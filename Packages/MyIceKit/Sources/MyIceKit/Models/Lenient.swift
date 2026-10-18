import Foundation

/// The backend mixes `"1"` and `1` for the same field, and the JS client
/// compares loosely (`==`). Decode both into a single numeric value.
@propertyWrapper
public struct LenientInt: Codable, Hashable, Sendable {
    public var wrappedValue: Int?
    public init(wrappedValue: Int?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let i = try? c.decode(Int.self) { wrappedValue = i }
        else if let s = try? c.decode(String.self) {
            let t = s.trimmingCharacters(in: .whitespaces)
            wrappedValue = Int(t) ?? Double(t).map { Int($0) }
        }
        else if let b = try? c.decode(Bool.self) { wrappedValue = b ? 1 : 0 }
        else if let d = try? c.decode(Double.self) { wrappedValue = Int(d) }
        else { wrappedValue = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// IDs such as `id_club` arrive as either strings or numbers; normalise to String.
@propertyWrapper
public struct LenientString: Codable, Hashable, Sendable {
    public var wrappedValue: String?
    public init(wrappedValue: String?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let s = try? c.decode(String.self) { wrappedValue = s }
        else if let i = try? c.decode(Int.self) { wrappedValue = String(i) }
        else if let d = try? c.decode(Double.self) { wrappedValue = String(d) }
        else { wrappedValue = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Image URLs arrive as "", relative paths or garbage; never fail the whole payload.
@propertyWrapper
public struct LenientURL: Codable, Hashable, Sendable {
    public var wrappedValue: URL?
    public init(wrappedValue: URL?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard let s = try? c.decode(String.self) else { wrappedValue = nil; return }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { wrappedValue = nil; return }
        wrappedValue = URL(string: t) ?? t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue?.absoluteString)
    }
}

// Missing keys decode to nil instead of throwing.
extension KeyedDecodingContainer {
    public func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        try decodeIfPresent(type, forKey: key) ?? LenientInt(wrappedValue: nil)
    }
    public func decode(_ type: LenientString.Type, forKey key: Key) throws -> LenientString {
        try decodeIfPresent(type, forKey: key) ?? LenientString(wrappedValue: nil)
    }
    public func decode(_ type: LenientURL.Type, forKey key: Key) throws -> LenientURL {
        try decodeIfPresent(type, forKey: key) ?? LenientURL(wrappedValue: nil)
    }
}
