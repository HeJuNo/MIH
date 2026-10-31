import Foundation
import MyIceKit
import OSLog

/// One line of the in-app protocol.
struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var level: LogLevel
    var area: LogArea
    var message: String
}

/// Settings-aware diagnostic log: filters by switch/level/area, mirrors to OSLog and
/// appends to a JSON-lines file that the "Protokoll" tab reads. Readable after first
/// unlock so background runs can write to it. Safe to call from any thread.
final class AppLog: @unchecked Sendable {
    static var shared: AppLog { AppEnvironment.shared.log }

    static let maxEntries = 3000
    private let settings: SettingsStore
    private let url: URL
    private let queue = DispatchQueue(label: "MyHockeyData.log")
    private var lineCount: Int?
    private let os = Logger(subsystem: "MyHockeyData", category: "app")

    init(settings: SettingsStore = SettingsStore(), directory: URL? = nil) {
        self.settings = settings
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyHockeyData", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("protocol.jsonl")
    }

    /// Sink handed to `APIClient` and `SyncEngine`.
    var sink: LogSink {
        LogSink(accepts: { [self] in accepts($0, $1) }) { [self] in write($0, $1, $2) }
    }

    func accepts(_ level: LogLevel, _ area: LogArea) -> Bool {
        settings.loggingEnabled && level >= settings.logLevel && settings.logAreas.contains(area)
    }

    func callAsFunction(_ level: LogLevel, _ area: LogArea, _ message: @autoclosure () -> String) {
        guard accepts(level, area) else { return }
        write(level, area, message())
    }

    private func write(_ level: LogLevel, _ area: LogArea, _ message: String) {
        let entry = LogEntry(date: .now, level: level, area: area, message: message)
        os.log(level: level.osType, "[\(area.rawValue, privacy: .public)] \(message, privacy: .public)")
        queue.async { [self] in append(entry) }
    }

    private func append(_ entry: LogEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            lineCount = 0
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        try? handle.close()

        let count = (lineCount ?? countLines()) + 1
        lineCount = count
        // Trim in chunks so the file is not rewritten on every line.
        if count > Self.maxEntries + 500 {
            let kept = Array(readAll().suffix(Self.maxEntries))
            let data = kept.compactMap { try? Self.encoder.encode($0) }.reduce(into: Data()) { $0 += $1; $0.append(0x0A) }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lineCount = kept.count
        }
    }

    private func countLines() -> Int {
        ((try? Data(contentsOf: url)) ?? Data()).reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    private func readAll() -> [LogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(LogEntry.self, from: Data($0)) }
    }

    /// Newest first.
    func entries() async -> [LogEntry] {
        await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: readAll().reversed()) } }
    }

    func clear() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                try? FileManager.default.removeItem(at: url)
                lineCount = 0
                c.resume()
            }
        }
    }

    /// Plain-text export for sharing.
    static func text(_ entries: [LogEntry]) -> String {
        entries.reversed().map { e in
            "\(e.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon))) "
                + "\(e.level.title.uppercased()) [\(e.area.title)] \(e.message)"
        }.joined(separator: "\n")
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension LogLevel {
    var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var osType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}

extension LogArea {
    var title: String {
        switch self {
        case .app: "App"
        case .sync: "Sync"
        case .background: "Background"
        case .network: "Network"
        case .changes: "Changes"
        case .notifications: "Notifications"
        case .history: "History"
        case .status: "Status"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app"
        case .sync: "arrow.triangle.2.circlepath"
        case .background: "moon.zzz"
        case .network: "network"
        case .changes: "bell.badge"
        case .notifications: "app.badge"
        case .history: "clock.arrow.circlepath"
        case .status: "heart.text.square"
        case .calendar: "calendar.badge.clock"
        }
    }
}
