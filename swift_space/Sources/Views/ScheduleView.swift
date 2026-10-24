import MyIceKit
import SwiftUI

/// "Spiele & Trainings": the player's personal schedule (`app_data`) across all clubs.
struct ScheduleView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let filter = state.scheduleFilter
        NavigationStack(path: $state.schedulePath) {
            List {
                let upcoming = state.entries.filter(filter.matches)

                ActiveFilterRow()

                if !filter.isActive, let next = upcoming.first(where: { !$0.isCancelled && ($0.event.start ?? .distantPast) > .now }) {
                    Section {
                        Button { state.schedulePath.append(next.id) } label: { NextUpCard(entry: next) }
                            .buttonStyle(PressableStyle())
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if !state.archive.isEmpty || state.isImportingHistory {
                    Section {
                        NavigationLink(value: PastEventsView.route) {
                            PastLinkLabel(count: state.archive.filter(filter.matches).count, importing: state.isImportingHistory)
                        }
                    }
                }

                if upcoming.isEmpty && !state.isSyncing {
                    if filter.isActive && !state.entries.isEmpty {
                        EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Keine passenden Termine",
                                       message: "Für diesen Filter gibt es gerade keine Termine.")
                            .listRowBackground(Color.clear)
                    } else {
                        EmptyStateView(symbol: "calendar", title: "Keine Termine",
                                       message: "Sobald dein Verein Spiele oder Trainings einträgt, erscheinen sie hier.")
                            .listRowBackground(Color.clear)
                    }
                }
                EntrySections(entries: upcoming)
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Spiele & Trainings")
            .navigationDestination(for: String.self) { key in
                if key == PastEventsView.route {
                    PastEventsView()
                } else {
                    EventDetailView(eventKey: key)
                }
            }
            .refreshable { await state.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { FilterMenu() }
                ToolbarItem(placement: .topBarTrailing) { SyncStatusButton() }
            }
            .overlay {
                if state.entries.isEmpty && state.isSyncing { ProgressView("Lade Termine…") }
            }
            .animation(Theme.spring, value: filter)
        }
    }
}

/// Toolbar filter shared by the schedule and the history, like Mail and Files: one menu for the kind
/// of event and (with several clubs) the club. The glyph fills while a filter is active.
struct FilterMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let filter = state.scheduleFilter
        Menu {
            Section("Anzeigen") {
                Picker("Anzeigen", selection: binding(\.kind)) {
                    ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            if state.hasMultipleClubs {
                Section("Verein") {
                    Picker("Verein", selection: binding(\.clubID)) {
                        Text("Alle Vereine").tag(String?.none)
                        ForEach(state.clubs) { Text($0.clubName ?? $0.id).tag(String?.some($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            if filter.isActive {
                Button("Filter zurücksetzen", systemImage: "xmark.circle") { state.setScheduleFilter(ScheduleFilter()) }
            }
        } label: {
            Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.selection, trigger: filter)
        .accessibilityLabel("Filter")
        .accessibilityValue(filter.isActive ? ActiveFilterRow.summary(filter, state: state) : "Aus")
    }

    private func binding<T>(_ path: WritableKeyPath<ScheduleFilter, T>) -> Binding<T> {
        Binding(get: { state.scheduleFilter[keyPath: path] },
                set: { var f = state.scheduleFilter; f[keyPath: path] = $0; state.setScheduleFilter(f) })
    }
}

/// Only while a filter is active: says what is hidden and clears it with one tap.
struct ActiveFilterRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let filter = state.scheduleFilter
        if filter.isActive {
            Section {
                Button { state.setScheduleFilter(ScheduleFilter()) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
                        Text(Self.summary(filter, state: state))
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .imageScale(.large)
                    }
                    .font(.subheadline)
                }
                .accessibilityLabel("Gefiltert: \(Self.summary(filter, state: state))")
                .accessibilityHint("Zeigt wieder alle Termine")
            }
        }
    }

    /// "Nur Spiele · EHC Musterstadt"
    static func summary(_ filter: ScheduleFilter, state: AppState) -> String {
        var parts: [String] = []
        if filter.kind != .all { parts.append(filter.kind.title) }
        if let club = state.clubName(filter.clubID) { parts.append(club) }
        return parts.joined(separator: " · ")
    }
}

/// Day-grouped list of entries; shared by the live schedule and the history.
struct EntrySections: View {
    @Environment(AppState.self) private var state
    /// Days and entries keep the given order (schedule: soonest first, archive: newest first).
    let entries: [TrackedEntry]

    var body: some View {
        let byKey = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = EventDates.groupedByDay(entries.map(\.event))
        ForEach(groups, id: \.day) { group in
            Section {
                ForEach(group.events) { event in
                    if let entry = byKey[event.id] {
                        NavigationLink(value: entry.id) { EventRow(entry: entry) }
                            .contextMenu { if !entry.isCancelled { NotifyMenuItem(entry: entry) } }
                            .swipeActions(edge: .trailing) { if !entry.isCancelled { NotifySwipeAction(entry: entry) } }
                    }
                }
            } header: {
                DayHeader(day: group.day)
            }
        }
    }
}

struct NotifyMenuItem: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry
    var body: some View {
        let on = state.isNotifying(entry.id)
        Button {
            state.setNotifying(!on, for: entry.id)
        } label: {
            Label(on ? "Benachrichtigungen aus" : "Benachrichtigungen an", systemImage: on ? "bell.slash" : "bell")
        }
    }
}

private struct NotifySwipeAction: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry
    var body: some View {
        let on = state.isNotifying(entry.id)
        Button {
            state.setNotifying(!on, for: entry.id)
        } label: {
            Label(on ? "Stumm" : "Melden", systemImage: on ? "bell.slash.fill" : "bell.fill")
        }
        .tint(on ? .gray : Theme.accent)
    }
}

/// History of the current season: local archive + web import. Uses the same filter as the schedule.
struct PastEventsView: View {
    static let route = "__past__"
    @Environment(AppState.self) private var state

    var body: some View {
        let filter = state.scheduleFilter
        let past = state.archive.filter(filter.matches)
        List {
            ActiveFilterRow()
            if past.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath",
                               title: filter.isActive && !state.archive.isEmpty ? "Keine passenden Termine" : "Noch keine vergangenen Termine",
                               message: state.isImportingHistory ? "Die Saison wird gerade geladen…"
                                   : filter.isActive && !state.archive.isEmpty ? "Für diesen Filter gibt es keine vergangenen Termine."
                                   : "Vergangene Termine werden hier gesammelt.")
                    .listRowBackground(Color.clear)
            }
            EntrySections(entries: past)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("Vergangene Termine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { FilterMenu() }
        }
        .animation(Theme.spring, value: filter)
    }
}

private struct PastLinkLabel: View {
    let count: Int
    let importing: Bool
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: "clock.arrow.circlepath", color: .indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vergangene Termine")
                Text(importing ? "Saison wird geladen…" : count == 1 ? "1 Eintrag in dieser Saison" : "\(count) Einträge in dieser Saison")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if importing { ProgressView() }
        }
    }
}

private struct DayHeader: View {
    let day: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de)))
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            if let relative {
                Text(relative)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var relative: String? {
        if Calendar.current.isDateInToday(day) { return "Heute" }
        if Calendar.current.isDateInTomorrow(day) { return "Morgen" }
        if Calendar.current.isDateInYesterday(day) { return "Gestern" }
        return nil
    }
}

/// Hero for the next upcoming event: the one colored surface on the screen.
private struct NextUpCard: View {
    let entry: TrackedEntry
    private var event: Event { entry.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: event.kindSymbol)
                Text("Als Nächstes · \(event.kindLabel)")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.name ?? "Termin")
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
            }

            if let start = event.start {
                HStack(alignment: .firstTextBaseline) {
                    Text(start.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(.de)))
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(.de)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if let place = event.place, !place.isEmpty {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroBackground(event.tint)
        .accessibilityElement(children: .combine)
    }
}

struct EventRow: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: TrackedEntry
    private var event: Event { entry.event }
    private var isPast: Bool { (event.start ?? .distantFuture) < .now }
    /// Notifications only matter for entries that can still change.
    private var showsMuted: Bool { !isPast && !entry.isCancelled && !state.isNotifying(entry.id) }

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            time
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(entry.isCancelled ? Theme.alert : event.tint)
                    .frame(width: 4)
                details
            }
        }
        .padding(.vertical, 4)
        .opacity(isPast && entry.archivedAt == nil ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var time: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            Text(event.timeRange.isEmpty ? "–:–" : EventDates.shortTime(event.timeStart))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if let end = event.displayEnd {
                Text(end)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: typeSize.isAccessibilitySize ? nil : 44, alignment: .trailing)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.name ?? "Termin")
                .font(.body.weight(.semibold))
                .strikethrough(entry.isCancelled, color: Theme.alert)
                .lineLimit(2)

            Text(meta)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if entry.isCancelled { CancelledPill() } else { StatusPill(event: event) }
                if let notes = entry.detail?.notes ?? event.eventNotes, !PlainText.from(html: notes).isEmpty {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                }
                if (event.hasNotifications ?? 0) > 0 {
                    Image(systemName: "envelope.badge.fill").foregroundStyle(Theme.alert)
                }
                Spacer(minLength: 0)
                // Only the exception is shown; a bell on every row is noise.
                if showsMuted {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.tertiary)
                }
            }
            .font(.footnote)
            .padding(.top, 3)
        }
    }

    /// "U15 · Gruppe A · Eishalle": one quiet line instead of three.
    private var meta: String {
        var parts = [event.subtitle.isEmpty ? event.kindLabel : event.subtitle]
        if state.hasMultipleClubs, let club = state.clubName(entry.clubID) { parts.append(club) }
        if let place = event.place, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        let day = event.start?.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de)) ?? ""
        let status = entry.isCancelled ? EventStatus.cancelledTitle : "Status \(EventStatus(event: event).title)"
        var parts = [event.kindLabel, event.name ?? "Termin", day, event.timeRange, meta, status]
        if (event.hasNotifications ?? 0) > 0 { parts.append("Neue Mitteilung") }
        if showsMuted { parts.append("Benachrichtigungen aus") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Toolbar button: rotates while syncing; after a failed sync it turns red and explains why.
struct SyncStatusButton: View {
    @Environment(AppState.self) private var state
    @State private var showError = false

    var body: some View {
        Button {
            if state.lastError != nil { showError = true } else { Task { await state.refresh() } }
        } label: {
            Image(systemName: state.lastError == nil ? "arrow.clockwise" : "exclamationmark.arrow.circlepath")
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state.isSyncing)
                .foregroundStyle(state.lastError == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.alert))
        }
        .disabled(state.isSyncing)
        .accessibilityLabel(state.lastError == nil ? "Aktualisieren" : "Synchronisierung fehlgeschlagen")
        .alert("Synchronisierung fehlgeschlagen", isPresented: $showError) {
            Button("Erneut versuchen") { Task { await state.refresh() } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? "")
        }
    }
}
