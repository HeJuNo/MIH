import Foundation
import MyIceKit

/// Process-wide dependencies shared by the UI and the background refresh task.
/// Everything here is safe to use off the main actor.
final class AppEnvironment: Sendable {
    static let shared = AppEnvironment()

    let session: DefaultSessionStore
    let settings: SettingsStore
    let api: APIClient
    let syncStore: SyncStore
    let engine: SyncEngine
    let notifier: ChangeNotifier
    let calendarSync: CalendarSync
    let log: AppLog

    private init() {
        let session = DefaultSessionStore(keychain: KeychainSecretStore(service: "app.myhockeydata.session"))
        let settings = SettingsStore()
        let log = AppLog(settings: settings)
        var config = APIConfig()
        if let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
           !raw.isEmpty, let url = URL(string: raw) {
            config.baseURL = url
        }
        let api = APIClient(config: config, context: SessionContext(session: session), log: log.sink)
        let syncStore = SyncStore()

        self.session = session
        self.settings = settings
        self.api = api
        self.syncStore = syncStore
        self.engine = SyncEngine(api: api, store: syncStore, log: log.sink)
        self.notifier = ChangeNotifier(log: log)
        self.calendarSync = CalendarSync(settings: settings, syncStore: syncStore, engine: engine, session: session, log: log)
        self.log = log
    }
}

/// Supplies `token` + `language` to every request.
struct SessionContext: RequestContextProviding {
    let session: DefaultSessionStore
    func currentToken() async -> String? { session.loadToken() }
    func currentLanguage() async -> String {
        AppLanguage.normalize(session.loadLanguage() ?? Locale.preferredLanguages.first ?? "de").rawValue
    }
}
