import EventKit
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

    enum Tab: Hashable { case schedule, changes, log, settings }

    // Session
    private(set) var user: User?
    private(set) var selectedClubID: String?
    var isLoggedIn: Bool { user != nil }

    // Data
    private(set) var entries: [TrackedEntry] = []
    /// Past entries (local archive + one-time web import), newest first.
    private(set) var archive: [TrackedEntry] = []
    private(set) var isImportingHistory = false
    /// Result of the last history import, shown in Settings.
    private(set) var historyMessage: String?
    private(set) var changeLog: [EventChange] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var unseenChanges = 0

    // Settings mirror
    private(set) var preferences = NotificationPreferences()
    private(set) var disabledCategories: Set<ChangeKind.Category> = []
    private(set) var refreshMinutes = 30
    private(set) var mapProvider: MapProvider = .apple
    private(set) var appearance: AppearanceMode = .system
    private(set) var storedScheduleFilter = ScheduleFilter()
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var backgroundRefreshStatus: UIBackgroundRefreshStatus = .available
    private(set) var lastBackgroundRun: Date?
    private(set) var calendarSyncEnabled = false
    private(set) var calendarTitlePrefixEnabled = false
    private(set) var calendarTitlePrefix = ""
    private(set) var clubAbbreviations: [String: String] = [:]
    private(set) var calendarIdentifier: String?
    private(set) var calendarAuthStatus: EKAuthorizationStatus = .notDetermined
    private(set) var calendarOptions: [(id: String, title: String)] = []

    // Protocol
    private(set) var loggingEnabled = false
    private(set) var logLevel: LogLevel = .info
    private(set) var logAreas: Set<LogArea> = Set(LogArea.allCases)

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
            entries = DemoData.entriesWithClubs()
            archive = DemoData.archive()
            changeLog = DemoData.changes(for: entries)
            unseenChanges = 2
            lastSync = .now.addingTimeInterval(-420)
            preferences.set(false, for: entries[3].id)
            clubLogos = DemoData.clubLogos()
            // Not persisted, so screenshots never depend on an earlier run.
            storedScheduleFilter = ScheduleFilter(kind: DemoData.value(after: "-demoFilter").flatMap(KindFilter.init(rawValue:)) ?? .all,
                                                  clubID: DemoData.value(after: "-demoClub"))
            if let i = DemoData.detailIndex, entries.indices.contains(i) { schedulePath = [entries[i].id] }
            if DemoData.opensPast {
                schedulePath = [PastEventsView.route]
                if let i = DemoData.value(after: "-demoPast").flatMap(Int.init), archive.indices.contains(i) {
                    schedulePath.append(archive[i].id)
                }
            }
            loggingEnabled = DemoData.showsLog
            logLevel = .debug
            if let tab = UserDefaults.standard.string(forKey: "demoTab") {
                selectedTab = tab == "changes" ? .changes : tab == "settings" ? .settings : tab == "log" ? .log : .schedule
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
        env.log(.debug, .app, "In foreground, last sync \(lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "never")")
        await BackgroundRefresh.logPending()
        // Avoid hammering the API when quickly switching apps.
        if (lastSync.map { Date().timeIntervalSince($0) > 5 * 60 }) ?? true {
            await refresh(reason: "foreground")
        }
    }

    func reloadFromStore() async {
        let state = await env.syncStore.load()
        entries = state.entries
        archive = state.archive ?? []
        changeLog = state.changeLog
        lastSync = state.lastSync
        lastError = state.lastError
        lastBackgroundRun = env.settings.lastBackgroundRun
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
        await importHistory(email: email, password: password)
    }

    /// One-time import of the season's past via the web API; the password is not stored.
    func importHistory(email: String, password: String) async {
        guard var current = user else { return }
        isImportingHistory = true
        historyMessage = nil
        env.log(.info, .history, "Import started")
        defer { isImportingHistory = false }
        do {
            // Sessions from older app versions didn't store the season: refresh the profile once.
            if current.info.idSeason == nil {
                let payload: SessionPayload = try await env.api.send(.login(email: email, password: password))
                guard payload.status == 1, let token = payload.token, let fresh = payload.user else {
                    throw APIError.rejected(message: payload.message ?? "Anmeldung fehlgeschlagen.")
                }
                env.session.saveToken(token)
                env.session.saveUser(fresh)
                user = fresh
                current = fresh
            }
            guard let player = current.info.idPlayer, let season = current.info.idSeason, !clubIDs.isEmpty else {
                historyMessage = "Saison konnte nicht ermittelt werden."
                return
            }
            // Primary club last: the web session keeps the last selected club.
            let primary = current.info.idClub
            let clubs = clubIDs.filter { $0 != primary } + [primary].compactMap { $0 }
            let before = archive.count
            let past = try await WebHistoryClient().pastEntries(email: email, password: password, playerID: player,
                                                                seasonID: season, clubIDs: clubs)
            await env.engine.importHistory(past)
            await reloadFromStore()
            let added = archive.count - before
            historyMessage = added > 0 ? "\(added) vergangene Termine geladen." : "Alle vergangenen Termine sind bereits vorhanden."
            let perClub = Dictionary(grouping: past, by: { $0.clubID ?? "-" }).map { "\($0.key): \($0.value.count)" }.sorted()
            env.log(.info, .history, "Web returned \(pluralized(past.count, "event")) (\(perClub.joined(separator: ", "))), new in archive: \(added)")
        } catch WebHistoryClient.WebError.loginFailed {
            historyMessage = "Anmeldung an der Web-Version fehlgeschlagen. Passwort prüfen."
        } catch APIError.rejected(let message) {
            historyMessage = message ?? "Anmeldung fehlgeschlagen."
        } catch {
            historyMessage = "Laden fehlgeschlagen: \(error.localizedDescription)"
        }
        if let historyMessage, !historyMessage.hasSuffix("geladen."), !historyMessage.hasPrefix("Alle") {
            env.log(.error, .history, historyMessage)
        }
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

    var clubIDs: [String] {
        guard let user else { return [] }
        return SyncCoordinator.clubIDs(for: user, fallback: selectedClubID)
    }

    var clubs: [Club] { user?.info.activeClubs ?? [] }

    /// Club logos sized for menu rows, where `AsyncImage` can't be used. Keyed by club ID.
    private(set) var clubLogos: [String: UIImage] = [:]
    /// The same (cleaned, cropped) logos at their processed resolution, for the bigger
    /// preview in the per-team settings screen — `clubLogos` is baked down to 26pt and
    /// would look blurry scaled back up.
    private(set) var clubLogoPreviews: [String: UIImage] = [:]

    /// Loads missing logos once; `URLSession`'s shared cache keeps the remote ones on
    /// disk. A user-supplied replacement (`setCustomLogo`) always wins over the remote one.
    func loadClubLogos() async {
        for club in clubs where clubLogos[club.id] == nil {
            let resolved: UIImage?
            if let custom = env.clubLogoStore.load(club.id) {
                resolved = custom   // already finalized by LogoEditorView — don't reprocess
            } else if let url = club.clubLogo, let (data, _) = try? await URLSession.shared.data(from: url) {
                resolved = UIImage(data: data).map(LogoProcessing.cleaned)
            } else {
                resolved = nil
            }
            guard let resolved else { continue }
            clubLogoPreviews[club.id] = resolved
            clubLogos[club.id] = resolved.menuIcon()
        }
    }

    /// Replaces (or, with `nil`, clears back to) the club's logo with the result of
    /// `LogoEditorView` — already cropped, rotated and background-cleaned as the user chose,
    /// so it's stored and shown as-is rather than run through automatic cleanup again.
    func setCustomLogo(_ image: UIImage?, for clubID: String) {
        if let image {
            env.clubLogoStore.save(image, for: clubID)
            clubLogoPreviews[clubID] = image
            clubLogos[clubID] = image.menuIcon()
        } else {
            env.clubLogoStore.remove(clubID)
            clubLogos[clubID] = nil
            clubLogoPreviews[clubID] = nil
            Task { await loadClubLogos() }
        }
    }

    func hasCustomLogo(_ clubID: String) -> Bool { env.clubLogoStore.load(clubID) != nil }

    var hasMultipleClubs: Bool { clubs.count > 1 }

    func clubName(_ id: String?) -> String? {
        guard let id else { return nil }
        return clubs.first { $0.clubID == id }?.clubName
    }

    // MARK: Status

    /// Changes the player's own status (and attendance for requested games).
    func submitStatus(for entry: TrackedEntry, _ submission: StatusRules.Submission) async throws {
        guard let player = user?.info.idPlayer else { return }
        let endpoint = try StatusRules.endpoint(for: [entry.event], playerID: player, submission: submission)
        do {
            try await env.api.perform(endpoint)
        } catch {
            env.log(.error, .status, "\(entry.id) not saved: \(error)")
            throw error
        }
        env.log(.info, .status, "\(entry.id) set: \(submission.status.map { StatusText.health($0.rawValue) } ?? "-")"
                + (submission.attendance.map { ", attendance \(StatusText.availability($0))" } ?? "")
                + ((submission.notes ?? "").isEmpty ? "" : ", with note"))
        // Own change → baseline, so no notification echoes it back.
        await env.engine.applyLocalStatus(eventKey: entry.id, submission: submission)
        await reloadFromStore()
        Task { await refresh(reason: "status") }
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
        await env.engine.clearChangeLog()
        await reloadFromStore()
    }

    // MARK: Details

    func entry(for key: String) -> TrackedEntry? { entries.first { $0.id == key } ?? archive.first { $0.id == key } }

    func changes(for key: String) -> [EventChange] { changeLog.filter { $0.eventKey == key } }

    func loadDetail(for entry: TrackedEntry) async {
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        _ = try? await env.engine.refreshDetail(for: entry, playerID: user?.info.idPlayer)
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
        mapProvider = env.settings.mapProvider
        appearance = env.settings.appearance
        storedScheduleFilter = env.settings.scheduleFilter
        loggingEnabled = env.settings.loggingEnabled
        logLevel = env.settings.logLevel
        logAreas = env.settings.logAreas
        calendarSyncEnabled = env.settings.calendarSyncEnabled
        calendarTitlePrefixEnabled = env.settings.calendarTitlePrefixEnabled
        calendarTitlePrefix = env.settings.calendarTitlePrefix
        clubAbbreviations = env.settings.clubAbbreviations
        calendarIdentifier = env.settings.calendarIdentifier
    }

    // MARK: Protocol

    func setLoggingEnabled(_ on: Bool) {
        if on {
            env.settings.loggingEnabled = true
            env.log(.info, .app, "Logging enabled (from \(logLevel.title))")
        } else {
            env.log(.info, .app, "Logging disabled")
            env.settings.loggingEnabled = false
            if selectedTab == .log { selectedTab = .settings }
        }
        loggingEnabled = on
    }

    func setLogLevel(_ level: LogLevel) {
        logLevel = level
        env.settings.logLevel = level
    }

    func setLogArea(_ area: LogArea, enabled: Bool) {
        if enabled { logAreas.insert(area) } else { logAreas.remove(area) }
        env.settings.logAreas = logAreas
    }

    func logEntries() async -> [LogEntry] {
        #if DEBUG
        if DemoData.isEnabled { return DemoData.logEntries() }
        #endif
        return await env.log.entries()
    }
    func clearLog() async { await env.log.clear() }

    /// The stored filter, minus a club the player no longer belongs to (or a single remaining club).
    var scheduleFilter: ScheduleFilter {
        var f = storedScheduleFilter
        if let id = f.clubID, !hasMultipleClubs || !clubs.contains(where: { $0.id == id }) { f.clubID = nil }
        return f
    }

    func setScheduleFilter(_ f: ScheduleFilter) {
        storedScheduleFilter = f
        env.settings.scheduleFilter = f
    }

    func setMapProvider(_ p: MapProvider) {
        mapProvider = p
        env.settings.mapProvider = p
    }

    func setAppearance(_ a: AppearanceMode) {
        appearance = a
        env.settings.appearance = a
    }

    // MARK: Calendar sync

    func requestCalendarAccess() async {
        if calendarAuthStatus == .denied || calendarAuthStatus == .restricted {
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            return
        }
        _ = await env.calendarSync.requestAccess()
        await refreshSystemStatus()
    }

    func setCalendarSyncEnabled(_ on: Bool) {
        calendarSyncEnabled = on
        env.settings.calendarSyncEnabled = on
        Task {
            if on {
                if calendarAuthStatus != .fullAccess { await requestCalendarAccess() }
                await syncCalendarNow()
            } else {
                await env.calendarSync.removeAll()
            }
        }
    }

    func setCalendarTitlePrefixEnabled(_ on: Bool) {
        calendarTitlePrefixEnabled = on
        env.settings.calendarTitlePrefixEnabled = on
        Task { await syncCalendarNow() }
    }

    func setCalendarTitlePrefix(_ prefix: String) {
        calendarTitlePrefix = prefix
        env.settings.calendarTitlePrefix = prefix
        Task { await syncCalendarNow() }
    }

    func setClubAbbreviation(_ abbreviation: String, for clubID: String) {
        clubAbbreviations[clubID] = abbreviation
        env.settings.clubAbbreviations = clubAbbreviations
        Task { await syncCalendarNow() }
    }

    func setCalendarIdentifier(_ id: String?) {
        calendarIdentifier = id
        env.settings.calendarIdentifier = id
        Task { await syncCalendarNow() }
    }

    func loadCalendarOptions() async {
        calendarOptions = await env.calendarSync.availableCalendars()
        calendarIdentifier = env.settings.calendarIdentifier   // CalendarSync may have auto-created the dedicated one
    }

    private func syncCalendarNow() async {
        guard calendarSyncEnabled else { return }
        await env.calendarSync.run(reason: "settings")
        await loadCalendarOptions()
    }

    private func refreshSystemStatus() async {
        let refresh = UIApplication.shared.backgroundRefreshStatus
        let notifications = await env.notifier.authorizationStatus()
        if refresh != backgroundRefreshStatus || notifications != notificationStatus || !statusLogged {
            statusLogged = true
            env.log(refresh == .available ? .info : .warning, .background,
                    "Hintergrundaktualisierung: \(refresh == .available ? "erlaubt" : refresh == .denied ? "in iOS ausgeschaltet" : "eingeschränkt")")
            env.log(notifications == .authorized ? .info : .warning, .notifications,
                    "Benachrichtigungen: \(notifications == .authorized ? "erlaubt" : notifications == .denied ? "abgelehnt" : "nicht erlaubt (\(notifications.rawValue))")")
        }
        backgroundRefreshStatus = refresh
        notificationStatus = notifications
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private var statusLogged = false
}

extension UIImage {
    /// Fits the image into a square menu glyph, keeping its own colors.
    func menuIcon(side: CGFloat = 26) -> UIImage {
        let scale = min(side / max(size.width, 1), side / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(in: CGRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
