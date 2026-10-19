import Foundation

/// Fetches "Spiele & Trainings" (`/refreshdata → app_data`) for every club of the
/// player, loads the detail of each upcoming entry (`/getevent`), diffs against the
/// previous generation, archives entries that took place, and persists the result.
/// Used identically by pull-to-refresh and background refresh.
///
/// Every operation that reads and writes `SyncState` runs strictly one after the
/// other (`exclusive`). Otherwise a sync that loaded the state before a detail
/// screen saved a detected change would write its older copy back and the change
/// would be lost.
public actor SyncEngine {
    public struct Configuration: Sendable {
        /// Only entries starting within this window get a detail fetch.
        public var detailHorizon: TimeInterval = 60 * 24 * 3600
        public var maxDetailFetches = 150
        public var concurrency = 6
        public init() {}
    }

    public struct Result: Sendable {
        public var entries: [TrackedEntry]
        /// Empty on the very first sync (baseline); entries of newly added clubs are baselined too.
        public var changes: [EventChange]
        public var wasBaseline: Bool
    }

    public enum SyncError: Error, Equatable { case notLoggedIn, missingPlayer, noClubs }

    private let api: APIClient
    private let store: SyncStore
    private let configuration: Configuration
    private let log: LogSink
    private var inFlight: Task<Result, Error>?
    /// Last queued state operation; the next one waits for it.
    private var tail: Task<Void, Never>?

    public init(api: APIClient, store: SyncStore, configuration: Configuration = .init(), log: LogSink = .none) {
        self.api = api
        self.store = store
        self.configuration = configuration
        self.log = log
    }

    /// Runs `body` after every previously queued state operation has finished.
    private func exclusive<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Coalesces concurrent calls (e.g. pull-to-refresh during a background run).
    /// `deadline` (background runs) stops starting new detail requests once reached;
    /// skipped details keep their last known value and get priority next time.
    public func sync(clubIDs: [String], playerID: Int?, now: Date = .now, deadline: Date? = nil) async throws -> Result {
        if let inFlight {
            log(.debug, .sync, "Synchronisierung läuft bereits, warte auf Ergebnis")
            return try await inFlight.value
        }
        let task = Task {
            try await self.exclusive { try await self.performSync(clubIDs: clubIDs, playerID: playerID, now: now, deadline: deadline) }
        }
        inFlight = task
        defer { inFlight = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performSync(clubIDs rawClubs: [String], playerID: Int?, now: Date, deadline: Date?) async throws -> Result {
        var state = await store.load()
        state.lastAttempt = now
        let clubs = Array(NSOrderedSet(array: rawClubs.filter { !$0.isEmpty })) as! [String]
        let began = Date()
        log(.info, .sync, "Start: Vereine \(clubs.joined(separator: ", ")), gespeichert \(state.entries.count) Termine")

        guard let playerID else { return try await fail(&state, SyncError.missingPlayer) }
        guard !clubs.isEmpty else { return try await fail(&state, SyncError.noClubs) }

        // 1. Personal schedule of every club. Any failure aborts so nothing is mistaken for "removed".
        var events: [(Event, String)] = []
        var seen = Set<String>()
        do {
            for club in clubs {
                let payload: SessionPayload = try await api.send(.refreshData(clubID: club))
                let rows = payload.appData ?? []
                log(.debug, .sync, "Verein \(club): \(rows.count) Termine")
                for event in rows where seen.insert(event.id).inserted {
                    events.append((event, club))
                }
            }
        } catch {
            return try await fail(&state, error)
        }
        events.sort { (EventDates.start(of: $0.0) ?? .distantFuture) < (EventDates.start(of: $1.0) ?? .distantFuture) }

        // 2. Details for upcoming entries.
        let previous = state.entries
        let previousByKey = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Least recently refreshed first, so runs cut short by the deadline still rotate through everything.
        let wanted = events.filter { needsDetail($0.0, now: now) }
            .sorted { (previousByKey[$0.0.id]?.detailFetchedAt ?? .distantPast) < (previousByKey[$1.0.id]?.detailFetchedAt ?? .distantPast) }
            .prefix(configuration.maxDetailFetches)
        let details = await fetchDetails(wanted.map { ($0.0, $0.1) }, playerID: playerID, deadline: deadline)
        let level: LogLevel = details.count < wanted.count ? .warning : .info
        log(level, .sync, "Details: \(details.count) von \(wanted.count) geladen" + (details.count < wanted.count ? " (Rest behält den letzten Stand)" : ""))

        let entries: [TrackedEntry] = events.map { event, club in
            if let fresh = details[event.id] {
                return TrackedEntry(event: event, detail: fresh, detailFetchedAt: now, clubID: club)
            }
            // Keep the last known detail so a failed fetch doesn't erase it.
            let old = previousByKey[event.id]
            return TrackedEntry(event: event, detail: old?.detail, detailFetchedAt: old?.detailFetchedAt, clubID: club)
        }

        // 3. Diff only clubs that were already covered by the baseline.
        let knownClubs = Set(state.clubIDs ?? []).intersection(clubs)
        let isBaseline = !state.hasBaseline
        let changes: [EventChange]
        if isBaseline {
            changes = []
        } else {
            let inKnown: (TrackedEntry) -> Bool = { $0.clubID.map(knownClubs.contains) ?? false }
            changes = ChangeDetector.diff(old: previous.filter(inKnown), new: entries.filter(inKnown), now: now)
        }

        // 4. Archive entries that dropped out after they took place.
        let newKeys = Set(entries.map(\.id))
        var archive = state.archive ?? []
        for var gone in previous where !newKeys.contains(gone.id) && !ChangeDetector.isUpcoming(gone, now: now) {
            gone.archivedAt = now
            archive.removeAll { $0.id == gone.id }
            archive.append(gone)
        }
        archive.removeAll { newKeys.contains($0.id) }
        archive = Self.trimmed(archive, now: now)

        state.entries = entries
        state.archive = archive
        state.clubIDs = clubs
        state.lastSync = now
        state.lastError = nil
        state.changeLog = Array((changes.reversed() + state.changeLog).prefix(SyncState.changeLogLimit))
        await store.save(state)

        if isBaseline {
            log(.info, .sync, "Ausgangsstand gespeichert: \(entries.count) Termine (noch keine Änderungen gemeldet)")
        }
        logChanges(changes, source: "Synchronisierung")
        log(.info, .sync, String(format: "Fertig in %.1f s: %d Termine, %d Änderungen, Archiv %d", Date().timeIntervalSince(began),
                                 entries.count, changes.count, archive.count))
        return Result(entries: entries, changes: changes, wasBaseline: isBaseline)
    }

    private func fail(_ state: inout SyncState, _ error: Error) async throws -> Result {
        state.lastError = String(describing: error)
        await store.save(state)
        log(error is CancellationError ? .warning : .error, .sync, "Abgebrochen: \(String(describing: error))")
        throw error
    }

    private func logChanges(_ changes: [EventChange], source: String) {
        guard !changes.isEmpty else { return }
        log(.info, .changes, "\(source): \(changes.count) Änderung(en) erkannt")
        for c in changes {
            log(.debug, .changes, "\(c.eventKey) \(c.eventSubtitle ?? "") \(c.eventTitle): \(c.kind)")
        }
    }

    static func trimmed(_ archive: [TrackedEntry], now: Date) -> [TrackedEntry] {
        let cutoff = now.addingTimeInterval(-SyncState.archiveRetention)
        return Array(archive
            .filter { (EventDates.start(of: $0.event) ?? now) > cutoff }
            .sorted { (EventDates.start(of: $0.event) ?? .distantPast) > (EventDates.start(of: $1.event) ?? .distantPast) }
            .prefix(SyncState.archiveLimit))
    }

    private func needsDetail(_ event: Event, now: Date) -> Bool {
        guard event.kind != nil else { return false }
        guard let start = EventDates.start(of: event) else { return true }
        let startOfToday = Calendar.current.startOfDay(for: now)
        return start >= startOfToday && start <= now.addingTimeInterval(configuration.detailHorizon)
    }

    private func fetchDetails(_ events: [(Event, String)], playerID: Int, deadline: Date?) async -> [String: EventDetail] {
        var result: [String: EventDetail] = [:]
        var iterator = events.makeIterator()
        await withTaskGroup(of: (String, EventDetail?).self) { group in
            func enqueue() {
                if Task.isCancelled || deadline.map({ Date() >= $0 }) == true { return }
                guard let (event, club) = iterator.next(), let kind = event.kind, let id = event.primaryID else { return }
                group.addTask { [api] in
                    let r: EventDetailResponse? = try? await api.send(.getEvent(kind: kind, eventID: id, playerID: playerID, clubID: club))
                    return (event.id, r?.eventData)
                }
            }
            for _ in 0..<configuration.concurrency { enqueue() }
            while let (key, detail) = await group.next() {
                if let detail { result[key] = detail }
                enqueue()
            }
        }
        return result
    }

    /// Fetches a single detail on demand (detail screen, also for archived entries) and stores it.
    /// Changes against the stored detail are logged like those of a regular sync.
    public func refreshDetail(for entry: TrackedEntry, playerID: Int?) async throws -> EventDetail? {
        guard let playerID, let kind = entry.event.kind, let id = entry.event.primaryID else { return nil }
        let r: EventDetailResponse = try await api.send(.getEvent(kind: kind, eventID: id, playerID: playerID, clubID: entry.clubID))
        guard let detail = r.eventData else { return nil }
        let key = entry.id
        let fetchedAt = Date()
        let changes: [EventChange] = try await exclusive {
            await self.storeDetail(detail, key: key, fetchedAt: fetchedAt)
        }
        logChanges(changes, source: "Detailansicht")
        return detail
    }

    private func storeDetail(_ detail: EventDetail, key: String, fetchedAt: Date) async -> [EventChange] {
        var state = await store.load()
        var changes: [EventChange] = []
        if let i = state.entries.firstIndex(where: { $0.id == key }) {
            // Compare against the stored entry (not the caller's possibly outdated copy) so
            // only the detail differs and on-demand loads don't hide changes from the next sync.
            let stored = state.entries[i]
            if state.hasBaseline, stored.detail != nil {
                var fresh = stored
                fresh.detail = detail
                changes = ChangeDetector.diff(old: [stored], new: [fresh], now: fetchedAt)
            }
            state.entries[i].detail = detail
            state.entries[i].detailFetchedAt = fetchedAt
            state.changeLog = Array((changes.reversed() + state.changeLog).prefix(SyncState.changeLogLimit))
        } else if let i = state.archive?.firstIndex(where: { $0.id == key }) {
            state.archive?[i].detail = detail
            state.archive?[i].detailFetchedAt = fetchedAt
        }
        await store.save(state)
        return changes
    }

    /// Merges past entries (e.g. from `WebHistoryClient`) into the archive without
    /// touching the live baseline or producing notifications.
    public func importHistory(_ past: [TrackedEntry], now: Date = .now) async {
        _ = try? await exclusive { await self.mergeHistory(past, now: now) }
    }

    private func mergeHistory(_ past: [TrackedEntry], now: Date) async {
        var state = await store.load()
        let live = Set(state.entries.map(\.id))
        var archive = state.archive ?? []
        let known = Set(archive.map(\.id))
        archive += past.filter { !live.contains($0.id) && !known.contains($0.id) }
        state.archive = Self.trimmed(archive, now: now)
        await store.save(state)
        log(.info, .history, "Archiv: \(past.count) vergangene Termine erhalten, jetzt \(state.archive?.count ?? 0)")
    }

    /// Empties the list of detected changes.
    public func clearChangeLog() async {
        _ = try? await exclusive {
            var state = await self.store.load()
            state.changeLog = []
            await self.store.save(state)
        }
    }

    /// Records the user's own status change in the baseline so the next sync
    /// doesn't report it back as a change. Mirrors the original optimistic update:
    /// `health_status = available == 2 ? 3 : id_status`.
    public func applyLocalStatus(eventKey: String, submission: StatusRules.Submission) async {
        _ = try? await exclusive { await self.storeLocalStatus(eventKey: eventKey, submission: submission) }
    }

    private func storeLocalStatus(eventKey: String, submission: StatusRules.Submission) async {
        var state = await store.load()
        guard let i = state.entries.firstIndex(where: { $0.id == eventKey }) else { return }
        var entry = state.entries[i]
        let available = submission.attendance ?? Availability(code: entry.detail?.available ?? entry.event.available)
        let health = available == .confirmed ? HealthStatus.attending.rawValue : submission.status?.rawValue
        entry.event.available = available.rawValue
        entry.event.healthStatus = health
        entry.event.healthStatusNotes = submission.notes
        if let detail = entry.detail { entry.detail = StatusRules.applying(submission, to: detail) }
        state.entries[i] = entry
        await store.save(state)
    }
}
