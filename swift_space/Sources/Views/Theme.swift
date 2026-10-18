import MyIceKit
import SwiftUI

enum Theme {
    static let accent = Color.accentColor
    static let night = Color(red: 0.024, green: 0.071, blue: 0.169)
    static let ice = Color(red: 0.353, green: 0.82, blue: 1.0)
    static let alert = Color("Alert")
    static let positive = Color(red: 0.2, green: 0.74, blue: 0.45)
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.2)

    static let heroGradient = LinearGradient(colors: [night, Color(red: 0.04, green: 0.18, blue: 0.39), Color(red: 0.1, green: 0.44, blue: 0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    /// `#rgb` / `#rrggbb` from the backend (`event.color`, `player.hex`).
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Event {
    var tint: Color { Color(hex: color) ?? (kind == .games ? Theme.accent : Theme.ice) }
    var isGame: Bool { idGame != nil }
    var start: Date? { EventDates.start(of: self) }
    var timeRange: String {
        let s = EventDates.shortTime(timeStart), e = EventDates.shortTime(timeEnd)
        return e.isEmpty ? s : "\(s) – \(e)"
    }
    var subtitle: String { [agegroup, practicegroup].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ") }
    var kindLabel: String { isGame ? "Spiel" : "Training" }
    var kindSymbol: String { isGame ? "hockey.puck.fill" : "figure.hockey" }
}

/// Small rounded label used for status and type tags.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color
    var filled = true

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(filled ? .white : color)
        .background(filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.14)), in: Capsule())
    }
}

/// Status pill for an event, mirroring the original card logic.
struct StatusPill: View {
    let event: Event
    var body: some View {
        switch event.availability {
        case .notRequested:
            let h = event.health
            if h == .attending || event.healthStatus == nil {
                Pill(text: "Dabei", symbol: "checkmark", color: Theme.positive)
            } else {
                Pill(text: StatusText.health(h.rawValue), symbol: h == .healthy ? "checkmark" : "xmark",
                     color: h == .healthy ? Theme.positive : Theme.alert)
            }
        case .requested: Pill(text: "Angefragt", symbol: "exclamationmark", color: Theme.warning)
        case .confirmed: Pill(text: "Zugesagt", symbol: "checkmark", color: Theme.positive)
        case .declined: Pill(text: "Abgesagt", symbol: "xmark", color: Theme.alert)
        }
    }
}

/// Grouped card container used throughout the detail screens.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent.gradient)
                .symbolEffect(.pulse, options: .repeating)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
