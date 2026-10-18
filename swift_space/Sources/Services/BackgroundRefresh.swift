import BackgroundTasks
import Foundation
import OSLog

/// Periodic wake-ups via BGAppRefreshTask. iOS decides the actual timing
/// (usage patterns, battery, Low Power Mode); `earliestBeginDate` is a lower bound.
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.myhockeydata.app") + ".refresh" }

    private static let log = Logger(subsystem: "MyHockeyData", category: "background")

    static func schedule(_ env: AppEnvironment = .shared) {
        guard env.session.loadToken() != nil else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, env.settings.refreshMinutes) * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("scheduled refresh, earliest \(request.earliestBeginDate!, privacy: .public)")
        } catch {
            // Fails in the simulator and when Background App Refresh is off.
            log.error("could not schedule refresh: \(String(describing: error), privacy: .public)")
        }
    }

    /// Body of the SwiftUI `.backgroundTask(.appRefresh)` handler.
    static func handle() async {
        schedule()   // chain the next wake-up first, in case we are cut short
        await SyncCoordinator.run(reason: "background")
    }
}
