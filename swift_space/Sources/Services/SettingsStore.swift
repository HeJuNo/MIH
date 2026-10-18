import Foundation
import MyIceKit

/// User preferences in UserDefaults. Thread-safe (UserDefaults is), so the
/// background task can read the same values the settings screen writes.
final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.refreshMinutes: 30])
    }

    private enum Key {
        static let preferences = "notificationPreferences"
        static let disabledCategories = "disabledChangeCategories"
        static let refreshMinutes = "backgroundRefreshMinutes"
        static let mapProvider = "mapProvider"
    }

    var mapProvider: MapProvider {
        get { defaults.string(forKey: Key.mapProvider).flatMap(MapProvider.init(rawValue:)) ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Key.mapProvider) }
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
