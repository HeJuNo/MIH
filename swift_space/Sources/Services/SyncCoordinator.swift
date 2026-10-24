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
            case .notLoggedIn: "not signed in"
            case let .baseline(n): "baseline with \(pluralized(n, "event"))"
            case let .synced(changes, notified): "\(pluralized(changes.count, "change")), \(pluralized(notified, "notification"))"
            case let .failed(message): "failed: \(message)"
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
            log(.warning, .sync, "(\(reason)) skipped: not signed in")
            return .notLoggedIn
        }
        do {
            let result = try await env.engine.sync(clubIDs: clubIDs(for: user, fallback: env.session.loadSelectedClub()),
                                                   playerID: user.info.idPlayer, deadline: deadline)

            var prefs = env.settings.preferences
            let deliverable = result.changes.filter(env.settings.shouldNotify)
            if deliverable.count < result.changes.count {
                log(.info, .notifications, "\(pluralized(result.changes.count - deliverable.count, "change")) without notification (event or category muted)")
            }
            // Forget overrides for events that are gone, after filtering their removal notice.
            prefs.prune(keeping: Set(result.entries.map(\.id)))
            env.settings.preferences = prefs

            let posted = await env.notifier.post(deliverable)
            log(.info, .sync, "(\(reason)): \(pluralized(result.entries.count, "event")), \(pluralized(result.changes.count, "change")), \(posted) notified")
            return result.wasBaseline ? .baseline(entries: result.entries.count) : .synced(changes: result.changes, notified: posted)
        } catch {
            log(.error, .sync, "(\(reason)) failed: \(String(describing: error))")
            return .failed(String(describing: error))
        }
    }
}
