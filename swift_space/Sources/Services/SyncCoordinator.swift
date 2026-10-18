import Foundation
import MyIceKit
import OSLog

/// One sync pass: fetch → diff → persist → notify. Shared by foreground
/// refresh and the BGAppRefreshTask so both behave identically.
enum SyncCoordinator {
    enum Outcome: Sendable {
        case notLoggedIn
        case baseline(entries: Int)
        case synced(changes: [EventChange], notified: Int)
        case failed(String)
    }

    private static let log = Logger(subsystem: "MyHockeyData", category: "sync")

    /// Every active club of the player (the original app only showed one at a time).
    static func clubIDs(for user: User, fallback: String?) -> [String] {
        let ids = (user.info.activeClubs ?? []).compactMap(\.clubID)
        return ids.isEmpty ? [user.info.idClub ?? fallback].compactMap { $0 } : ids
    }

    @discardableResult
    static func run(_ env: AppEnvironment = .shared, reason: String) async -> Outcome {
        guard env.session.loadToken() != nil, let user = env.session.loadUser() else { return .notLoggedIn }
        do {
            let result = try await env.engine.sync(clubIDs: clubIDs(for: user, fallback: env.session.loadSelectedClub()),
                                                   playerID: user.info.idPlayer)

            var prefs = env.settings.preferences
            let deliverable = result.changes.filter(env.settings.shouldNotify)
            // Forget overrides for events that are gone, after filtering their removal notice.
            prefs.prune(keeping: Set(result.entries.map(\.id)))
            env.settings.preferences = prefs

            let posted = await env.notifier.post(deliverable)
            log.info("sync[\(reason, privacy: .public)] entries=\(result.entries.count) changes=\(result.changes.count) notified=\(posted)")
            return result.wasBaseline ? .baseline(entries: result.entries.count) : .synced(changes: result.changes, notified: posted)
        } catch {
            log.error("sync[\(reason, privacy: .public)] failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }
}
