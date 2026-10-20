import MyIceKit
import SwiftUI

/// "Spiele & Trainings": the player's personal schedule (`app_data`) across all clubs.
struct ScheduleView: View {
    @Environment(AppState.self) private var state
    @State private var filter: KindFilter = .all
    @State private var club: String?

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.schedulePath) {
            List {
                let upcoming = filtered(state.entries)

                FilterBar(filter: $filter, club: $club)

                if filter == .all, club == nil, let next = upcoming.first(where: { ($0.event.start ?? .distantPast) > .now }) {
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
                            PastLinkLabel(count: filtered(state.archive).count, importing: state.isImportingHistory)
                        }
                    }
                }

                if upcoming.isEmpty && !state.isSyncing {
                    EmptyStateView(symbol: "calendar", title: "Keine Termine",
                                   message: "Sobald dein Verein Spiele oder Trainings einträgt, erscheinen sie hier.")
                        .listRowBackground(Color.clear)
                }
                EntrySections(entries: upcoming)
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Spiele & Trainings")
            .navigationDestination(for: String.self) { key in
                if key == PastEventsView.route {
                    PastEventsView(filter: filter, club: club)
                } else {
                    EventDetailView(eventKey: key)
                }
            }
            .refreshable { await state.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SyncStatusButton() }
            }
            .overlay {
                if state.entries.isEmpty && state.isSyncing { ProgressView("Lade Termine…") }
            }
            .animation(Theme.spring, value: filter)
            .animation(Theme.spring, value: club)
        }
    }

    private func filtered(_ entries: [TrackedEntry]) -> [TrackedEntry] {
        entries.filter { filter.matches($0.event) && (club == nil || $0.clubID == club) }
    }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "Alle", games = "Spiele", practices = "Trainings"
    var id: Self { self }
    func matches(_ e: Event) -> Bool {
        switch self {
        case .all: true
        case .games: e.idGame != nil
        case .practices: e.idPractice != nil
        }
    }
}

/// Kind filter + club chips (only when the player has more than one club). Lives inside a List
/// as a row without background.
struct FilterBar: View {
    @Environment(AppState.self) private var state
    @Binding var filter: KindFilter
    @Binding var club: String?

    var body: some View {
        VStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if state.hasMultipleClubs {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("Alle Vereine", logo: nil, selected: club == nil) { club = nil }
                        ForEach(state.clubs) { c in
                            chip(c.clubName ?? c.id, logo: c.clubLogo, selected: club == c.id) { club = c.id }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear)
        .sensoryFeedback(.selection, trigger: club)
    }

    private func chip(_ title: String, logo: URL?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let logo {
                    AsyncImage(url: logo) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Day-grouped list of entries; shared by the live schedule and the history.
struct EntrySections: View {
    @Environment(AppState.self) private var state
    let entries: [TrackedEntry]
    var newestFirst = false

    var body: some View {
        let byKey = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = EventDates.groupedByDay(entries.map(\.event))
        ForEach(newestFirst ? groups.reversed() : groups, id: \.day) { group in
            Section {
                ForEach(group.events) { event in
                    if let entry = byKey[event.id] {
                        NavigationLink(value: entry.id) { EventRow(entry: entry) }
                            .contextMenu { NotifyMenuItem(entry: entry) }
                            .swipeActions(edge: .trailing) { NotifySwipeAction(entry: entry) }
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

/// History of the current season: local archive + web import.
struct PastEventsView: View {
    static let route = "__past__"
    @Environment(AppState.self) private var state
    @State var filter: KindFilter
    @State var club: String?

    var body: some View {
        let past = state.archive.filter { filter.matches($0.event) && (club == nil || $0.clubID == club) }
        List {
            FilterBar(filter: $filter, club: $club)
            if past.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "Noch keine vergangenen Termine",
                               message: state.isImportingHistory ? "Die Saison wird gerade geladen…"
                                   : "Vergangene Termine werden hier gesammelt.")
                    .listRowBackground(Color.clear)
            }
            EntrySections(entries: past, newestFirst: true)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("Vergangene Termine")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Theme.spring, value: filter)
        .animation(Theme.spring, value: club)
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
                Text(importing ? "Saison wird geladen…" : "\(count) Einträge in dieser Saison")
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

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            time
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(event.tint)
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
                .lineLimit(2)

            Text(meta)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                StatusPill(event: event)
                if let notes = entry.detail?.notes ?? event.eventNotes, !PlainText.from(html: notes).isEmpty {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                }
                if (event.hasNotifications ?? 0) > 0 {
                    Image(systemName: "envelope.badge.fill").foregroundStyle(Theme.alert)
                }
                Spacer(minLength: 0)
                // Only the exception is shown; a bell on every row is noise.
                if !isPast && !state.isNotifying(entry.id) {
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
        var parts = [event.kindLabel, event.name ?? "Termin", day, event.timeRange, meta, "Status \(EventStatus(event: event).title)"]
        if (event.hasNotifications ?? 0) > 0 { parts.append("Neue Mitteilung") }
        if !isPast && !state.isNotifying(entry.id) { parts.append("Benachrichtigungen aus") }
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
