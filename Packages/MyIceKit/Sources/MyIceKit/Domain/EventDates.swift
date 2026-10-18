import Foundation

/// The backend mixes `dd.mm.yyyy`, `yyyy-mm-dd` and `yyyy-mm-dd HH:mm:ss`.
/// All values are interpreted in the device time zone, as the JS `new Date()` did.
public enum EventDates {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    public static func parseDay(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: ".", with: "-")
        let parts = normalized.split(separator: "-")
        guard parts.count == 3 else { return nil }
        let iso = parts[0].count == 4 ? normalized : "\(parts[2])-\(parts[1])-\(parts[0])"
        return formatter("yyyy-MM-dd").date(from: String(iso.prefix(10)))
    }

    public static func parseDateTime(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: "T", with: " ")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let d = formatter(format).date(from: normalized) { return d }
        }
        return nil
    }

    /// Prefer `datetime`; otherwise combine `date` + `time_start`.
    public static func start(of event: Event) -> Date? {
        if let d = parseDateTime(event.datetime) { return d }
        guard let day = parseDay(event.date) else { return nil }
        let hm = (event.timeStart ?? "00:00").split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: hm.first ?? 0, minute: hm.dropFirst().first ?? 0, second: 0, of: day)
    }

    /// `HH:MM:SS` → `HH:MM`.
    public static func shortTime(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw.split(separator: ":").prefix(2).joined(separator: ":")
    }

    /// `"00:00"` and empty mean "not set" for departure/meeting times.
    public static func meaningfulTime(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != "00:00", t != "00:00:00" else { return nil }
        return t
    }

    /// `HH:MM – HH:MM`, dropping an end time that lies before the start (the API sends "01:00" for open-ended games).
    public static func timeRange(start: String?, end: String?, separator: String = " – ") -> String {
        let s = shortTime(start), e = shortTime(end)
        if s.isEmpty || (s == "00:00" && (e.isEmpty || e == "00:00")) { return "" }   // time not set yet
        guard !e.isEmpty, e > s else { return s }
        return s + separator + e
    }

    /// Groups events by calendar day, preserving server order (the original groups by formatted label).
    public static func groupedByDay(_ events: [Event]) -> [(day: Date, events: [Event])] {
        var order: [Date] = []
        var buckets: [Date: [Event]] = [:]
        for e in events {
            guard let d = parseDay(e.date) ?? start(of: e) else { continue }
            let key = Calendar.current.startOfDay(for: d)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        return order.map { ($0, buckets[$0]!) }
    }
}
