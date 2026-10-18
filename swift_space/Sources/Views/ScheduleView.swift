import MyIceKit
import SwiftUI

/// "Spiele & Trainings": the player's personal schedule (`app_data`).
struct ScheduleView: View {
    @Environment(AppState.self) private var state
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Alle", games = "Spiele", practices = "Trainings"
        var id: Self { self }
    }

    private var filtered: [TrackedEntry] {
        state.entries.filter {
            switch filter {
            case .all: true
            case .games: $0.event.idGame != nil
            case .practices: $0.event.idPractice != nil
            }
        }
    }

    private var nextUp: TrackedEntry? {
        state.entries.first { ($0.event.start ?? .distantPast) > .now }
    }

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.schedulePath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    if let nextUp, filter == .all {
                        NavigationLink(value: nextUp.id) { NextUpCard(entry: nextUp) }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                    }

                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    let groups = EventDates.groupedByDay(filtered.map(\.event))
                    if groups.isEmpty && !state.isSyncing {
                        EmptyStateView(symbol: "calendar.badge.exclamationmark", title: "Keine Termine",
                                       message: "Sobald dein Verein Spiele oder Trainings einträgt, erscheinen sie hier.")
                    }
                    ForEach(groups, id: \.day) { group in
                        Section {
                            VStack(spacing: 10) {
                                ForEach(group.events) { event in
                                    if let entry = state.entry(for: event.id) {
                                        NavigationLink(value: entry.id) { EventRow(entry: entry) }
                                            .buttonStyle(.plain)
                                            .contextMenu { notifyToggle(entry) }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        } header: {
                            DayHeader(day: group.day)
                        }
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

    @ViewBuilder private func notifyToggle(_ entry: TrackedEntry) -> some View {
        let on = state.isNotifying(entry.id)
        Button {
            state.setNotifying(!on, for: entry.id)
        } label: {
            Label(on ? "Benachrichtigungen aus" : "Benachrichtigungen an", systemImage: on ? "bell.slash" : "bell")
        }
    }
}

private struct DayHeader: View {
    let day: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).locale(.de)))
                .font(.subheadline.weight(.bold))
            Text(day.formatted(.dateTime.day().month(.wide).locale(.de)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if Calendar.current.isDateInToday(day) {
                Pill(text: "Heute", color: Theme.accent)
            } else if Calendar.current.isDateInTomorrow(day) {
                Pill(text: "Morgen", color: Theme.accent, filled: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Large hero card for the next upcoming event.
private struct NextUpCard: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry
    private var event: Event { entry.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Als Nächstes", systemImage: "sparkles")
                    .font(.caption.weight(.bold)).textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Pill(text: event.kindLabel, symbol: event.kindSymbol, color: .white.opacity(0.22))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(event.name ?? "Termin").font(.title2.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.8)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
            }
            HStack(spacing: 16) {
                if let start = event.start {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(start.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(.de)))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                        Text(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(.de)))
                            .font(.caption)
                            .opacity(0.8)
                    }
                }
                Spacer()
                if let place = event.place, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(20)
        .background {
            ZStack {
                Theme.heroGradient
                event.tint.opacity(0.35).blendMode(.plusLighter)
                Image(systemName: "hockey.puck.fill")
                    .font(.system(size: 150))
                    .foregroundStyle(.white.opacity(0.06))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 120, y: 30)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Theme.night.opacity(0.3), radius: 18, y: 10)
    }
}

struct EventRow: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry
    private var event: Event { entry.event }
    private var isPast: Bool { (event.start ?? .distantFuture) < .now }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(EventDates.shortTime(event.timeStart))
                    .font(.headline.monospacedDigit())
                Text(EventDates.shortTime(event.timeEnd))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52)

            RoundedRectangle(cornerRadius: 3)
                .fill(event.tint.gradient)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: event.kindSymbol).foregroundStyle(event.tint)
                    Text(event.subtitle.isEmpty ? event.kindLabel : event.subtitle)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(event.name ?? "Termin")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                if let place = event.place, !place.isEmpty {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    StatusPill(event: event)
                    if event.eventNotes?.isEmpty == false || entry.detail?.notes?.isEmpty == false {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                    }
                    if (event.hasNotifications ?? 0) > 0 {
                        Image(systemName: "envelope.badge.fill").foregroundStyle(Theme.alert)
                    }
                    Spacer()
                    Image(systemName: state.isNotifying(entry.id) ? "bell.fill" : "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(state.isNotifying(entry.id) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .opacity(isPast ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 18))
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
