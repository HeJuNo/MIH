import MyIceKit
import SwiftUI

/// "Protokoll" tab: everything the app recorded, newest first. The tab itself always stays in
/// place (HIG wants a stable tab set); when logging is off, this explains that instead.
struct LogView: View {
    @Environment(AppState.self) private var state
    @State private var entries: [LogEntry] = []
    @State private var minLevel: LogLevel = .debug
    @State private var area: LogArea?
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        if !state.loggingEnabled {
            NavigationStack {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "Protokoll ist aus",
                               message: "Schalte die Protokollierung in den Einstellungen ein, um Einträge zu sammeln.")
                    .overlay(alignment: .bottom) {
                        Button("Protokollierung einschalten") { state.setLoggingEnabled(true) }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 24)
                    }
                    .navigationTitle("Protokoll")
            }
        } else {
            content
        }
    }

    private var content: some View {
        NavigationStack {
            List {
                if visible.isEmpty {
                    EmptyStateView(symbol: "list.bullet.rectangle", title: entries.isEmpty ? "Noch keine Einträge" : "Keine Treffer",
                                   message: entries.isEmpty
                                       ? "Sobald die App synchronisiert oder im Hintergrund geweckt wird, erscheinen hier die Einträge."
                                       : "Filter oder Suche anpassen.")
                        .listRowBackground(Color.clear)
                }
                ForEach(groupedByDay, id: \.0) { day, items in
                    Section(dayTitle(day)) {
                        ForEach(items) { LogRow(entry: $0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Protokoll durchsuchen")
            .navigationTitle("Protokoll")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: AppLog.text(visible), subject: Text("MyHockey Data Protokoll")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(visible.isEmpty)
                    Button("Leeren", systemImage: "trash") { confirmClear = true }
                        .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog("Protokoll leeren?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Alle Einträge löschen", role: .destructive) {
                    Task {
                        await state.clearLog()
                        entries = []
                    }
                }
            }
            .refreshable { entries = await state.logEntries() }
            .task {
                // Background runs and syncs keep writing; refresh while the tab is visible.
                while !Task.isCancelled {
                    entries = await state.logEntries()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Mindeststufe", selection: $minLevel) {
                ForEach(LogLevel.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("Bereich", selection: $area) {
                Text("Alle Bereiche").tag(LogArea?.none)
                ForEach(LogArea.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
            }
        } label: {
            Image(systemName: minLevel == .debug && area == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var visible: [LogEntry] {
        entries.filter { e in
            e.level >= minLevel && (area.map { e.area == $0 } ?? true)
                && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search) || e.area.title.localizedCaseInsensitiveContains(search))
        }
    }

    private var groupedByDay: [(Date, [LogEntry])] {
        let groups = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Heute" }
        if Calendar.current.isDateInYesterday(day) { return "Gestern" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de))
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.area.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(entry.level >= .warning ? color : .primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.level {
        case .debug: .secondary
        case .info: Theme.accent
        case .warning: Theme.warning
        case .error: Theme.alert
        }
    }
}
