import Foundation

/// Everything the sync engine remembers between runs.
public struct SyncState: Codable, Sendable {
    public var entries: [TrackedEntry] = []
    public var lastSync: Date?
    public var lastAttempt: Date?
    public var lastError: String?
    /// Newest first, capped at `SyncState.changeLogLimit`.
    public var changeLog: [EventChange] = []
    /// Club the baseline belongs to; switching clubs resets the baseline.
    public var clubID: String?

    public static let changeLogLimit = 300
    public init() {}

    public var hasBaseline: Bool { lastSync != nil }
}

/// Per-event notification switches on top of a global default.
public struct NotificationPreferences: Codable, Sendable, Equatable {
    /// "Benachrichtigungen standardmäßig aktivieren": applies to every event without an override.
    public var enabledByDefault: Bool = true
    public var overrides: [String: Bool] = [:]

    public init(enabledByDefault: Bool = true, overrides: [String: Bool] = [:]) {
        self.enabledByDefault = enabledByDefault
        self.overrides = overrides
    }

    public func isEnabled(_ eventKey: String) -> Bool { overrides[eventKey] ?? enabledByDefault }

    public mutating func set(_ enabled: Bool, for eventKey: String) {
        overrides[eventKey] = enabled == enabledByDefault ? nil : enabled
    }

    /// Drop overrides for events that no longer exist.
    public mutating func prune(keeping keys: Set<String>) {
        overrides = overrides.filter { keys.contains($0.key) }
    }
}

/// JSON-file persistence in Application Support. Readable while the device is
/// locked after first unlock, so background refresh can use it.
public actor SyncStore {
    private let url: URL
    private var cached: SyncState?

    public init(directory: URL? = nil, fileName: String = "sync-state.json") {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyHockeyData", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent(fileName)
    }

    public func load() -> SyncState {
        if let cached { return cached }
        let state = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(SyncState.self, from: $0) } ?? SyncState()
        cached = state
        return state
    }

    public func save(_ state: SyncState) {
        cached = state
        guard let data = try? Self.encoder.encode(state) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }

    public func reset() {
        cached = SyncState()
        try? FileManager.default.removeItem(at: url)
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
