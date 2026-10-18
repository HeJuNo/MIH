import Foundation

/// One event as last seen by the sync engine: the list row plus (when it
/// could be fetched) the `/getevent` detail.
public struct TrackedEntry: Codable, Hashable, Sendable, Identifiable {
    public var event: Event
    public var detail: EventDetail?
    public var detailFetchedAt: Date?

    public var id: String { event.id }

    public init(event: Event, detail: EventDetail? = nil, detailFetchedAt: Date? = nil) {
        self.event = event
        self.detail = detail
        self.detailFetchedAt = detailFetchedAt
    }
}

/// A single detected difference between two syncs. Values are kept raw so the
/// app can render them in the user's language at display/notification time.
public enum ChangeKind: Codable, Hashable, Sendable {
    case added
    case removed
    case renamed(old: String, new: String)
    case date(old: Date?, new: Date?)
    case time(old: String, new: String)
    case place(old: String, new: String)
    case departure(label: String?, old: String, new: String)
    case meeting(label: String?, old: String, new: String)
    case notes(new: String)
    case attendance(old: Int, new: Int)
    case healthStatus(old: Int, new: Int)
    case rosterPublished(players: Int)
    case players(added: [String], removed: [String])
    case staff(added: [String], removed: [String])
    case message(subject: String, body: String)

    /// Stable category used for grouping and per-category icons.
    public var category: Category {
        switch self {
        case .added: .added
        case .removed: .removed
        case .renamed, .place, .notes: .info
        case .date, .time, .departure, .meeting: .schedule
        case .attendance, .healthStatus: .status
        case .rosterPublished, .players, .staff: .people
        case .message: .message
        }
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case added, removed, schedule, info, status, people, message
    }
}

public struct EventChange: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var eventKey: String
    public var eventTitle: String
    public var eventSubtitle: String?
    public var eventStart: Date?
    public var eventKind: EventKind?
    public var detectedAt: Date
    public var kind: ChangeKind

    public init(id: UUID = UUID(), entry: TrackedEntry, detectedAt: Date, kind: ChangeKind) {
        self.id = id
        self.eventKey = entry.id
        self.eventTitle = entry.event.name ?? ""
        self.eventSubtitle = [entry.event.agegroup, entry.event.practicegroup].compactMap { $0 }.joined(separator: " · ")
        self.eventStart = EventDates.start(of: entry.event)
        self.eventKind = entry.event.kind
        self.detectedAt = detectedAt
        self.kind = kind
    }
}
