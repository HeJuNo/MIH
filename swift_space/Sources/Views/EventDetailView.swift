import MyIceKit
import SwiftUI

/// Detail of one entry: Übersicht · Personen (Staff & Spieler) · Mitteilungen.
struct EventDetailView: View {
    @Environment(AppState.self) private var state
    let eventKey: String
    @State private var section: Section = {
        #if DEBUG
        switch DemoData.section {
        case "people": return .people
        case "messages": return .messages
        default: break
        }
        #endif
        return .overview
    }()
    @State private var loading = false

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Übersicht", people = "Personen", messages = "Mitteilungen"
        var id: Self { self }
    }

    var body: some View {
        if let entry = state.entry(for: eventKey) {
            content(entry)
        } else {
            EmptyStateView(symbol: "calendar.badge.minus", title: "Termin nicht mehr vorhanden",
                           message: "Dieser Termin ist nicht mehr in deinem Plan.")
        }
    }

    private func content(_ entry: TrackedEntry) -> some View {
        let notifying = state.isNotifying(entry.id)
        return List {
            SwiftUI.Section {
                DetailHero(entry: entry)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let cancelledAt = entry.cancelledAt {
                SwiftUI.Section {
                    CancelledNotice(cancelledAt: cancelledAt)
                }
            }

            Picker("Bereich", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)

            switch section {
            case .overview: OverviewSection(entry: entry)
            case .people: PeopleSection(entry: entry, loading: loading)
            case .messages: MessagesSection(entry: entry)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .animation(Theme.spring, value: section)
        .navigationTitle(entry.event.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entry.isCancelled {
                ToolbarItem(placement: .topBarTrailing) { notifyButton(entry: entry, notifying: notifying) }
            }
        }
        .refreshable { await state.loadDetail(for: entry) }
        .task(id: eventKey) {
            loading = true
            await state.loadDetail(for: entry)
            loading = false
        }
    }

    private func notifyButton(entry: TrackedEntry, notifying: Bool) -> some View {
        Button {
            state.setNotifying(!notifying, for: entry.id)
        } label: {
            Image(systemName: notifying ? "bell.fill" : "bell.slash")
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.selection, trigger: notifying)
        .accessibilityLabel(notifying ? "Benachrichtigungen ausschalten" : "Benachrichtigungen einschalten")
    }
}

/// Shown above the details of an event the club removed; the details below are its last known state.
private struct CancelledNotice: View {
    let cancelledAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(symbol: "xmark", color: Theme.alert)
            VStack(alignment: .leading, spacing: 2) {
                Text(EventStatus.cancelledTitle).font(.body.weight(.semibold))
                Text("Am \(cancelledAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(.de))) aus dem Plan entfernt. Angezeigt wird der letzte bekannte Stand.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero

private struct DetailHero: View {
    let entry: TrackedEntry
    private var event: Event { entry.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: event.kindSymbol)
                Text([entry.detail?.type ?? event.kindLabel, entry.detail?.isAway.flatMap(homeAway)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))

            if entry.isCancelled {
                Pill(text: EventStatus.cancelledTitle, symbol: "xmark.circle.fill", color: .white, filled: false)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.name ?? "Termin")
                    .font(.title2.weight(.bold))
                    .strikethrough(entry.isCancelled)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
            }

            // Date and time on their own lines, like Calendar.
            VStack(alignment: .leading, spacing: 4) {
                if let start = event.start {
                    Label(start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de)), systemImage: "calendar")
                }
                Label(event.timeRange.isEmpty ? "Zeit folgt" : event.timeRange, systemImage: "clock")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroBackground(event.tint)
        .accessibilityElement(children: .combine)
    }
}

private func homeAway(_ raw: String) -> String? {
    let t = PlainText.from(html: raw)
    switch t.lowercased() {
    case "": return nil
    case "home", "heim": return "Heim"
    case "away", "auswärts", "auswaerts": return "Auswärts"
    default: return t.capitalized
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    let entry: TrackedEntry
    private var event: Event { entry.event }
    private var detail: EventDetail? { entry.detail }

    var body: some View {
        SwiftUI.Section {
            AttendanceRow(entry: entry)
        }

        SwiftUI.Section {
            DetailRow(symbol: "mappin.and.ellipse", label: "Ort", value: event.place)
            if let place = event.place, !place.isEmpty, let urls = state.mapProvider.urls(for: place) {
                Button {
                    openURL(urls.app) { accepted in if !accepted { openURL(urls.web) } }
                } label: {
                    Label("In \(state.mapProvider.title) öffnen", systemImage: "map")
                }
            }
            if event.isGame {
                DetailRow(symbol: "bus", label: nonEmpty(detail?.departure) ?? "Abfahrt",
                          value: EventDates.meaningfulTime(detail?.departureTime))
                DetailRow(symbol: "person.2.wave.2", label: nonEmpty(detail?.meeting) ?? "Treffpunkt",
                          value: EventDates.meaningfulTime(detail?.meetingTime))
            }
        }

        if let notes = detail?.notes, !PlainText.from(html: notes).isEmpty {
            SwiftUI.Section("Notizen") {
                Text(PlainText.from(html: notes))
                    .textSelection(.enabled)
            }
        }
    }
}

private func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }

/// Contacts-style row: small label above the value, icon in the leading column.
private struct DetailRow: View {
    let symbol: String
    let label: String
    let value: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                Text(value?.isEmpty == false ? value! : "–")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AttendanceRow: View {
    let entry: TrackedEntry
    @State private var editing: Bool = {
        #if DEBUG
        return DemoData.opensStatus
        #else
        return false
        #endif
    }()
    private var event: Event { entry.event }
    private var detail: EventDetail? { entry.detail }
    /// Like the original app: only before the event starts, never for archived or cancelled entries.
    private var editable: Bool { StatusRules.isEditable(event) && entry.archivedAt == nil && !entry.isCancelled }

    var body: some View {
        let availability = Availability(code: detail?.available ?? event.available)
        let health = HealthStatus(code: detail?.healthStatus ?? event.healthStatus)
        let notes = (detail?.healthNotes ?? event.healthStatusNotes)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let (color, symbol, title, subtitle) = describe(availability, health)

        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                ForEach([subtitle, notes].compactMap { $0?.isEmpty == false ? $0 : nil }, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if editable {
                Button("Ändern") { editing = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Status ändern")
                    // Keeps the compact capsule look while meeting the 44×44pt minimum tap target.
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $editing) { StatusSheet(entry: entry) }
    }

    /// The only inline extra next to an attendance answer is its date.
    private func describe(_ a: Availability, _ h: HealthStatus) -> (Color, String, String, String?) {
        let since = detail?.availableDate.flatMap(EventDates.parseDay)?.formatted(.dateTime.day().month(.wide).locale(.de))
        let answered = since.map { "Beantwortet am \($0)" }
        switch a {
        case .requested: return (Theme.warning, "questionmark", "Anwesenheit angefragt", since.map { "Seit \($0)" })
        case .confirmed: return (Theme.positive, "checkmark", "Zugesagt", answered)
        case .declined: return (Theme.alert, "xmark", "Abgesagt", answered)
        case .notRequested:
            switch h {
            case .healthy, .attending: return (Theme.positive, "checkmark", StatusText.health(h.rawValue), nil)
            case .excused: return (Theme.warning, "calendar.badge.minus", StatusText.health(h.rawValue), nil)
            case .sick: return (Theme.alert, "thermometer.medium", StatusText.health(h.rawValue), nil)
            case .injured: return (Theme.alert, "bandage.fill", StatusText.health(h.rawValue), nil)
            }
        }
    }
}

// MARK: - People

private struct PeopleSection: View {
    let entry: TrackedEntry
    let loading: Bool

    var body: some View {
        let c = entry.detail?.convocation
        let staff = c?.staff ?? []
        let players = StatusRules.sortedRoster(c?.available ?? [])

        if entry.detail == nil {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    EmptyStateView(symbol: "person.3", title: "Noch keine Daten", message: "Zum Laden nach unten ziehen.")
                }
            }
            .listRowBackground(Color.clear)
        } else if staff.isEmpty && players.isEmpty {
            EmptyStateView(symbol: "person.3", title: "Kein Aufgebot",
                           message: Availability(code: entry.detail?.available) == .notRequested
                               ? "Für diesen Termin wurde noch kein Aufgebot veröffentlicht."
                               : "Das Aufgebot ist sichtbar, sobald deine Teilnahme feststeht.")
                .listRowBackground(Color.clear)
        } else {
            if !players.isEmpty, let c {
                SwiftUI.Section {
                    HStack(spacing: 0) {
                        Stat(label: "Tor", value: c.availableTotalG ?? count(players, "G"))
                        Divider()
                        Stat(label: "Verteidigung", value: c.availableTotalD ?? count(players, "D"))
                        Divider()
                        Stat(label: "Sturm", value: c.availableTotalF ?? count(players, "F"))
                        Divider()
                        Stat(label: "Gesamt", value: c.availableTotal ?? players.count, emphasized: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !staff.isEmpty {
                SwiftUI.Section("Staff") {
                    ForEach(Array(staff.enumerated()), id: \.offset) { _, s in
                        PersonRow(name: name(s.fname, s.lname), trailing: s.role) {
                            Avatar(name: name(s.fname, s.lname), color: .gray)
                        }
                    }
                }
            }

            ForEach(positionGroups(players), id: \.title) { group in
                SwiftUI.Section("\(group.title) · \(group.players.count)") {
                    ForEach(Array(group.players.enumerated()), id: \.offset) { _, p in
                        PersonRow(name: name(p.fname, p.lname), trailing: nil) { leading(p) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func leading(_ p: Convocation.Player) -> some View {
        if entry.detail?.category == EventKind.games.rawValue, let n = p.number, !n.isEmpty {
            NumberBadge(number: n, color: entry.event.tint)
        } else {
            Avatar(name: name(p.fname, p.lname), color: Color(hex: p.hex) ?? entry.event.tint)
        }
    }

    private struct PositionGroup { let title: String; let players: [Convocation.Player] }

    private func positionGroups(_ players: [Convocation.Player]) -> [PositionGroup] {
        let defs: [(String?, String)] = [("G", "Tor"), ("D", "Verteidigung"), ("F", "Sturm"), (nil, "Spieler")]
        return defs.compactMap { pos, title in
            let ps = players.filter { p in
                pos.map { p.position == $0 } ?? !["G", "D", "F"].contains(p.position ?? "")
            }
            return ps.isEmpty ? nil : PositionGroup(title: title, players: ps)
        }
    }

    private func count(_ ps: [Convocation.Player], _ pos: String) -> Int { ps.filter { $0.position == pos }.count }
    private func name(_ f: String?, _ l: String?) -> String { [f, l].compactMap { $0 }.joined(separator: " ") }
}

private struct Stat: View {
    let label: String
    let value: Int
    var emphasized = false
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct PersonRow<Leading: View>: View {
    let name: String
    let trailing: String?
    @ViewBuilder var leading: Leading
    var body: some View {
        HStack(spacing: 12) {
            leading
            Text(name)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Avatar: View {
    let name: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size = 32
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: Circle())
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

private struct NumberBadge: View {
    let number: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size = 32
    var body: some View {
        Text(number)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded).monospacedDigit())
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .foregroundStyle(.white)
            .accessibilityLabel("Nummer \(number)")
    }
}

// MARK: - Messages

private struct MessagesSection: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry

    var body: some View {
        let messages = entry.detail?.notifications ?? []
        let changes = state.changes(for: entry.id)

        SwiftUI.Section("Mitteilungen vom Verein") {
            if messages.isEmpty {
                Text("Keine Mitteilungen zu diesem Termin.").foregroundStyle(.secondary)
            } else {
                ForEach(messages) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if m.isRead != 1 {
                                Circle().fill(.tint).frame(width: 8, height: 8)
                                    .accessibilityLabel("Ungelesen")
                            }
                            Text(m.subject ?? "Mitteilung").font(.body.weight(.semibold))
                            Spacer()
                            if let d = m.date { Text(d).font(.footnote).foregroundStyle(.secondary) }
                        }
                        if let body = m.message, !body.isEmpty {
                            Text(body).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let f = m.fname {
                            Text("\(f) \(m.lname ?? "")").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        SwiftUI.Section("Erkannte Änderungen") {
            if changes.isEmpty {
                Text("Seit Beginn der Überwachung keine Änderungen.").foregroundStyle(.secondary)
            } else {
                ForEach(changes) { change in
                    ChangeLine(change: change, showEvent: false)
                }
            }
        }
    }
}
