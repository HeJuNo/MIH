import Foundation
import MyIceKit
import Observation
import UIKit
import UserNotifications

/// UI state. Persistence and networking live in `AppEnvironment`; this class
/// mirrors what's stored so views stay simple and reactive.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum Tab: Hashable { case schedule, changes, settings }

    // Session
    private(set) var user: User?
    private(set) var selectedClubID: String?
    var isLoggedIn: Bool { user != nil }

    // Data
    private(set) var entries: [TrackedEntry] = []
    private(set) var changeLog: [EventChange] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var unseenChanges = 0

    // Settings mirror
    private(set) var preferences = NotificationPreferences()
    private(set) var disabledCategories: Set<ChangeKind.Category> = []
    private(set) var refreshMinutes = 30
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var backgroundRefreshStatus: UIBackgroundRefreshStatus = .available

    // Navigation
    var selectedTab: Tab = .schedule
    var schedulePath: [String] = []

    private let env: AppEnvironment
    private var seenChangeIDs: Set<UUID> = []

    init(env: AppEnvironment = .shared) {
        self.env = env
    }

    // MARK: Lifecycle

    func bootstrap() async {
        #if DEBUG
        if DemoData.isEnabled {
            user = DemoData.user
            entries = DemoData.entries()
            changeLog = DemoData.changes(for: entries)
            unseenChanges = 2
            lastSync = .now.addingTimeInterval(-420)
            preferences.set(false, for: entries[3].id)
            if ProcessInfo.processInfo.arguments.contains("-demoDetail") { schedulePath = [entries[2].id] }
            if let tab = UserDefaults.standard.string(forKey: "demoTab") {
                selectedTab = tab == "changes" ? .changes : tab == "settings" ? .settings : .schedule
            }
            return
        }
        #endif
        user = env.session.loadUser()
        selectedClubID = env.session.loadSelectedClub()
        loadSettings()
        await reloadFromStore()
        seenChangeIDs = Set(changeLog.map(\.id))
        await refreshSystemStatus()
        if isLoggedIn {
            BackgroundRefresh.schedule()
            await refresh(reason: "launch")
        }
    }

    func didBecomeActive() async {
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        await refreshSystemStatus()
        await reloadFromStore()
        guard isLoggedIn else { return }
        // Avoid hammering the API when quickly switching apps.
        if (lastSync.map { Date().timeIntervalSince($0) > 5 * 60 }) ?? true {
            await refresh(reason: "foreground")
        }
    }

    func reloadFromStore() async {
        let state = await env.syncStore.load()
        entries = state.entries
        changeLog = state.changeLog
        lastSync = state.lastSync
        lastError = state.lastError
        unseenChanges = changeLog.filter { !seenChangeIDs.contains($0.id) }.count
    }

    func refresh(reason: String = "manual") async {
        guard isLoggedIn, !isSyncing else { return }
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        isSyncing = true
        defer { isSyncing = false }
        let outcome = await SyncCoordinator.run(env, reason: reason)
        if case .failed(let message) = outcome { lastError = message }
        await reloadFromStore()
        preferences = env.settings.preferences
    }

    // MARK: Session

    func login(email: String, password: String) async throws {
        let payload: SessionPayload = try await env.api.send(.login(email: email, password: password))
        guard payload.status == 1, let token = payload.token, let user = payload.user else {
            throw APIError.rejected(message: payload.message ?? "Anmeldung fehlgeschlagen.")
        }
        env.session.saveToken(token)
        env.session.saveUser(user)
        env.session.saveSelectedClub(user.info.idClub)
        await env.syncStore.reset()
        self.user = user
        selectedClubID = user.info.idClub
        if notificationStatus == .notDetermined {
            await env.notifier.requestAuthorization()
            await refreshSystemStatus()
        }
        await refresh(reason: "login")
        BackgroundRefresh.schedule()
    }

    func logout() async {
        env.session.clearSession()
        await env.syncStore.reset()
        env.settings.preferences = NotificationPreferences(enabledByDefault: preferences.enabledByDefault)
        user = nil
        selectedClubID = nil
        schedulePath = []
        seenChangeIDs = []
        await reloadFromStore()
        BackgroundRefresh.schedule()   // cancels when logged out
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func selectClub(_ id: String) async {
        guard id != selectedClubID else { return }
        env.session.saveSelectedClub(id)
        selectedClubID = id
        await refresh(reason: "club")   // new club → new baseline, no notifications
    }

    // MARK: Notifications

    func isNotifying(_ eventKey: String) -> Bool { preferences.isEnabled(eventKey) }

    func setNotifying(_ enabled: Bool, for eventKey: String) {
        preferences.set(enabled, for: eventKey)
        env.settings.preferences = preferences
    }

    func setNotifyByDefault(_ enabled: Bool) {
        // Keep explicit per-event choices; only the default flips.
        var p = preferences
        let explicit = p.overrides
        p.enabledByDefault = enabled
        p.overrides = explicit.filter { $0.value != enabled }
        preferences = p
        env.settings.preferences = p
    }

    func setCategory(_ category: ChangeKind.Category, enabled: Bool) {
        if enabled { disabledCategories.remove(category) } else { disabledCategories.insert(category) }
        env.settings.disabledCategories = disabledCategories
    }

    func setRefreshMinutes(_ minutes: Int) {
        refreshMinutes = minutes
        env.settings.refreshMinutes = minutes
        BackgroundRefresh.schedule()
    }

    func requestNotificationPermission() async {
        if notificationStatus == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                await UIApplication.shared.open(url)
            }
            return
        }
        await env.notifier.requestAuthorization()
        await refreshSystemStatus()
    }

    func sendTestNotification() async {
        await env.notifier.sendTest()
    }

    func markChangesSeen() {
        seenChangeIDs.formUnion(changeLog.map(\.id))
        unseenChanges = 0
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    func clearChangeLog() async {
        var state = await env.syncStore.load()
        state.changeLog = []
        await env.syncStore.save(state)
        await reloadFromStore()
    }

    // MARK: Details

    func entry(for key: String) -> TrackedEntry? { entries.first { $0.id == key } }

    func changes(for key: String) -> [EventChange] { changeLog.filter { $0.eventKey == key } }

    func loadDetail(for entry: TrackedEntry) async {
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        _ = try? await env.engine.refreshDetail(for: entry.event, clubID: selectedClubID, playerID: user?.info.idPlayer)
        await reloadFromStore()
    }

    func open(eventKey: String) {
        selectedTab = .schedule
        schedulePath = [eventKey]
    }

    // MARK: Private

    private func loadSettings() {
        preferences = env.settings.preferences
        disabledCategories = env.settings.disabledCategories
        refreshMinutes = env.settings.refreshMinutes
    }

    private func refreshSystemStatus() async {
        notificationStatus = await env.notifier.authorizationStatus()
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    }
}
