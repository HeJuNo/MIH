import Foundation

/// Pure business rules extracted from DashboardContent / EventDetails /
/// StatusChangeModal (ANALYSIS.md §3.3). Kept UI-free so they are testable.
public enum StatusRules {
    public static let maxNotesLength = 150

    /// Status may only be changed before the event starts.
    public static func isEditable(_ event: Event, now: Date = .now) -> Bool {
        guard let start = EventDates.start(of: event) else { return false }
        return now < start
    }

    /// Bulk-select checkbox: future, no pending/answered attendance request, not a club item.
    public static func isBulkSelectable(_ event: Event, now: Date = .now) -> Bool {
        !event.isClubCalendarItem && event.availability == .notRequested && isEditable(event, now: now)
    }

    /// "Healthy" is disabled as soon as any selected event is a game.
    public static func allowedStatuses(for events: [Event]) -> [HealthStatus] {
        let hasGame = events.contains { $0.idGame != nil }
        return HealthStatus.selectable.filter { !(hasGame && $0 == .healthy) }
    }

    /// Attendance radio (can / cannot attend) is shown for a single event with a request.
    public static func showsAttendanceChoice(for events: [Event]) -> Bool {
        events.count == 1 && events[0].availability != .notRequested
    }

    /// Choosing "can participate" clears and disables the status picker.
    public static func statusPickerEnabled(attendance: Availability?) -> Bool {
        attendance != .confirmed
    }

    public struct Submission: Sendable {
        public var attendance: Availability?
        public var status: HealthStatus?
        public var notes: String?
        public init(attendance: Availability? = nil, status: HealthStatus?, notes: String?) {
            self.attendance = attendance; self.status = status; self.notes = notes
        }
    }

    public enum ValidationError: Error, Equatable { case noEvents, statusRequired, notesTooLong, notEditable }

    /// Chooses the endpoint exactly like `StatusChangeModal.handleSave`.
    public static func endpoint(for events: [Event], playerID: Int, submission s: Submission, now: Date = .now) throws -> Endpoint {
        guard let first = events.first else { throw ValidationError.noEvents }
        if (s.notes?.count ?? 0) > maxNotesLength { throw ValidationError.notesTooLong }
        // Original enforces this only in the UI; we enforce it here too.
        guard events.allSatisfy({ isEditable($0, now: now) }) else { throw ValidationError.notEditable }
        if s.attendance != .confirmed && s.status == nil { throw ValidationError.statusRequired }

        if events.count == 1, let id = first.primaryID, let kind = first.kind {
            if kind == .games, first.availability != .notRequested {
                return .setAvailability(gameID: id, playerID: playerID,
                                        available: s.attendance ?? first.availability,
                                        status: s.status, notes: s.notes)
            }
            return .setEvent(kind: kind, eventID: id, playerID: playerID, status: s.status, notes: s.notes)
        }

        let games = events.compactMap(\.idGame)
        let practices = events.compactMap(\.idPractice)
        return .setMassEvent(kind: games.isEmpty ? .practices : .games,
                             games: games, practices: practices,
                             playerID: playerID, status: s.status, notes: s.notes)
    }

    /// Optimistic detail update applied after a successful save.
    public static func applying(_ s: Submission, to detail: EventDetail) -> EventDetail {
        var d = detail
        let attendance = s.attendance ?? Availability(code: detail.available)
        d.healthStatus = attendance == .confirmed ? HealthStatus.attending.rawValue : s.status?.rawValue
        d.healthNotes = s.notes
        d.available = attendance.rawValue
        return d
    }

    /// Roster ordering: goalies, defence, forwards, then unassigned.
    public static func sortedRoster(_ players: [Convocation.Player]) -> [Convocation.Player] {
        let rank = ["G": 1, "D": 2, "F": 3]
        return players.enumerated().sorted {
            let l = rank[$0.element.position ?? ""] ?? 4, r = rank[$1.element.position ?? ""] ?? 4
            return l == r ? $0.offset < $1.offset : l < r
        }.map(\.element)
    }

    /// Dashboard tab filter (`apiService.filterEventsByType`).
    public static func filter(_ events: [Event], by tab: DashboardTab) -> [Event] {
        switch tab {
        case .all, .club: events
        case .games: events.filter { $0.idGame != nil }
        case .practices: events.filter { $0.idPractice != nil }
        }
    }
}

public enum DashboardTab: String, CaseIterable, Sendable { case all, games, practices, club }
