import Foundation

/// Every server call observed in the original client. All are
/// `POST multipart/form-data` to `{base}/{path}`; `token` + `language`
/// are appended by `APIClient`, not here.
public enum Endpoint: Sendable {
    case login(email: String, password: String)
    /// Switch to a saved account: authenticates with *that* account's token.
    case changeLogin(token: String, email: String)
    case addAccount(email: String, password: String)
    case refreshData(clubID: String?)
    case getEvent(kind: EventKind, eventID: Int, playerID: Int, clubID: String?)
    case setEvent(kind: EventKind, eventID: Int, playerID: Int, status: HealthStatus?, notes: String?)
    case setAvailability(gameID: Int, playerID: Int, available: Availability, status: HealthStatus?, notes: String?)
    case setMassEvent(kind: EventKind, games: [Int], practices: [Int], playerID: Int, status: HealthStatus?, notes: String?)
    case getNotifications
    case setNotification(id: Int)
    case getBadge
    case setPushToken(String)
    case getAdvertisement

    public var path: String {
        switch self {
        case .login: "/login"
        case .changeLogin: "/change_login"
        case .addAccount: "/add_account"
        case .refreshData: "/refreshdata"
        case .getEvent: "/getevent"
        case .setEvent: "/setevent"
        case .setAvailability: "/setavailability"
        case .setMassEvent: "/setmassevent"
        case .getNotifications: "/getnotifications"
        case .setNotification: "/setnotification"
        case .getBadge: "/get-badge"
        case .setPushToken: "/setpushtoken"
        case .getAdvertisement: "/get-advertisement"
        }
    }

    /// Token that overrides the stored session token (only `change_login`).
    var tokenOverride: String? {
        if case .changeLogin(let token, _) = self { return token }
        return nil
    }

    /// Endpoint-specific fields, in the original field order.
    var fields: [(String, MultipartForm.Value)] {
        func opt(_ s: String?) -> MultipartForm.Value { s.map(MultipartForm.Value.string) ?? .null }
        func opt(_ st: HealthStatus?) -> MultipartForm.Value { st.map { .int($0.rawValue) } ?? .null }
        // An empty note must be "" — the server stores a literal "null" otherwise.
        func note(_ s: String?) -> MultipartForm.Value { .string(s ?? "") }

        switch self {
        case let .login(email, password):
            return [("login_email", .string(email)), ("login_password", .string(password))]
        case let .changeLogin(_, email):
            return [("email", .string(email))]
        case let .addAccount(email, password):
            return [("user_email", .string(email)), ("user_password", .string(password))]
        case let .refreshData(clubID):
            return [("id_club", opt(clubID))]
        case let .getEvent(kind, eventID, playerID, clubID):
            return [("type", .string(kind.rawValue)), ("id_event", .int(eventID)),
                    ("id_player", .int(playerID)), ("id_club", opt(clubID))]
        case let .setEvent(kind, eventID, playerID, status, notes):
            return [("type", .string(kind.rawValue)), ("id_event", .int(eventID)),
                    ("id_player", .int(playerID)), ("id_status", opt(status)), ("notes", note(notes))]
        case let .setAvailability(gameID, playerID, available, status, notes):
            return [("id_event", .int(gameID)), ("id_player", .int(playerID)),
                    ("available", .int(available.rawValue)), ("id_status", opt(status)), ("notes", note(notes))]
        case let .setMassEvent(kind, games, practices, playerID, status, notes):
            return [("type", .string(kind.rawValue)), ("games", .list(games)), ("practices", .list(practices)),
                    ("id_player", .int(playerID)), ("id_status", opt(status)), ("notes", note(notes))]
        case .getNotifications, .getBadge, .getAdvertisement:
            return []
        case let .setNotification(id):
            return [("id_notification", .int(id))]
        case let .setPushToken(token):
            return [("pushToken", .string(token))]
        }
    }
}

extension Endpoint {
    /// Path plus non-sensitive identifiers, for the diagnostic log. Never contains credentials.
    var logLabel: String {
        switch self {
        case let .refreshData(club): "\(path) club=\(club ?? "-")"
        case let .getEvent(kind, id, _, club): "\(path) \(kind.rawValue)/\(id) club=\(club ?? "-")"
        case let .setEvent(kind, id, _, _, _): "\(path) \(kind.rawValue)/\(id)"
        case let .setAvailability(id, _, _, _, _): "\(path) games/\(id)"
        default: path
        }
    }
}
