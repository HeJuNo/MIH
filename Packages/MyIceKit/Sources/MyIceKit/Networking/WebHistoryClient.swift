import Foundation

/// Loads the *past* of the current season from the web app's JSON API
/// (`/api/players/playersfilter`), which the mobile API doesn't offer.
/// Uses its own cookie session; the password is only needed for this one call.
/// See `Analysis/MyIceHockey/web/WEB_API.md`.
public struct WebHistoryClient: Sendable {
    public var baseURL: URL

    public init(baseURL: URL = URL(string: "https://app.myice.hockey")!) {
        self.baseURL = baseURL
    }

    public enum WebError: Error { case loginFailed, badResponse }

    /// Returns past entries (strictly before `now`) of every given club, games and practices, newest first.
    /// The web API answers for the club selected in the session (`/?cl=<id>`), not the `club` parameter,
    /// so each club is selected first. Pass the primary club last so the session ends where it started.
    public func pastEntries(email: String, password: String, playerID: Int, seasonID: String, clubIDs: [String],
                            now: Date = .now) async throws -> [TrackedEntry] {
        // Ephemeral sessions keep cookies in their own in-memory jar, discarded afterwards.
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        _ = try await session.data(from: baseURL)
        let (body, loginResponse) = try await session.data(for: form("classes/process.php",
            ["login_email": email, "login_password": password, "sublogin": "1"], ajax: false))
        // A failed login lands back on the login form; success redirects into /players/.
        let landedOnLogin = String(decoding: body, as: UTF8.self).contains("name=\"sublogin\"")
        guard loginResponse.url?.path.contains("/players") == true || !landedOnLogin else { throw WebError.loginFailed }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let min = f.string(from: now.addingTimeInterval(-400 * 24 * 3600))
        let max = f.string(from: now)

        var entries: [TrackedEntry] = []
        var seen = Set<String>()
        for clubID in clubIDs {
            var select = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            select.queryItems = [URLQueryItem(name: "cl", value: clubID)]
            _ = try await session.data(from: select.url!)
            for type in ["g", "p"] {
                let (data, _) = try await session.data(for: form("api/players/playersfilter", [
                    "type": "filter", "player_id": String(playerID), "event_type": type,
                    "season": seasonID, "club": clubID, "minDate": min, "maxDate": max,
                ]))
                for entry in try Self.parse(data, clubID: clubID, fetchedAt: now) where seen.insert(entry.id).inserted {
                    entries.append(entry)
                }
            }
        }
        return entries
            .filter { (EventDates.start(of: $0.event) ?? .distantFuture) < now }
            .sorted { (EventDates.start(of: $0.event) ?? .distantPast) > (EventDates.start(of: $1.event) ?? .distantPast) }
    }

    private func form(_ path: String, _ fields: [String: String], ajax: Bool = true) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if ajax { r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        return r
    }

    /// Maps `playersfilter` rows onto the mobile models (same ids as `app_data`).
    static func parse(_ data: Data, clubID: String, fetchedAt: Date) throws -> [TrackedEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw WebError.badResponse }
        return rows.compactMap { row in
            var r = row.mapValues { v -> Any in (v as? String) == "None" ? NSNull() : v }
            let isGame = r["id_game"] != nil
            r["category"] = isGame ? "games" : "practices"
            if let d = r["date"] as? String, let t = r["time_start"] as? String { r["datetime"] = "\(d) \(t)" }
            r["health_status_notes"] = r["health_notes"]
            r["event_notes"] = r["notes"]
            r["departure_time"] = r["departure"]; r["departure"] = nil
            r["meeting_time"] = r["meeting"]; r["meeting"] = nil
            if !isGame, let web = r["name"] as? String {
                // Web: name "U-14 (Winter)", type "Eistraining" → mobile: name "Eistraining", agegroup "U-14", practicegroup "Winter".
                if let open = web.firstIndex(of: "("), web.hasSuffix(")") {
                    r["agegroup"] = web[..<open].trimmingCharacters(in: .whitespaces)
                    r["practicegroup"] = String(web[web.index(after: open)..<web.index(before: web.endIndex)])
                } else {
                    r["agegroup"] = web
                }
                r["name"] = r["type"]
            }
            guard let json = try? JSONSerialization.data(withJSONObject: r) else { return nil }
            let normalized = JSONNormalizer.normalize(json)
            guard let event = try? JSONDecoder().decode(Event.self, from: normalized),
                  event.kind != nil else { return nil }
            let detail = try? JSONDecoder().decode(EventDetail.self, from: normalized)
            var entry = TrackedEntry(event: event, detail: detail, detailFetchedAt: fetchedAt, clubID: clubID)
            entry.archivedAt = fetchedAt
            return entry
        }
    }
}
