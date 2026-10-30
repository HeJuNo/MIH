import EventKit
import Foundation
import MyIceKit

enum CalendarSyncError: Error { case noSource }

/// Mirrors "Spiele & Trainings" (current entries + archive, i.e. the current season) into
/// an iOS calendar via EventKit: one `EKEvent` per tracked entry, plus a linked
/// meeting-point/departure sub-event when the detail has a usable time. Runs after every
/// `SyncCoordinator` pass (background and foreground), so the calendar follows the app
/// automatically. The app is always the source of truth: a manually edited or deleted
/// calendar entry is simply recreated on the next pass.
actor CalendarSync {
    static let defaultCalendarTitle = "MyHockey Data"
    /// Caps the one-time detail backfill per run so a large first sync doesn't block the
    /// background budget; the rest catches up on the next pass.
    private let maxDetailBackfill = 25

    private let store = EKEventStore()
    private let mappingStore: CalendarSyncStore
    private let settings: SettingsStore
    private let syncStore: SyncStore
    private let engine: SyncEngine
    private let session: DefaultSessionStore
    private let log: AppLog

    init(settings: SettingsStore, syncStore: SyncStore, engine: SyncEngine, session: DefaultSessionStore,
         log: AppLog, mappingStore: CalendarSyncStore = CalendarSyncStore()) {
        self.settings = settings
        self.syncStore = syncStore
        self.engine = engine
        self.session = session
        self.log = log
        self.mappingStore = mappingStore
    }

    nonisolated var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    @discardableResult
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Writable calendars the picker in Settings can offer.
    func availableCalendars() -> [(id: String, title: String)] {
        guard authorizationStatus == .fullAccess else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { $0.title < $1.title }
            .map { ($0.calendarIdentifier, $0.title) }
    }

    /// One sync pass: backfill missing detail for past entries, resolve the calendar, then
    /// create/update/delete `EKEvent`s to match `entries + archive` exactly.
    func run(reason: String, deadline: Date? = nil) async {
        guard settings.calendarSyncEnabled else {
            log(.debug, .calendar, "(\(reason)) disabled")
            return
        }
        guard authorizationStatus == .fullAccess else {
            log(.warning, .calendar, "(\(reason)) skipped: access not granted")
            return
        }
        guard let playerID = session.loadUser()?.info.idPlayer else {
            log(.debug, .calendar, "(\(reason)) skipped: not signed in")
            return
        }

        var syncState = await syncStore.load()
        let backfilled = await backfillDetails(from: syncState, playerID: playerID, deadline: deadline)
        if backfilled > 0 { syncState = await syncStore.load() }   // refreshDetail already persisted; reload fresh

        let calendar: EKCalendar
        do { calendar = try resolveCalendar() } catch {
            log(.error, .calendar, "(\(reason)) could not resolve calendar: \(error)")
            return
        }

        let clubNames = clubNames(for: session.loadUser())
        let changesByEvent = Dictionary(grouping: syncState.changeLog) { $0.eventKey }
        let tracked = syncState.entries + (syncState.archive ?? [])
        let liveKeys = Set(tracked.map(\.id))

        var state = await mappingStore.load()
        var removedCount = 0
        for key in Set(state.mapping.keys).subtracting(liveKeys) {
            remove(state.mapping[key])
            state.mapping[key] = nil
            removedCount += 1
        }

        var written = 0
        for entry in tracked {
            if Task.isCancelled || deadline.map({ Date() >= $0 }) == true { break }
            var mapping = state.mapping[entry.id] ?? CalendarMapping()
            upsert(entry, changes: changesByEvent[entry.id] ?? [], team: clubNames[entry.clubID ?? ""],
                   calendar: calendar, mapping: &mapping)
            state.mapping[entry.id] = mapping.isEmpty ? nil : mapping
            written += 1
        }

        do { try store.commit() } catch {
            log(.error, .calendar, "(\(reason)) commit failed: \(error)")
        }
        await mappingStore.save(state)
        log(.info, .calendar, "(\(reason)): \(pluralized(written, "event")) written"
            + (removedCount > 0 ? ", \(pluralized(removedCount, "event")) removed" : "")
            + (backfilled > 0 ? ", \(pluralized(backfilled, "detail")) backfilled" : ""))
    }

    /// Removes every calendar entry this created; called when the user turns sync off.
    func removeAll() async {
        var state = await mappingStore.load()
        for mapping in state.mapping.values { remove(mapping) }
        try? store.commit()
        state.mapping = [:]
        await mappingStore.save(state)
        log(.info, .calendar, "Disabled: removed all synced events")
    }

    // MARK: - Detail backfill

    /// One-time `/getevent` load for archived entries that never got a detail (the regular
    /// sync only fetches it for upcoming ones). `SyncEngine.refreshDetail` persists each
    /// result itself.
    private func backfillDetails(from state: SyncState, playerID: Int, deadline: Date?) async -> Int {
        let candidates = (state.archive ?? []).filter { !$0.isCancelled && $0.detail == nil }
        guard !candidates.isEmpty else { return 0 }
        var done = 0
        for entry in candidates.prefix(maxDetailBackfill) {
            if deadline.map({ Date() >= $0 }) == true { break }
            if (try? await engine.refreshDetail(for: entry, playerID: playerID)) != nil { done += 1 }
        }
        return done
    }

    // MARK: - Calendar

    private func resolveCalendar() throws -> EKCalendar {
        if let id = settings.calendarIdentifier, let existing = store.calendar(withIdentifier: id) { return existing }
        if let byTitle = store.calendars(for: .event).first(where: { $0.title == Self.defaultCalendarTitle && $0.allowsContentModifications }) {
            settings.calendarIdentifier = byTitle.calendarIdentifier
            return byTitle
        }
        guard let source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .local }) ?? store.sources.first else {
            throw CalendarSyncError.noSource
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.defaultCalendarTitle
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        settings.calendarIdentifier = calendar.calendarIdentifier
        return calendar
    }

    // MARK: - Event fields

    private func upsert(_ entry: TrackedEntry, changes: [EventChange], team: String?, calendar: EKCalendar,
                        mapping: inout CalendarMapping) {
        guard let start = EventDates.start(of: entry.event) else {
            remove(mapping)
            mapping = CalendarMapping()
            return
        }
        let end = EventDates.end(of: entry.event).map { $0 > start ? $0 : nil } ?? nil
        let resolvedEnd = end ?? start.addingTimeInterval(90 * 60)

        let main = event(withID: mapping.mainEventID, calendar: calendar)
        let mainTitle = title(for: entry, team: team)
        main.title = mainTitle
        main.location = entry.event.place
        main.startDate = start
        main.endDate = resolvedEnd
        main.notes = notes(for: entry, changes: changes)
        try? store.save(main, span: .thisEvent, commit: false)
        mapping.mainEventID = main.eventIdentifier

        upsertLinked(.meeting, entry: entry, mainStart: start, mainTitle: mainTitle, team: team, calendar: calendar,
                     identifier: mapping.meetingEventID) { mapping.meetingEventID = $0 }
        upsertLinked(.departure, entry: entry, mainStart: start, mainTitle: mainTitle, team: team, calendar: calendar,
                     identifier: mapping.departureEventID) { mapping.departureEventID = $0 }
    }

    private enum LinkedKind { case meeting, departure }

    /// Creates/updates/removes the "Treffpunkt"/"Abfahrt" sub-event: start = that time,
    /// end = the main event's start. Removed again once the detail no longer has a usable time.
    private func upsertLinked(_ kind: LinkedKind, entry: TrackedEntry, mainStart: Date, mainTitle: String, team: String?,
                              calendar: EKCalendar, identifier: String?, store writeID: (String?) -> Void) {
        let rawTime: String?, rawLabel: String?, fallbackLabel: String
        switch kind {
        case .meeting: (rawTime, rawLabel, fallbackLabel) = (entry.detail?.meetingTime, entry.detail?.meeting, "Treffpunkt")
        case .departure: (rawTime, rawLabel, fallbackLabel) = (entry.detail?.departureTime, entry.detail?.departure, "Abfahrt")
        }
        let parsed = leadingTime(rawTime) ?? (kind == .meeting ? meetingTimeInNotes(entry.detail?.notes) : nil)
        guard let (time, locationText) = parsed, let start = combinedDate(time, day: mainStart) else {
            if let identifier { removeEvent(identifier) }
            writeID(nil)
            return
        }
        let label = nonEmpty(rawLabel) ?? fallbackLabel
        let ek = event(withID: identifier, calendar: calendar)
        // "Treffpunkt"/"Abfahrt" mirrors the main title's "PREFIX TEAM …" shape instead of
        // prefixing the full main title, e.g. main "PREFIX TEAM Eistraining" -> "PREFIX TEAM Treffpunkt".
        ek.title = kind == .meeting ? linkedTitle(for: entry, team: team, label: label) : "\(label): \(mainTitle)"
        ek.location = locationText.isEmpty ? nil : locationText
        ek.startDate = start
        ek.endDate = max(mainStart, start.addingTimeInterval(60))
        try? self.store.save(ek, span: .thisEvent, commit: false)
        writeID(ek.eventIdentifier)
    }

    private func event(withID id: String?, calendar: EKCalendar) -> EKEvent {
        let ek = id.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        ek.calendar = calendar
        return ek
    }

    private func removeEvent(_ id: String) {
        guard let ek = store.event(withIdentifier: id) else { return }
        try? store.remove(ek, span: .thisEvent, commit: false)
    }

    private func remove(_ mapping: CalendarMapping?) {
        guard let mapping else { return }
        [mapping.mainEventID, mapping.meetingEventID, mapping.departureEventID].compactMap { $0 }.forEach(removeEvent)
    }

    private func title(for entry: TrackedEntry, team: String?) -> String {
        let base: String
        if entry.event.isGame {
            base = entry.event.name ?? "Termin"
        } else if let team, !team.isEmpty {
            base = "\(team) \(entry.event.name ?? "Training")"
        } else {
            base = entry.event.name ?? "Training"
        }
        return decorated(base, cancelled: entry.isCancelled)
    }

    /// "Treffpunkt"/"Abfahrt" sub-event title: the main title's "PREFIX TEAM …" shape with
    /// `label` ("Treffpunkt" by default, or the server's custom label) standing in for the
    /// event name, e.g. main "PREFIX TEAM Eistraining" -> linked "PREFIX TEAM Treffpunkt".
    private func linkedTitle(for entry: TrackedEntry, team: String?, label: String) -> String {
        let base = team.flatMap { $0.isEmpty ? nil : "\($0) \(label)" } ?? label
        return decorated(base, cancelled: entry.isCancelled)
    }

    private func decorated(_ base: String, cancelled: Bool) -> String {
        let withStatus = cancelled ? "Abgesagt: \(base)" : base
        guard settings.calendarTitlePrefixEnabled, !settings.calendarTitlePrefix.isEmpty else { return withStatus }
        return "\(settings.calendarTitlePrefix) \(withStatus)"
    }

    private func notes(for entry: TrackedEntry, changes: [EventChange]) -> String {
        var sections: [String] = []
        if let detail = entry.detail {
            let participants = participantsText(detail)
            if !participants.isEmpty { sections.append(participants) }
            let free = PlainText.from(html: detail.notes)
            if !free.isEmpty { sections.append("Notizen:\n\(free)") }
        }
        if !changes.isEmpty {
            let lines = changes.sorted { $0.detectedAt > $1.detectedAt }.prefix(10).map { c in
                let t = ChangeFormatter.text(for: c)
                return "• \(t.headline): \(t.detail)"
            }
            sections.append("Änderungen:\n" + lines.joined(separator: "\n"))
        }
        sections.append("Synchronisiert \(Date().formatted(date: .abbreviated, time: .shortened))")
        return sections.joined(separator: "\n\n")
    }

    private func participantsText(_ d: EventDetail) -> String {
        let players = (d.convocation?.available ?? [])
            .map { "\($0.fname ?? "") \($0.lname ?? "")".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let staff = (d.convocation?.staff ?? [])
            .map { "\($0.fname ?? "") \($0.lname ?? "")".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var lines: [String] = []
        if !players.isEmpty { lines.append("Teilnehmer (\(players.count)): \(players.joined(separator: ", "))") }
        if !staff.isEmpty { lines.append("Betreuer: \(staff.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// The team label used in calendar titles: the configured "Kürzel" when set for that
    /// club, the full club name otherwise.
    private func clubNames(for user: User?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (user?.info.activeClubs ?? []).map {
            ($0.id, settings.clubAbbreviation(for: $0.id) ?? ($0.clubName ?? ""))
        })
    }

    // MARK: - Free-text time parsing

    /// Splits a detail time field like `"08:30 Parkplatz Halle"` into its clock time and the
    /// remaining free text; nil when there is no usable leading time (`"00:00"`, `"–"`, empty).
    private func leadingTime(_ raw: String?) -> (time: String, rest: String)? {
        guard let t = EventDates.meaningfulTime(raw) else { return nil }
        guard let match = t.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) else { return nil }
        return (String(t[match]), t[match.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    /// Falls back to a time written in the free-text notes, e.g. "Treffpunkt 11:45", "TP 11:45"
    /// or "Treff: 11:45", for events where the structured `meeting_time` field isn't set.
    /// No location is derived from this; the rest of the note isn't reliably a place.
    private func meetingTimeInNotes(_ html: String?) -> (time: String, rest: String)? {
        let text = PlainText.from(html: html)
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:treffpunkt|treff|tp)\b[^\d\n]{0,15}(\d{1,2}:\d{2})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return (String(text[range]), "")
    }

    private func combinedDate(_ time: String, day: Date) -> Date? {
        let hm = time.split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: day)
    }

    private func nonEmpty(_ s: String?) -> String? {
        s.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
