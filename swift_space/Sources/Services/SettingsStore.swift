import Foundation
import MyIceKit

/// User preferences in UserDefaults. Thread-safe (UserDefaults is), so the
/// background task can read the same values the settings screen writes.
final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.refreshMinutes: 30, Key.logLevel: LogLevel.info.rawValue])
    }

    private enum Key {
        static let preferences = "notificationPreferences"
        static let disabledCategories = "disabledChangeCategories"
        static let refreshMinutes = "backgroundRefreshMinutes"
        static let mapProvider = "mapProvider"
        static let lastBackgroundRun = "lastBackgroundRun"
        static let loggingEnabled = "loggingEnabled"
        static let logLevel = "logLevel"
        static let disabledLogAreas = "disabledLogAreas"
        static let scheduleFilter = "scheduleFilter"
    }

    /// When iOS last woke the app for a background run (shown in the settings).
    var lastBackgroundRun: Date? {
        get { defaults.object(forKey: Key.lastBackgroundRun) as? Date }
        set { defaults.set(newValue, forKey: Key.lastBackgroundRun) }
    }

    // MARK: Protocol ("Protokoll" tab)

    var loggingEnabled: Bool {
        get { defaults.bool(forKey: Key.loggingEnabled) }
        set { defaults.set(newValue, forKey: Key.loggingEnabled) }
    }

    /// Lowest level that is recorded.
    var logLevel: LogLevel {
        get { LogLevel(rawValue: defaults.integer(forKey: Key.logLevel)) ?? .info }
        set { defaults.set(newValue.rawValue, forKey: Key.logLevel) }
    }

    /// Stored as the disabled set so areas added later are on by default.
    var logAreas: Set<LogArea> {
        get {
            let off = Set((defaults.stringArray(forKey: Key.disabledLogAreas) ?? []).compactMap(LogArea.init(rawValue:)))
            return Set(LogArea.allCases).subtracting(off)
        }
        set { defaults.set(Set(LogArea.allCases).subtracting(newValue).map(\.rawValue).sorted(), forKey: Key.disabledLogAreas) }
    }

    var mapProvider: MapProvider {
        get { defaults.string(forKey: Key.mapProvider).flatMap(MapProvider.init(rawValue:)) ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Key.mapProvider) }
    }

    /// Shared by "Spiele & Trainings" and "Vergangene Termine"; survives relaunches.
    var scheduleFilter: ScheduleFilter {
        get { defaults.data(forKey: Key.scheduleFilter).flatMap { try? JSONDecoder().decode(ScheduleFilter.self, from: $0) } ?? ScheduleFilter() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.scheduleFilter) }
    }

    /// Global default ("Änderungen standardmäßig melden") + per-event overrides.
    var preferences: NotificationPreferences {
        get {
            defaults.data(forKey: Key.preferences)
                .flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) }
                ?? NotificationPreferences(enabledByDefault: true)
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.preferences) }
    }

    var disabledCategories: Set<ChangeKind.Category> {
        get { Set((defaults.stringArray(forKey: Key.disabledCategories) ?? []).compactMap(ChangeKind.Category.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.disabledCategories) }
    }

    /// Earliest interval between background refreshes. iOS decides the actual time.
    var refreshMinutes: Int {
        get { defaults.integer(forKey: Key.refreshMinutes) }
        set { defaults.set(newValue, forKey: Key.refreshMinutes) }
    }

    static let refreshOptions = [15, 30, 60, 120, 240]

    func shouldNotify(_ change: EventChange) -> Bool {
        preferences.isEnabled(change.eventKey) && !disabledCategories.contains(change.kind.category)
    }
}

/// What the schedule and the history show: kind of event and (with several clubs) one club.
struct ScheduleFilter: Codable, Equatable {
    var kind: KindFilter = .all
    var clubID: String?

    var isActive: Bool { kind != .all || clubID != nil }

    func matches(_ entry: TrackedEntry) -> Bool {
        kind.matches(entry.event) && (clubID == nil || entry.clubID == clubID)
    }
}

enum KindFilter: String, Codable, CaseIterable, Identifiable {
    case all, games, practices
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Spiele & Trainings"
        case .games: "Nur Spiele"
        case .practices: "Nur Trainings"
        }
    }

    func matches(_ e: Event) -> Bool {
        switch self {
        case .all: true
        case .games: e.idGame != nil
        case .practices: e.idPractice != nil
        }
    }
}

enum MapProvider: String, CaseIterable, Identifiable {
    case apple, google
    var id: Self { self }
    var title: String { self == .apple ? "Apple Karten" : "Google Maps" }

    /// App URL first; the second URL is the web fallback (Google Maps not installed).
    func urls(for place: String) -> (app: URL, web: URL)? {
        guard let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .apple:
            guard let u = URL(string: "https://maps.apple.com/?q=\(q)") else { return nil }
            return (u, u)
        case .google:
            guard let app = URL(string: "comgooglemaps://?q=\(q)"),
                  let web = URL(string: "https://www.google.com/maps/search/?api=1&query=\(q)") else { return nil }
            return (app, web)
        }
    }

}
