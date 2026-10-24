import MyIceKit
import SwiftUI

enum Theme {
    static let accent = Color.accentColor
    static let night = Color(red: 0.024, green: 0.071, blue: 0.169)
    static let ice = Color(red: 0.353, green: 0.82, blue: 1.0)
    static let alert = Color("Alert")
    // System colors adapt to dark mode and "Increase Contrast" on their own.
    static let positive = Color(.systemGreen)
    static let warning = Color(.systemOrange)

    static let heroGradient = LinearGradient(colors: [night, Color(red: 0.05, green: 0.2, blue: 0.42)],
                                             startPoint: .top, endPoint: .bottom)

    /// Critically damped: no overshoot unless a gesture supplied momentum.
    static let spring = Animation.spring(duration: 0.3, bounce: 0)
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

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Event {
    var tint: Color { Color(hex: color) ?? (kind == .games ? Theme.accent : Theme.ice) }
    var isGame: Bool { idGame != nil }
    var start: Date? { EventDates.start(of: self) }
    var timeRange: String { EventDates.timeRange(start: timeStart, end: timeEnd) }
    /// End time only when it is plausible (see `EventDates.timeRange`).
    var displayEnd: String? {
        let s = EventDates.shortTime(timeStart), e = EventDates.shortTime(timeEnd)
        return !e.isEmpty && e > s ? e : nil
    }
    var subtitle: String { [agegroup, practicegroup].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ") }
    var kindLabel: String { isGame ? "Spiel" : "Training" }
    var kindSymbol: String {
        if isGame { return "hockey.puck.fill" }
        // Off-ice sessions ("Trockentraining", athletics, strength) get an athlete instead of a hockey player.
        let n = (name ?? "").lowercased()
        if ["trocken", "athletik", "kraft", "off-ice", "office", "lauf"].contains(where: n.contains) { return "figure.run" }
        return "figure.hockey"
    }
}

/// Small rounded label used for status and type tags. Tinted by default; `filled` is for the one
/// thing on screen that should stand out.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color
    var filled = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(filled ? .white : color)
        .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}

/// Status pill for an event, mirroring the original card logic.
struct StatusPill: View {
    let event: Event
    var body: some View {
        let s = EventStatus(event: event)
        Pill(text: s.title, symbol: s.symbol, color: s.color)
    }
}

/// Red, filled marker for an event the club removed from the plan.
struct CancelledPill: View {
    var body: some View {
        Pill(text: EventStatus.cancelledTitle, symbol: "xmark.circle.fill", color: Theme.alert, filled: true)
    }
}

/// Short status of an event: shared by the pill and the VoiceOver label of a row.
struct EventStatus {
    let title: String
    let symbol: String
    let color: Color

    /// Distinct from "Abgesagt", which is the player's own answer to an attendance request.
    static let cancelledTitle = "Termin abgesagt"

    init(event: Event) {
        switch event.availability {
        case .notRequested:
            let h = event.health
            if h == .attending || event.healthStatus == nil {
                (title, symbol, color) = ("Dabei", "checkmark", Theme.positive)
            } else {
                (title, symbol, color) = (StatusText.health(h.rawValue), h == .healthy ? "checkmark" : "xmark",
                                          h == .healthy ? Theme.positive : Theme.alert)
            }
        case .requested: (title, symbol, color) = ("Angefragt", "questionmark", Theme.warning)
        case .confirmed: (title, symbol, color) = ("Zugesagt", "checkmark", Theme.positive)
        case .declined: (title, symbol, color) = ("Abgesagt", "xmark", Theme.alert)
        }
    }
}

/// Rounded, colored glyph in the style of the iOS Settings app.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}

/// Native empty state, quiet by design (no looping animation).
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

/// Immediate, subtle feedback on touch-down for custom tappable surfaces.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

extension View {
    /// Rounded hero surface in an event's color; flat, without drop shadow or decoration.
    func heroBackground(_ tint: Color) -> some View {
        background {
            LinearGradient(colors: [tint.mix(with: .black, by: 0.15), tint.mix(with: Theme.night, by: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Lets the tab bar shrink while scrolling on iOS 26; no-op before.
    @ViewBuilder func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
