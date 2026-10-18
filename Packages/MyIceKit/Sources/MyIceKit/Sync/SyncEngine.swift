import Foundation

/// Fetches "Spiele & Trainings" (`/refreshdata → app_data`) for every club of the
/// player, loads the detail of each upcoming entry (`/getevent`), diffs against the
/// previous generation, archives entries that took place, and persists the result.
/// Used identically by pull-to-refresh and background refresh.
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
        /// Empty on the very first sync (baseline); entries of newly added clubs are baselined too.
        public var changes: [EventChange]
        public var wasBaseline: Bool
    }

    public enum SyncError: Error, Equatable { case notLoggedIn, missingPlayer, noClubs }

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
    public func sync(clubIDs: [String], playerID: Int?, now: Date = .now) async throws -> Result {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.performSync(clubIDs: clubIDs, playerID: playerID, now: now) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performSync(clubIDs rawClubs: [String], playerID: Int?, now: Date) async throws -> Result {
        var state = await store.load()
        state.lastAttempt = now
        let clubs = Array(NSOrderedSet(array: rawClubs.filter { !$0.isEmpty })) as! [String]

        guard let playerID else { return try await fail(&state, SyncError.missingPlayer) }
        guard !clubs.isEmpty else { return try await fail(&state, SyncError.noClubs) }

        // 1. Personal schedule of every club. Any failure aborts so nothing is mistaken for "removed".
        var events: [(Event, String)] = []
        var seen = Set<String>()
        do {
            for club in clubs {
                let payload: SessionPayload = try await api.send(.refreshData(clubID: club))
                for event in payload.appData ?? [] where seen.insert(event.id).inserted {
                    events.append((event, club))
                }
            }
        } catch {
            return try await fail(&state, error)
        }
        events.sort { (EventDates.start(of: $0.0) ?? .distantFuture) < (EventDates.start(of: $1.0) ?? .distantFuture) }

        // 2. Details for upcoming entries.
        let previous = state.entries
        let previousByKey = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = events.filter { needsDetail($0.0, now: now) }.prefix(configuration.maxDetailFetches)
        let details = await fetchDetails(wanted.map { ($0.0, $0.1) }, playerID: playerID)

        let entries: [TrackedEntry] = events.map { event, club in
            if let fresh = details[event.id] {
                return TrackedEntry(event: event, detail: fresh, detailFetchedAt: now, clubID: club)
            }
            // Keep the last known detail so a failed fetch doesn't erase it.
            let old = previousByKey[event.id]
            return TrackedEntry(event: event, detail: old?.detail, detailFetchedAt: old?.detailFetchedAt, clubID: club)
        }

        // 3. Diff only clubs that were already covered by the baseline.
        let knownClubs = Set(state.clubIDs ?? []).intersection(clubs)
        let isBaseline = !state.hasBaseline
        let changes: [EventChange]
        if isBaseline {
            changes = []
        } else {
            let inKnown: (TrackedEntry) -> Bool = { $0.clubID.map(knownClubs.contains) ?? false }
            changes = ChangeDetector.diff(old: previous.filter(inKnown), new: entries.filter(inKnown), now: now)
        }

        // 4. Archive entries that dropped out after they took place.
        let newKeys = Set(entries.map(\.id))
        var archive = state.archive ?? []
        for var gone in previous where !newKeys.contains(gone.id) && !ChangeDetector.isUpcoming(gone, now: now) {
            gone.archivedAt = now
            archive.removeAll { $0.id == gone.id }
            archive.append(gone)
        }
        archive.removeAll { newKeys.contains($0.id) }
        archive = Self.trimmed(archive, now: now)

        state.entries = entries
        state.archive = archive
        state.clubIDs = clubs
        state.lastSync = now
        state.lastError = nil
        state.changeLog = Array((changes.reversed() + state.changeLog).prefix(SyncState.changeLogLimit))
        await store.save(state)

        return Result(entries: entries, changes: changes, wasBaseline: isBaseline)
    }

    private func fail(_ state: inout SyncState, _ error: Error) async throws -> Result {
        state.lastError = String(describing: error)
        await store.save(state)
        throw error
    }

    static func trimmed(_ archive: [TrackedEntry], now: Date) -> [TrackedEntry] {
        let cutoff = now.addingTimeInterval(-SyncState.archiveRetention)
        return Array(archive
            .filter { (EventDates.start(of: $0.event) ?? now) > cutoff }
            .sorted { (EventDates.start(of: $0.event) ?? .distantPast) > (EventDates.start(of: $1.event) ?? .distantPast) }
            .prefix(SyncState.archiveLimit))
    }

    private func needsDetail(_ event: Event, now: Date) -> Bool {
        guard event.kind != nil else { return false }
        guard let start = EventDates.start(of: event) else { return true }
        let startOfToday = Calendar.current.startOfDay(for: now)
        return start >= startOfToday && start <= now.addingTimeInterval(configuration.detailHorizon)
    }

    private func fetchDetails(_ events: [(Event, String)], playerID: Int) async -> [String: EventDetail] {
        var result: [String: EventDetail] = [:]
        var iterator = events.makeIterator()
        await withTaskGroup(of: (String, EventDetail?).self) { group in
            func enqueue() {
                guard let (event, club) = iterator.next(), let kind = event.kind, let id = event.primaryID else { return }
                group.addTask { [api] in
                    let r: EventDetailResponse? = try? await api.send(.getEvent(kind: kind, eventID: id, playerID: playerID, clubID: club))
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

    /// Fetches a single detail on demand (detail screen, also for archived entries) and stores it.
    public func refreshDetail(for entry: TrackedEntry, playerID: Int?) async throws -> EventDetail? {
        guard let playerID, let kind = entry.event.kind, let id = entry.event.primaryID else { return nil }
        let r: EventDetailResponse = try await api.send(.getEvent(kind: kind, eventID: id, playerID: playerID, clubID: entry.clubID))
        guard let detail = r.eventData else { return nil }
        var state = await store.load()
        if let i = state.entries.firstIndex(where: { $0.id == entry.id }) {
            // Diff against stored so on-demand loads don't hide changes from the next sync.
            let changes = state.hasBaseline
                ? ChangeDetector.diff(old: [state.entries[i]], new: [TrackedEntry(event: entry.event, detail: detail)])
                : []
            state.entries[i].detail = detail
            state.entries[i].detailFetchedAt = .now
            state.changeLog = Array((changes.reversed() + state.changeLog).prefix(SyncState.changeLogLimit))
        } else if let i = state.archive?.firstIndex(where: { $0.id == entry.id }) {
            state.archive?[i].detail = detail
            state.archive?[i].detailFetchedAt = .now
        }
        await store.save(state)
        return detail
    }

    /// Merges past entries (e.g. from `WebHistoryClient`) into the archive without
    /// touching the live baseline or producing notifications.
    public func importHistory(_ past: [TrackedEntry], now: Date = .now) async {
        var state = await store.load()
        let live = Set(state.entries.map(\.id))
        var archive = state.archive ?? []
        let known = Set(archive.map(\.id))
        archive += past.filter { !live.contains($0.id) && !known.contains($0.id) }
        state.archive = Self.trimmed(archive, now: now)
        await store.save(state)
    }

    /// Records the user's own status change in the baseline so the next sync
    /// doesn't report it back as a change. Mirrors the original optimistic update:
    /// `health_status = available == 2 ? 3 : id_status`.
    public func applyLocalStatus(eventKey: String, submission: StatusRules.Submission) async {
        var state = await store.load()
        guard let i = state.entries.firstIndex(where: { $0.id == eventKey }) else { return }
        var entry = state.entries[i]
        let available = submission.attendance ?? Availability(code: entry.detail?.available ?? entry.event.available)
        let health = available == .confirmed ? HealthStatus.attending.rawValue : submission.status?.rawValue
        entry.event.available = available.rawValue
        entry.event.healthStatus = health
        entry.event.healthStatusNotes = submission.notes
        if let detail = entry.detail { entry.detail = StatusRules.applying(submission, to: detail) }
        state.entries[i] = entry
        await store.save(state)
    }
}
