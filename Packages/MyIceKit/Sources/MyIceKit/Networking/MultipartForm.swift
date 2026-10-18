import Foundation

/// Mirrors the browser `FormData` encoding used by the original client.
///
/// Wire-compat notes (see ANALYSIS.md §2.1):
/// * arrays are sent comma-joined (`FormData.append(k, [1,2])` → `"1,2"`)
/// * `nil` values are sent as the literal string `"null"` (JS `String(null)`)
public struct MultipartForm: Sendable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case int(Int)
        case list([Int])
        case null

        var wireString: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .list(let l): return l.map(String.init).joined(separator: ",")
            case .null: return "null"
            }
        }
    }

    public private(set) var fields: [(name: String, value: Value)] = []
    public let boundary: String

    public init(boundary: String = "----MyIceBoundary\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public mutating func append(_ name: String, _ value: Value) {
        fields.append((name, value))
    }

    public func value(for name: String) -> Value? {
        fields.last { $0.name == name }?.value
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public func encoded() -> Data {
        var data = Data()
        for (name, value) in fields {
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            data.append(value.wireString)
            data.append("\r\n")
        }
        data.append("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
