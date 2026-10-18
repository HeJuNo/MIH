import Foundation

public enum EventKind: String, Codable, Sendable { case games, practices }

/// `health_status` / `id_status`.
public enum HealthStatus: Int, Codable, CaseIterable, Sendable {
    case healthy = 1
    /// Not user-selectable; set after the player confirms participation (`available = 2`).
    case attending = 3
    case excused = 6
    case sick = 8
    case injured = 9

    /// Codes the user can pick in the status sheet.
    public static let selectable: [HealthStatus] = [.healthy, .excused, .sick, .injured]

    /// The JS client falls back to "healthy" for unknown codes.
    public init(code: Int?) { self = code.flatMap(HealthStatus.init(rawValue:)) ?? .healthy }

    public var isPositive: Bool { self == .healthy || self == .attending }
    public var localizationKey: String { "health_\(rawValue)" }
}

/// `available` — staff attendance request state for games.
public enum Availability: Int, Codable, Sendable {
    case notRequested = 0
    case requested = 1
    case confirmed = 2
    case declined = 3

    public init(code: Int?) { self = code.flatMap(Availability.init(rawValue:)) ?? .notRequested }
}

/// Visual semantics only; concrete colours belong to the app's own design system.
public enum StatusTone: Sendable { case positive, warning, negative, neutral }

public extension Event {
    var availability: Availability { Availability(code: available) }
    var health: HealthStatus { HealthStatus(code: healthStatus) }

    /// Card badge: health state when no request is pending, otherwise the request state.
    var badge: (tone: StatusTone, localizationKey: String) {
        switch availability {
        case .notRequested:
            return (health == .healthy ? .positive : .negative, health.localizationKey)
        case .requested: return (.warning, "available_1")
        case .confirmed: return (.positive, "available_2")
        case .declined: return (.negative, "available_3")
        }
    }
}
