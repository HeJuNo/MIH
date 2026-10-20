import BackgroundTasks
import Foundation
import MyIceKit

/// Periodic wake-ups. Two task types, both registered at launch (`AppDelegate`):
/// * app refresh: short (about 30 s). iOS decides how often, based on how much the
///   app is used, battery and Low Power Mode; `earliestBeginDate` is only a lower bound.
/// * processing: a longer window iOS grants while the device is idle (often overnight).
///   This is an extra chance to run, not a replacement for app refresh.
enum BackgroundRefresh {
    /// Fixed identifiers (not derived from the bundle id), listed in Info.plist.
    static let refreshID = "app.myhockeydata.refresh"
    static let processingID = "app.myhockeydata.processing"
    /// Bundle-derived identifier of earlier builds. No longer in Info.plist, so iOS never runs it,
    /// but a leftover request still occupies the app's single app-refresh slot.
    static let legacyRefreshID = "com.myhockeydata.app.refresh"

    /// Stop starting new requests well before the system limit so there is time to save and notify.
    static let refreshBudget: TimeInterval = 18
    static let processingBudget: TimeInterval = 120

    private static var log: AppLog { AppEnvironment.shared.log }

    /// Must run before the app finishes launching.
    static func register() {
        let refresh = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            run(task, kind: "Hintergrundaktualisierung", budget: refreshBudget)
        }
        let processing = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            run(task, kind: "Hintergrundwartung", budget: processingBudget)
        }
        log(refresh && processing ? .debug : .error, .background,
            "Registrierung: Aktualisierung \(refresh ? "ok" : "fehlgeschlagen"), Wartung \(processing ? "ok" : "fehlgeschlagen")")
    }

    static func schedule(_ env: AppEnvironment = .shared) {
        guard env.session.loadToken() != nil else {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            log(.info, .background, "Nicht angemeldet: keine Hintergrundläufe geplant")
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: legacyRefreshID)

        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, env.settings.refreshMinutes) * 60))
        submit(refresh, "Aktualisierung")

        // Resubmitting replaces the queued request, so doing it on every trip to the background
        // pushed the processing window 2 h out each time and it never came due during the day.
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            guard !pending.contains(where: { $0.identifier == processingID }) else { return }
            let processing = BGProcessingTaskRequest(identifier: processingID)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            processing.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
            submit(processing, "Wartung")
        }
    }

    private static func submit(_ request: BGTaskRequest, _ name: String) {
        do {
            try BGTaskScheduler.shared.submit(request)
            let at = request.earliestBeginDate?.formatted(date: .omitted, time: .shortened) ?? "-"
            log(.debug, .background, "\(name) geplant, frühestens \(at)")
        } catch {
            // Always fails in the simulator, and when Background App Refresh is off.
            log(.error, .background, "\(name) konnte nicht geplant werden: \(describe(error))")
        }
    }

    private static func run(_ task: BGTask, kind: String, budget: TimeInterval) {
        log(.info, .background, "\(kind) gestartet")
        AppEnvironment.shared.settings.lastBackgroundRun = .now
        schedule()   // chain the next wake-up first, in case we are cut short

        let work = Task {
            let outcome = await SyncCoordinator.run(reason: "background", deadline: Date(timeIntervalSinceNow: budget))
            await AppState.shared.reloadFromStore()
            return outcome
        }
        task.expirationHandler = {
            log(.warning, .background, "\(kind): von iOS vorzeitig beendet")
            work.cancel()
        }
        Task {
            let outcome = await work.value
            log(.info, .background, "\(kind) beendet: \(outcome.summary)")
            task.setTaskCompleted(success: outcome.isSuccess)
        }
    }

    /// Debug aid: which wake-ups iOS currently has queued.
    static func logPending() async {
        let pending = await BGTaskScheduler.shared.pendingTaskRequests()
        let list = pending.map { r in
            "\(r.identifier == refreshID ? "Aktualisierung" : r.identifier == processingID ? "Wartung" : r.identifier) ab \(r.earliestBeginDate?.formatted(date: .omitted, time: .shortened) ?? "sofort")"
        }
        log(.debug, .background, list.isEmpty ? "Keine Hintergrundläufe vorgemerkt" : "Vorgemerkt: " + list.joined(separator: ", "))
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? BGTaskScheduler.Error else { return error.localizedDescription }
        switch e.code {
        case .unavailable: return "nicht verfügbar (Hintergrundaktualisierung aus oder Simulator)"
        case .tooManyPendingTaskRequests: return "zu viele vorgemerkte Läufe"
        case .notPermitted: return "nicht erlaubt (Info.plist)"
        default: return e.localizedDescription
        }
    }
}
