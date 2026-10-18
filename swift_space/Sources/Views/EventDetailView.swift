import MyIceKit
import SwiftUI

/// Detail of one entry: Übersicht · Personen (Staff & Spieler) · Mitteilungen.
struct EventDetailView: View {
    @Environment(AppState.self) private var state
    let eventKey: String
    @State private var section: Section = .overview
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
        return ScrollView {
            VStack(spacing: 16) {
                DetailHero(entry: entry)

                Picker("Bereich", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch section {
                    case .overview: OverviewSection(entry: entry)
                    case .people: PeopleSection(entry: entry)
                    case .messages: MessagesSection(entry: entry)
                    }
                }
                .padding(.horizontal)
                .animation(.snappy, value: section)
            }
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entry.event.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .overlay(alignment: .top) {
            if loading && entry.detail == nil { ProgressView().padding(.top, 260) }
        }
        .refreshable { await state.loadDetail(for: entry) }
        .task(id: eventKey) {
            loading = true
            await state.loadDetail(for: entry)
            loading = false
        }
    }
}

// MARK: - Hero

private struct DetailHero: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry
    private var event: Event { entry.event }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Pill(text: entry.detail?.type ?? event.kindLabel, symbol: event.kindSymbol, color: .white.opacity(0.22))
                if let away = entry.detail?.isAway, !away.isEmpty {
                    Pill(text: homeAway(away), color: .white.opacity(0.22))
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                if !event.subtitle.isEmpty {
                    Text(event.subtitle).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                }
                Text(event.name ?? "Termin").font(.title3.weight(.bold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let start = event.start {
                    HeroChip(symbol: "calendar", text: start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.de)))
                }
                HeroChip(symbol: "clock", text: event.timeRange.isEmpty ? "Zeit folgt" : event.timeRange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [event.tint, Theme.night], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: event.kindSymbol)
                    .font(.system(size: 140))
                    .foregroundStyle(.white.opacity(0.07))
                    .offset(x: 30, y: -10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal)
        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
    }
}

private func homeAway(_ raw: String) -> String {
    let t = PlainText.from(html: raw)
    switch t.lowercased() {
    case "home", "heim": return "Heim"
    case "away", "auswärts", "auswaerts": return "Auswärts"
    default: return t.capitalized
    }
}

private struct HeroChip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.16), in: Capsule())
            .foregroundStyle(.white)
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
        VStack(spacing: 14) {
            AttendanceCard(entry: entry)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                InfoTile(symbol: "mappin.and.ellipse", label: "Ort", value: event.place, span: true)
                InfoTile(symbol: "calendar", label: "Datum",
                         value: event.start?.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.de)))
                InfoTile(symbol: "clock", label: "Zeit", value: event.timeRange.isEmpty ? "Zeit folgt" : event.timeRange)
                if event.isGame {
                    InfoTile(symbol: "bus.fill", label: nonEmpty(detail?.departure) ?? "Abfahrt",
                             value: EventDates.meaningfulTime(detail?.departureTime))
                    InfoTile(symbol: "person.2.wave.2.fill", label: nonEmpty(detail?.meeting) ?? "Treffpunkt",
                             value: EventDates.meaningfulTime(detail?.meetingTime))
                }
            }

            if let notes = detail?.notes, !PlainText.from(html: notes).isEmpty {
                Card(title: "Notizen", symbol: "note.text") {
                    Text(PlainText.from(html: notes))
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }

            if let place = event.place, !place.isEmpty, let urls = state.mapProvider.urls(for: place) {
                Button {
                    openURL(urls.app) { accepted in if !accepted { openURL(urls.web) } }
                } label: {
                    Label("In \(state.mapProvider.title) öffnen", systemImage: "map.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

private func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }

private struct AttendanceCard: View {
    let entry: TrackedEntry
    @State private var editing = false
    private var event: Event { entry.event }
    private var detail: EventDetail? { entry.detail }
    /// Like the original app: only before the event starts, never for archived entries.
    private var editable: Bool { StatusRules.isEditable(event) && entry.archivedAt == nil }

    var body: some View {
        let availability = Availability(code: detail?.available ?? event.available)
        let health = HealthStatus(code: detail?.healthStatus ?? event.healthStatus)
        let notes = (detail?.healthNotes ?? event.healthStatusNotes)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let (color, symbol, title, subtitle) = describe(availability, health)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(color.gradient, in: Circle())
                    .foregroundStyle(.white)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if editable {
                    Button { editing = true } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(color)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Status ändern")
                }
            }
            if let notes, !notes.isEmpty {
                Text(notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
        }
        .sheet(isPresented: $editing) { StatusSheet(entry: entry) }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Title stays on one line; the only inline extra is the date of an attendance answer.
    private func describe(_ a: Availability, _ h: HealthStatus) -> (Color, String, String, String?) {
        let since = detail?.availableDate.flatMap(EventDates.parseDay)?.formatted(.dateTime.day().month().locale(.de))
        switch a {
        case .requested: return (Theme.warning, "exclamationmark", "Anwesenheit angefragt", since)
        case .confirmed: return (Theme.positive, "checkmark", "Zugesagt", since)
        case .declined: return (Theme.alert, "xmark", "Abgesagt", since)
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

private struct InfoTile: View {
    let symbol: String
    let label: String
    let value: String?
    var span = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "–")
                .font(.footnote.weight(.semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gridCellColumns(span ? 2 : 1)
    }
}

// MARK: - People

private struct PeopleSection: View {
    let entry: TrackedEntry

    var body: some View {
        let c = entry.detail?.convocation
        let staff = c?.staff ?? []
        let players = StatusRules.sortedRoster(c?.available ?? [])

        if entry.detail == nil {
            EmptyStateView(symbol: "person.3", title: "Noch keine Daten", message: "Die Details werden geladen.")
        } else if staff.isEmpty && players.isEmpty {
            EmptyStateView(symbol: "person.3", title: "Kein Aufgebot",
                           message: Availability(code: entry.detail?.available) == .notRequested
                               ? "Für diesen Termin wurde noch kein Aufgebot veröffentlicht."
                               : "Das Aufgebot ist sichtbar, sobald deine Teilnahme feststeht.")
        } else {
            VStack(spacing: 14) {
                if !players.isEmpty, let c {
                    HStack(spacing: 10) {
                        CountBadge(label: "Tor", value: c.availableTotalG ?? count(players, "G"), color: .purple)
                        CountBadge(label: "Verteidigung", value: c.availableTotalD ?? count(players, "D"), color: .blue)
                        CountBadge(label: "Sturm", value: c.availableTotalF ?? count(players, "F"), color: .orange)
                        CountBadge(label: "Gesamt", value: c.availableTotal ?? players.count, color: .gray)
                    }
                }

                if !staff.isEmpty {
                    Card(title: "Staff · \(staff.count)", symbol: "person.badge.shield.checkmark") {
                        ForEach(Array(staff.enumerated()), id: \.offset) { i, s in
                            PersonRow(leading: AnyView(Avatar(name: name(s.fname, s.lname), color: Theme.accent)),
                                      name: name(s.fname, s.lname), trailing: s.role)
                            if i < staff.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }

                ForEach(positionGroups(players), id: \.title) { group in
                    Card(title: "\(group.title) · \(group.players.count)", symbol: group.symbol) {
                        ForEach(Array(group.players.enumerated()), id: \.offset) { i, p in
                            PersonRow(leading: AnyView(leading(p)), name: name(p.fname, p.lname), trailing: p.position?.isEmpty == false ? p.position : nil)
                            if i < group.players.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func leading(_ p: Convocation.Player) -> some View {
        if entry.detail?.category == EventKind.games.rawValue, let n = p.number, !n.isEmpty {
            Text(n)
                .font(.footnote.monospacedDigit().weight(.bold))
                .frame(width: 32, height: 32)
                .background(entry.event.tint.gradient, in: Circle())
                .foregroundStyle(.white)
        } else {
            Avatar(name: name(p.fname, p.lname), color: Color(hex: p.hex) ?? entry.event.tint)
        }
    }

    private struct Group { let title: String; let symbol: String; let players: [Convocation.Player] }

    private func positionGroups(_ players: [Convocation.Player]) -> [Group] {
        let defs: [(String?, String, String)] = [("G", "Tor", "shield.lefthalf.filled"), ("D", "Verteidigung", "rectangle.split.3x1"),
                                                 ("F", "Sturm", "bolt.fill"), (nil, "Spieler", "person.fill")]
        return defs.compactMap { pos, title, symbol in
            let ps = players.filter { p in
                pos.map { p.position == $0 } ?? !["G", "D", "F"].contains(p.position ?? "")
            }
            return ps.isEmpty ? nil : Group(title: title, symbol: symbol, players: ps)
        }
    }

    private func count(_ ps: [Convocation.Player], _ pos: String) -> Int { ps.filter { $0.position == pos }.count }
    private func name(_ f: String?, _ l: String?) -> String { [f, l].compactMap { $0 }.joined(separator: " ") }
}

private struct PersonRow: View {
    let leading: AnyView
    let name: String
    let trailing: String?
    var body: some View {
        HStack(spacing: 14) {
            leading
            Text(name).font(.subheadline)
            Spacer()
            if let trailing { Text(trailing).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
        }
    }
}

private struct Avatar: View {
    let name: String
    let color: Color
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
            .font(.caption2.weight(.bold))
            .frame(width: 32, height: 32)
            .background(color.opacity(0.18), in: Circle())
            .foregroundStyle(color)
    }
}

private struct CountBadge: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Messages

private struct MessagesSection: View {
    @Environment(AppState.self) private var state
    let entry: TrackedEntry

    var body: some View {
        let messages = entry.detail?.notifications ?? []
        let changes = state.changes(for: entry.id)
        VStack(spacing: 14) {
            Card(title: "Mitteilungen vom Verein", symbol: "envelope") {
                if messages.isEmpty {
                    Text("Keine Mitteilungen zu diesem Termin.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(messages) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(m.isRead == 1 ? Color.clear : Theme.alert).frame(width: 8, height: 8)
                                Text(m.subject ?? "Mitteilung").font(.footnote.weight(.semibold))
                                Spacer()
                                if let d = m.date { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                            if let body = m.message, !body.isEmpty {
                                Text(body).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let f = m.fname {
                                Text("– \(f) \(m.lname ?? "")").font(.caption.italic()).foregroundStyle(.tertiary)
                            }
                        }
                        if m.id != messages.last?.id { Divider() }
                    }
                }
            }

            Card(title: "Erkannte Änderungen", symbol: "clock.arrow.circlepath") {
                if changes.isEmpty {
                    Text("Seit Beginn der Überwachung keine Änderungen.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(changes) { change in
                        ChangeLine(change: change, showEvent: false)
                        if change.id != changes.last?.id { Divider() }
                    }
                }
            }
        }
    }
}
