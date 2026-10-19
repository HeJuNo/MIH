import Foundation

/// Severity of a diagnostic message, lowest first.
public enum LogLevel: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case debug, info, warning, error

    public var id: Self { self }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Functional area a message belongs to; each can be switched on/off separately.
public enum LogArea: String, Codable, Sendable, CaseIterable, Identifiable {
    case app, sync, background, network, changes, notifications, history, status

    public var id: Self { self }
}

/// Where the kit writes diagnostics. The app decides about filtering and storage.
/// Never pass secrets (password, token) into a message.
public struct LogSink: Sendable {
    private let accepts: @Sendable (LogLevel, LogArea) -> Bool
    private let write: @Sendable (LogLevel, LogArea, String) -> Void

    public init(accepts: @escaping @Sendable (LogLevel, LogArea) -> Bool = { _, _ in true },
                _ write: @escaping @Sendable (LogLevel, LogArea, String) -> Void) {
        self.accepts = accepts
        self.write = write
    }

    public static let none = LogSink(accepts: { _, _ in false }) { _, _, _ in }

    /// The message is only built when the level/area is enabled.
    public func callAsFunction(_ level: LogLevel, _ area: LogArea, _ message: @autoclosure () -> String) {
        guard accepts(level, area) else { return }
        write(level, area, message())
    }
}
