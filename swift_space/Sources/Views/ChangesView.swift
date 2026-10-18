import MyIceKit
import SwiftUI

/// Timeline of every detected change, newest first.
struct ChangesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationStack {
            List {
                if state.changeLog.isEmpty {
                    EmptyStateView(symbol: "bell.and.waves.left.and.right", title: "Noch keine Änderungen",
                                   message: "MyHockey Data prüft deine Spiele & Trainings regelmäßig im Hintergrund und meldet jede Änderung.")
                        .listRowBackground(Color.clear)
                }
                ForEach(groupedByDay, id: \.0) { day, changes in
                    Section(day.formatted(.relative(presentation: .named).locale(.de)).capitalized) {
                        ForEach(changes) { change in
                            Button { state.open(eventKey: change.eventKey) } label: {
                                ChangeLine(change: change, showEvent: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.entry(for: change.eventKey) == nil)
                        }
                    }
                }
            }
            .navigationTitle("Änderungen")
            .refreshable { await state.refresh() }
            .toolbar {
                if !state.changeLog.isEmpty {
                    Menu {
                        Button("Verlauf löschen", systemImage: "trash", role: .destructive) {
                            Task { await state.clearChangeLog() }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onAppear { state.markChangesSeen() }
            .onChange(of: state.changeLog.count) { state.markChangesSeen() }
        }
    }

    private var groupedByDay: [(Date, [EventChange])] {
        let groups = Dictionary(grouping: state.changeLog) { Calendar.current.startOfDay(for: $0.detectedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }
}

struct ChangeLine: View {
    let change: EventChange
    let showEvent: Bool

    var body: some View {
        let text = ChangeFormatter.text(for: change)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: text.symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.headline).font(.footnote.weight(.semibold))
                    Spacer()
                    Text(change.detectedAt, format: .dateTime.hour().minute())
                        .font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
                if showEvent {
                    Text(change.eventTitle).font(.caption.weight(.medium)).foregroundStyle(.tint).lineLimit(1)
                }
                if !text.detail.isEmpty {
                    Text(text.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .padding(.vertical, 4)
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
