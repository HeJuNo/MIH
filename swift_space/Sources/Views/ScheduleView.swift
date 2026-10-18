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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    let upcoming = filtered(state.entries)
                    if filter == .all, club == nil, let next = upcoming.first(where: { ($0.event.start ?? .distantPast) > .now }) {
                        NavigationLink(value: next.id) { NextUpCard(entry: next) }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                    }

                    FilterBar(filter: $filter, club: $club)

                    if upcoming.isEmpty && !state.isSyncing {
                        EmptyStateView(symbol: "calendar.badge.exclamationmark", title: "Keine Termine",
                                       message: "Sobald dein Verein Spiele oder Trainings einträgt, erscheinen sie hier.")
                    }
                    EntrySections(entries: upcoming)

                    if !state.archive.isEmpty || state.isImportingHistory {
                        NavigationLink {
                            PastEventsView(filter: filter, club: club)
                        } label: {
                            PastLinkLabel(count: filtered(state.archive).count, importing: state.isImportingHistory)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spiele & Trainings")
            .navigationDestination(for: String.self) { key in EventDetailView(eventKey: key) }
            .refreshable { await state.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SyncStatusButton() }
            }
            .overlay {
                if state.entries.isEmpty && state.isSyncing { ProgressView("Lade Termine…") }
            }
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

/// Kind filter + club chips (only when the player has more than one club).
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
            .padding(.horizontal)

            if state.hasMultipleClubs {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("Alle Vereine", logo: nil, selected: club == nil) { club = nil }
                        ForEach(state.clubs) { c in
                            chip(c.clubName ?? c.id, logo: c.clubLogo, selected: club == c.id) { club = c.id }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func chip(_ title: String, logo: URL?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let logo {
                    AsyncImage(url: logo) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(title).lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator).opacity(selected ? 0 : 0.6), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
                VStack(spacing: 8) {
                    ForEach(group.events) { event in
                        if let entry = byKey[event.id] {
                            NavigationLink(value: entry.id) { EventRow(entry: entry) }
                                .buttonStyle(.plain)
                                .contextMenu { NotifyMenuItem(entry: entry) }
                        }
                    }
                }
                .padding(.horizontal)
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

/// History of the current season: local archive + web import.
struct PastEventsView: View {
    @Environment(AppState.self) private var state
    @State var filter: KindFilter
    @State var club: String?

    var body: some View {
        let past = state.archive.filter { filter.matches($0.event) && (club == nil || $0.clubID == club) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                FilterBar(filter: $filter, club: $club)
                if past.isEmpty {
                    EmptyStateView(symbol: "clock.arrow.circlepath", title: "Noch keine vergangenen Termine",
                                   message: state.isImportingHistory ? "Die Saison wird gerade geladen…"
                                       : "Vergangene Termine werden hier gesammelt.")
                }
                EntrySections(entries: past, newestFirst: true)
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Vergangene Termine")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PastLinkLabel: View {
    let count: Int
    let importing: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vergangene Termine").font(.subheadline.weight(.semibold))
                Text(importing ? "Saison wird geladen…" : "\(count) Einträge in dieser Saison")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if importing { ProgressView() } else { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DayHeader: View {
    let day: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).locale(.de)))
                .font(.footnote.weight(.bold))
            Text(day.formatted(.dateTime.day().month(.wide).year().locale(.de)))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if Calendar.current.isDateInToday(day) {
                Pill(text: "Heute", color: Theme.accent)
            } else if Calendar.current.isDateInTomorrow(day) {
                Pill(text: "Morgen", color: Theme.accent, filled: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Large hero card for the next upcoming event.
private struct NextUpCard: View {
    let entry: TrackedEntry
    private var event: Event { entry.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Als Nächstes", systemImage: "sparkles")
                    .font(.caption2.weight(.bold)).textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Pill(text: event.kindLabel, symbol: event.kindSymbol, color: .white.opacity(0.22))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(event.name ?? "Termin").font(.title3.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.85)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle).font(.footnote).foregroundStyle(.white.opacity(0.75))
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                if let start = event.start {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(start.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(.de)))
                            .font(.headline.monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                        Text(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(.de)))
                            .font(.caption)
                            .opacity(0.8)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 8)
                if let place = event.place, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(16)
        .background {
            ZStack {
                Theme.heroGradient
                event.tint.opacity(0.35).blendMode(.plusLighter)
                Image(systemName: "hockey.puck.fill")
                    .font(.system(size: 130))
                    .foregroundStyle(.white.opacity(0.06))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 120, y: 30)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}

struct EventRow: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry
    private var event: Event { entry.event }
    private var isPast: Bool { (event.start ?? .distantFuture) < .now }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                let start = EventDates.shortTime(event.timeStart)
                Text(event.timeRange.isEmpty ? "–:–" : start)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if let end = event.displayEnd {
                    Text(end)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 42, alignment: .trailing)
            .padding(.top, 2)

            RoundedRectangle(cornerRadius: 2)
                .fill(event.tint.gradient)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: event.kindSymbol).foregroundStyle(event.tint)
                    Text(event.subtitle.isEmpty ? event.kindLabel : event.subtitle)
                        .lineLimit(1)
                    if state.hasMultipleClubs, let club = state.clubName(entry.clubID) {
                        Text("· \(club)").lineLimit(1).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                Text(event.name ?? "Termin")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                if let place = event.place, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    StatusPill(event: event)
                    if let notes = entry.detail?.notes ?? event.eventNotes, !PlainText.from(html: notes).isEmpty {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                    }
                    if (event.hasNotifications ?? 0) > 0 {
                        Image(systemName: "envelope.badge.fill").foregroundStyle(Theme.alert)
                    }
                    Spacer()
                    if !isPast {
                        Image(systemName: state.isNotifying(entry.id) ? "bell.fill" : "bell.slash")
                            .foregroundStyle(state.isNotifying(entry.id) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.caption)
                .padding(.top, 1)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .opacity(isPast && entry.archivedAt == nil ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Toolbar indicator: spinner while syncing, otherwise last-sync time.
struct SyncStatusButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            Task { await state.refresh() }
        } label: {
            if state.isSyncing {
                ProgressView()
            } else {
                Image(systemName: state.lastError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(state.lastError == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.alert))
            }
        }
        .disabled(state.isSyncing)
        .accessibilityLabel("Aktualisieren")
    }
}
