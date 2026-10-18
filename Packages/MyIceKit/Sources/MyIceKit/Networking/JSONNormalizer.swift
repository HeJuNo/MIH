import Foundation

/// Smooths over PHP JSON quirks before `Decodable` sees the payload:
/// * numbers → strings (`String?` fields accept them; `LenientInt` parses them back)
/// * `false` → `null`, `true` → `"1"` (the API uses `false` for "no notes")
/// * `[]` → `null` (PHP encodes an empty associative array as a list)
/// * objects keyed `"0","1",…` → arrays (PHP encodes non-sequential lists as objects)
enum JSONNormalizer {
    static func normalize(_ data: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: normalize(value: root), options: [.fragmentsAllowed])
        else { return data }
        return out
    }

    static func normalize(value: Any) -> Any {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" as Any : NSNull() }
            return n.stringValue
        case let a as [Any]:
            return a.isEmpty ? NSNull() : a.map(normalize(value:))
        case let d as [String: Any]:
            if !d.isEmpty, d.keys.allSatisfy({ Int($0) != nil }) {
                return d.sorted { Int($0.key)! < Int($1.key)! }.map { normalize(value: $0.value) }
            }
            return d.mapValues(normalize(value:))
        default:
            return value
        }
    }
}
