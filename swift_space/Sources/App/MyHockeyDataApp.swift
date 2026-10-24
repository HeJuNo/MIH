import SwiftUI
import UserNotifications

@main
struct MyHockeyDataApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .tint(Theme.accent)
                .preferredColorScheme(state.appearance.colorScheme)
                .task { await state.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await state.didBecomeActive() }
            case .background:
                AppEnvironment.shared.log(.debug, .app, "In background")
                BackgroundRefresh.schedule()
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AppEnvironment.shared.log(.info, .app, "Launched" + (launchOptions?.isEmpty == false ? " (by the system)" : ""))
        BackgroundRefresh.register()
        return true
    }

    // Show change banners while the app is open, too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Tapping a change notification opens that event.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let key = response.notification.request.content.userInfo[ChangeNotifier.eventKeyUserInfo] as? String else { return }
        AppEnvironment.shared.log(.debug, .notifications, "Opened: \(key)")
        await MainActor.run { AppState.shared.open(eventKey: key) }
    }
}
