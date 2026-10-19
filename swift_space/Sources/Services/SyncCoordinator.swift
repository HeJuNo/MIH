import Foundation
import MyIceKit

/// One sync pass: fetch → diff → persist → notify. Shared by foreground
/// refresh and the BGAppRefreshTask so both behave identically.
enum SyncCoordinator {
    enum Outcome: Sendable {
        case notLoggedIn
        case baseline(entries: Int)
        case synced(changes: [EventChange], notified: Int)
        case failed(String)

        var isSuccess: Bool { if case .failed = self { false } else { true } }

        var summary: String {
            switch self {
            case .notLoggedIn: "nicht angemeldet"
            case let .baseline(n): "Ausgangsstand mit \(n) Terminen"
            case let .synced(changes, notified): "\(changes.count) Änderung(en), \(notified) Benachrichtigung(en)"
            case let .failed(message): "Fehler: \(message)"
            }
        }
    }

    /// Every active club of the player (the original app only showed one at a time).
    static func clubIDs(for user: User, fallback: String?) -> [String] {
        let ids = (user.info.activeClubs ?? []).compactMap(\.clubID)
        return ids.isEmpty ? [user.info.idClub ?? fallback].compactMap { $0 } : ids
    }

    @discardableResult
    static func run(_ env: AppEnvironment = .shared, reason: String, deadline: Date? = nil) async -> Outcome {
        let log = env.log
        guard env.session.loadToken() != nil, let user = env.session.loadUser() else {
            log(.warning, .sync, "Synchronisierung (\(reason)) übersprungen: keine Anmeldung gespeichert")
            return .notLoggedIn
        }
        do {
            let result = try await env.engine.sync(clubIDs: clubIDs(for: user, fallback: env.session.loadSelectedClub()),
                                                   playerID: user.info.idPlayer, deadline: deadline)

            var prefs = env.settings.preferences
            let deliverable = result.changes.filter(env.settings.shouldNotify)
            if deliverable.count < result.changes.count {
                log(.info, .notifications, "\(result.changes.count - deliverable.count) Änderung(en) ohne Benachrichtigung (Termin oder Kategorie ausgeschaltet)")
            }
            // Forget overrides for events that are gone, after filtering their removal notice.
            prefs.prune(keeping: Set(result.entries.map(\.id)))
            env.settings.preferences = prefs

            let posted = await env.notifier.post(deliverable)
            log(.info, .sync, "Synchronisierung (\(reason)): \(result.entries.count) Termine, \(result.changes.count) Änderungen, \(posted) gemeldet")
            return result.wasBaseline ? .baseline(entries: result.entries.count) : .synced(changes: result.changes, notified: posted)
        } catch {
            log(.error, .sync, "Synchronisierung (\(reason)) fehlgeschlagen: \(String(describing: error))")
            return .failed(String(describing: error))
        }
    }
}
