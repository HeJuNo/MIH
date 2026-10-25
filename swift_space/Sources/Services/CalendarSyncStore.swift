import Foundation

/// The `EKEvent` identifiers `CalendarSync` created for one `TrackedEntry`, so a later
/// pass updates them in place instead of creating duplicates.
struct CalendarMapping: Codable, Equatable {
    var mainEventID: String?
    var meetingEventID: String?
    var departureEventID: String?

    var isEmpty: Bool { mainEventID == nil && meetingEventID == nil && departureEventID == nil }
}

/// Everything `CalendarSync` remembers between runs: the chosen calendar and, per
/// tracked entry, which `EKEvent`s it already wrote.
struct CalendarSyncState: Codable {
    var calendarIdentifier: String?
    var mapping: [String: CalendarMapping] = [:]
}

/// JSON-file persistence in Application Support, next to `sync-state.json`. Mirrors
/// `SyncStore`'s pattern so both survive background runs identically.
actor CalendarSyncStore {
    private let url: URL
    private var cached: CalendarSyncState?

    init(directory: URL? = nil, fileName: String = "calendar-sync-state.json") {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyHockeyData", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent(fileName)
    }

    func load() -> CalendarSyncState {
        if let cached { return cached }
        let state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CalendarSyncState.self, from: $0) }
            ?? CalendarSyncState()
        cached = state
        return state
    }

    func save(_ state: CalendarSyncState) {
        cached = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
