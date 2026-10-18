import Foundation

public struct StatusEnvelope: Decodable, Sendable {
    @LenientInt public var status: Int?
    public var message: String?
    public var isSuccess: Bool { status == 1 }
}

public struct Club: Codable, Hashable, Sendable, Identifiable {
    @LenientString public var clubID: String?
    public var clubName: String?
    @LenientURL public var clubLogo: URL?
    public var id: String { clubID ?? "" }

    enum CodingKeys: String, CodingKey {
        case clubID = "club_id", clubName = "club_name", clubLogo = "club_logo"
    }
}

/// `userinfo` from /login. Only fields the original client reads are typed.
public struct UserInfo: Codable, Hashable, Sendable {
    @LenientInt public var idPlayer: Int?
    @LenientString public var idClub: String?
    @LenientString public var idSeason: String?
    public var fname: String?
    public var lname: String?
    @LenientURL public var photo: URL?
    public var activeClubs: [Club]?

    enum CodingKeys: String, CodingKey {
        case idPlayer = "id_player", idClub = "id_club", idSeason = "id_season", fname, lname, photo, activeClubs = "active_clubs"
    }
}

/// Persisted user (JS: `{ id: userid, email: useremail, ...userinfo, has_notifications }`).
public struct User: Codable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var info: UserInfo
    public var hasNotifications: Bool

    public init(id: String, email: String, info: UserInfo, hasNotifications: Bool) {
        self.id = id; self.email = email; self.info = info; self.hasNotifications = hasNotifications
    }
}

/// Shared payload of /login, /change_login and /refreshdata.
public struct SessionPayload: Decodable, Sendable {
    @LenientInt public var status: Int?
    public var message: String?
    public var token: String?
    @LenientString public var userid: String?
    public var useremail: String?
    public var userinfo: UserInfo?
    @LenientInt public var hasNotification: Int?
    public var appData: [Event]?
    public var clubGames: [Event]?

    enum CodingKeys: String, CodingKey {
        case status, message, token, userid, useremail, userinfo
        case hasNotification = "has_notification", appData = "app_data", clubGames = "club_games"
    }

    public var user: User? {
        guard let userid, let userinfo else { return nil }
        return User(id: userid, email: useremail ?? "", info: userinfo, hasNotifications: (hasNotification ?? 0) > 0)
    }
}

/// An entry in `app_data` (personal schedule) or `club_games` (club calendar).
public struct Event: Codable, Hashable, Sendable, Identifiable {
    @LenientInt public var idGame: Int?
    @LenientInt public var idPractice: Int?
    /// Present only on club-calendar items → read-only.
    @LenientInt public var idEvent: Int?
    public var date: String?
    public var datetime: String?
    public var timeStart: String?
    public var timeEnd: String?
    public var name: String?
    public var agegroup: String?
    public var practicegroup: String?
    public var place: String?
    public var color: String?
    @LenientInt public var available: Int?
    @LenientInt public var healthStatus: Int?
    public var healthStatusNotes: String?
    public var eventNotes: String?
    @LenientInt public var hasNotifications: Int?

    enum CodingKeys: String, CodingKey {
        case idGame = "id_game", idPractice = "id_practice", idEvent = "id_event"
        case date, datetime, timeStart = "time_start", timeEnd = "time_end"
        case name, agegroup, practicegroup, place, color, available
        case healthStatus = "health_status", healthStatusNotes = "health_status_notes"
        case eventNotes = "event_notes", hasNotifications = "has_notifications"
    }

    public var id: String {
        if let idGame { return "g\(idGame)" }
        if let idPractice { return "p\(idPractice)" }
        return "e\(idEvent ?? 0)-\(datetime ?? "")"
    }

    public var kind: EventKind? {
        if idGame != nil { return .games }
        if idPractice != nil { return .practices }
        return nil
    }

    public var primaryID: Int? { idGame ?? idPractice }
    public var isClubCalendarItem: Bool { idEvent != nil }
}

public struct Convocation: Codable, Hashable, Sendable {
    public struct Staff: Codable, Hashable, Sendable { public var fname, lname, role: String? }
    public struct Player: Codable, Hashable, Sendable {
        public var fname, lname, position, hex: String?
        @LenientString public var number: String?
    }
    public var staff: [Staff]?
    public var available: [Player]?
    @LenientInt public var availableTotal: Int?
    @LenientInt public var availableTotalG: Int?
    @LenientInt public var availableTotalD: Int?
    @LenientInt public var availableTotalF: Int?

    enum CodingKeys: String, CodingKey {
        case staff, available, availableTotal = "available_total"
        case availableTotalG = "available_totalG", availableTotalD = "available_totalD", availableTotalF = "available_totalF"
    }
}

/// `/getevent → eventData`.
public struct EventDetail: Codable, Hashable, Sendable {
    public var type: String?
    public var category: String?
    public var isAway: String?
    @LenientInt public var available: Int?
    public var availableDate: String?
    @LenientInt public var healthStatus: Int?
    public var healthNotes: String?
    /// HTML authored by club staff. Render sanitized; never in a privileged web view.
    public var notes: String?
    public var departure, departureTime, meeting, meetingTime: String?
    public var convocation: Convocation?
    public var notifications: [AppNotification]?
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case type, category, isAway = "is_away", available, availableDate = "available_date"
        case healthStatus = "health_status", healthNotes = "health_notes", notes
        case departure, departureTime = "departure_time", meeting, meetingTime = "meeting_time"
        case convocation, notifications, title
    }
}

public struct EventDetailResponse: Decodable, Sendable { public var eventData: EventDetail? }

public struct AppNotification: Codable, Hashable, Sendable, Identifiable {
    public struct Context: Codable, Hashable, Sendable { public var description, date: String? }
    @LenientInt public var idNotification: Int?
    @LenientInt public var isRead: Int?
    public var date, subject, message, fname, lname: String?
    public var context: Context?
    public var id: Int { idNotification ?? 0 }

    enum CodingKeys: String, CodingKey {
        case idNotification = "id_notification", isRead = "is_read", date, subject, message, fname, lname, context
    }
}

public struct NotificationsResponse: Decodable, Sendable { public var messages: [AppNotification]? }
public struct BadgeResponse: Decodable, Sendable { @LenientInt public var badge: Int? }

/// Secondary account kept for one-tap switching (JS: localStorage.accounts).
/// The original stores the raw /add_account response; we keep only what is needed.
public struct SavedAccount: Codable, Hashable, Sendable, Identifiable {
    public var email: String
    public var token: String
    public var fname: String?
    public var lname: String?
    public var photo: URL?
    public var id: String { email }

    public init(email: String, token: String, fname: String? = nil, lname: String? = nil, photo: URL? = nil) {
        self.email = email; self.token = token; self.fname = fname; self.lname = lname; self.photo = photo
    }
}

public struct AddAccountResponse: Decodable, Sendable {
    @LenientInt public var status: Int?
    public var message, email, token, fname, lname: String?
    @LenientURL public var photo: URL?
}
