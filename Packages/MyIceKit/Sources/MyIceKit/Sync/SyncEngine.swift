import Foundation

/// Fetches "Spiele & Trainings" (`/refreshdata → app_data`), loads the detail of
/// every upcoming entry (`/getevent`), diffs against the previous generation and
/// persists the result. Used identically by pull-to-refresh and background refresh.
public actor SyncEngine {
    public struct Configuration: Sendable {
        /// Only entries starting within this window get a detail fetch.
        public var detailHorizon: TimeInterval = 60 * 24 * 3600
        public var maxDetailFetches = 40
        public var concurrency = 4
        public init() {}
    }

    public struct Result: Sendable {
        public var entries: [TrackedEntry]
        /// Empty on the very first sync (baseline) and after a club switch.
        public var changes: [EventChange]
        public var wasBaseline: Bool
    }

    public enum SyncError: Error, Equatable { case notLoggedIn, missingPlayer }

    private let api: APIClient
    private let store: SyncStore
    private let configuration: Configuration
    private var inFlight: Task<Result, Error>?

    public init(api: APIClient, store: SyncStore, configuration: Configuration = .init()) {
        self.api = api
        self.store = store
        self.configuration = configuration
    }

    /// Coalesces concurrent calls (e.g. pull-to-refresh during a background run).
    public func sync(clubID: String?, playerID: Int?, now: Date = .now) async throws -> Result {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.performSync(clubID: clubID, playerID: playerID, now: now) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performSync(clubID: String?, playerID: Int?, now: Date) async throws -> Result {
        var state = await store.load()
        state.lastAttempt = now
        guard let playerID else {
            state.lastError = "missingPlayer"
            await store.save(state)
            throw SyncError.missingPlayer
        }

        let payload: SessionPayload
        do {
            payload = try await api.send(.refreshData(clubID: clubID))
        } catch {
            state.lastError = String(describing: error)
            await store.save(state)
            throw error
        }

        let events = payload.appData ?? []
        let previous = state.clubID == clubID ? state.entries : []
        let previousByKey = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let wanted = events.filter { needsDetail($0, now: now) }.prefix(configuration.maxDetailFetches)
        let details = await fetchDetails(Array(wanted), clubID: clubID, playerID: playerID)

        let entries: [TrackedEntry] = events.map { event in
            if let fresh = details[event.id] {
                return TrackedEntry(event: event, detail: fresh, detailFetchedAt: now)
            }
            // Keep the last known detail so a failed fetch doesn't erase it.
            let old = previousByKey[event.id]
            return TrackedEntry(event: event, detail: old?.detail, detailFetchedAt: old?.detailFetchedAt)
        }

        let isBaseline = !state.hasBaseline || state.clubID != clubID
        let changes = isBaseline ? [] : ChangeDetector.diff(old: previous, new: entries, now: now)

        state.entries = entries
        state.clubID = clubID
        state.lastSync = now
        state.lastError = nil
        state.changeLog = Array((changes.reversed() + state.changeLog).prefix(SyncState.changeLogLimit))
        await store.save(state)

        return Result(entries: entries, changes: changes, wasBaseline: isBaseline)
    }

    private func needsDetail(_ event: Event, now: Date) -> Bool {
        guard event.kind != nil else { return false }
        guard let start = EventDates.start(of: event) else { return true }
        let startOfToday = Calendar.current.startOfDay(for: now)
        return start >= startOfToday && start <= now.addingTimeInterval(configuration.detailHorizon)
    }

    private func fetchDetails(_ events: [Event], clubID: String?, playerID: Int) async -> [String: EventDetail] {
        var result: [String: EventDetail] = [:]
        var iterator = events.makeIterator()
        await withTaskGroup(of: (String, EventDetail?).self) { group in
            func enqueue() {
                guard let event = iterator.next(), let kind = event.kind, let id = event.primaryID else { return }
                group.addTask { [api] in
                    let r: EventDetailResponse? = try? await api.send(.getEvent(kind: kind, eventID: id, playerID: playerID, clubID: clubID))
                    return (event.id, r?.eventData)
                }
            }
            for _ in 0..<configuration.concurrency { enqueue() }
            while let (key, detail) = await group.next() {
                if let detail { result[key] = detail }
                enqueue()
            }
        }
        return result
    }

    /// Fetches a single detail on demand (detail screen) and stores it.
    public func refreshDetail(for event: Event, clubID: String?, playerID: Int?) async throws -> EventDetail? {
        guard let playerID, let kind = event.kind, let id = event.primaryID else { return nil }
        let r: EventDetailResponse = try await api.send(.getEvent(kind: kind, eventID: id, playerID: playerID, clubID: clubID))
        guard let detail = r.eventData else { return nil }
        var state = await store.load()
        if let i = state.entries.firstIndex(where: { $0.id == event.id }) {
            // Diff against stored so on-demand loads don't hide changes from the next sync.
            let changes = state.hasBaseline
                ? ChangeDetector.diff(old: [state.entries[i]], new: [TrackedEntry(event: event, detail: detail)])
                : []
            state.entries[i].detail = detail
            state.entries[i].detailFetchedAt = .now
            state.changeLog = Array((changes.reversed() + state.changeLog).prefix(SyncState.changeLogLimit))
            await store.save(state)
        }
        return detail
    }
}
