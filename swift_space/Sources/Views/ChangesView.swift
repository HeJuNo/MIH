import MyIceKit
import SwiftUI

/// Timeline of every detected change, newest first.
struct ChangesView: View {
    @Environment(AppState.self) private var state
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if state.changeLog.isEmpty {
                    EmptyStateView(symbol: "bell.and.waves.left.and.right", title: "Noch keine Änderungen",
                                   message: "MyHockey Data prüft deine Spiele & Trainings regelmäßig im Hintergrund und meldet jede Änderung.")
                        .listRowBackground(Color.clear)
                }
                ForEach(groupedByDay, id: \.0) { day, changes in
                    Section {
                        ForEach(changes) { change in
                            // Removed events stay openable (read-only); only entries lost before
                            // they were kept, or trimmed from the archive, have nothing to open.
                            if state.entry(for: change.eventKey) != nil {
                                Button { state.open(eventKey: change.eventKey) } label: {
                                    ChangeLine(change: change, showEvent: true)
                                }
                                .foregroundStyle(.primary)
                                .accessibilityHint("Öffnet den Termin")
                            } else {
                                ChangeLine(change: change, showEvent: true)
                            }
                        }
                    } header: {
                        Text(dayTitle(day)).font(.headline).foregroundStyle(.primary).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Änderungen")
            .refreshable { await state.refresh() }
            .toolbar {
                if !state.changeLog.isEmpty {
                    Menu {
                        Button("Verlauf löschen", systemImage: "trash", role: .destructive) { confirmClear = true }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Mehr")
                }
            }
            .confirmationDialog("Verlauf löschen?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Alle Änderungen löschen", role: .destructive) {
                    Task { await state.clearChangeLog() }
                }
            } message: {
                Text("Das kann nicht rückgängig gemacht werden.")
            }
            .onAppear { state.markChangesSeen() }
            .onChange(of: state.changeLog.count) { state.markChangesSeen() }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Heute" }
        if Calendar.current.isDateInYesterday(day) { return "Gestern" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de))
    }

    private var groupedByDay: [(Date, [EventChange])] {
        let groups = Dictionary(grouping: state.changeLog) { Calendar.current.startOfDay(for: $0.detectedAt) }
        return groups.keys.sorted(by: >).map { day in (day, groups[day]!.sorted { $0.detectedAt > $1.detectedAt }) }
    }
}

struct ChangeLine: View {
    let change: EventChange
    let showEvent: Bool

    var body: some View {
        let text = ChangeFormatter.text(for: change)
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(symbol: text.symbol, color: color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.headline).font(.body.weight(.semibold))
                    Spacer()
                    // The list groups by day; inside a detail the day is needed too.
                    Text(change.detectedAt, format: showEvent
                         ? .dateTime.hour().minute()
                         : .dateTime.day().month(.twoDigits).year(.twoDigits).hour().minute().locale(.de))
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
                if showEvent {
                    Text([ChangeFormatter.eventLabel(change), ChangeFormatter.eventWhen(change)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.tint).lineLimit(2)
                }
                if !text.detail.isEmpty {
                    Text(text.detail).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(change.kind.category == .people ? nil : 4)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch change.kind.category {
        case .added: Theme.positive
        case .removed: Theme.alert
        case .schedule: Theme.accent
        case .info: .teal
        case .status: Theme.warning
        case .people: .indigo
        case .message: .pink
        }
    }
}
