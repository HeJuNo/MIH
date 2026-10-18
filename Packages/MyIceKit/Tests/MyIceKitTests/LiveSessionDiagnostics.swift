import XCTest
@testable import MyIceKit

/// Opt-in end-to-end check with a real account. Never prints the password or token.
///   LIVE_LOGIN_FILE=/path/login.txt LIVE_DUMP_DIR=/tmp/dir swift test --filter LiveSessionDiagnostics
/// login.txt format: "User: <email>" and "Pass: <password>" (one or two lines).
final class LiveSessionDiagnostics: XCTestCase {
    final class Ctx: RequestContextProviding, @unchecked Sendable {
        var token: String?
        func currentToken() async -> String? { token }
        func currentLanguage() async -> String { "de" }
    }

    func testRealAccountRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["LIVE_LOGIN_FILE"], let raw = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw XCTSkip("LIVE_LOGIN_FILE not set")
        }
        let dump = env["LIVE_DUMP_DIR"].map(URL.init(fileURLWithPath:))
        let (email, password) = try parse(raw)

        let ctx = Ctx()
        let client = APIClient(context: ctx)

        let loginData = try await rawData(client, .login(email: email, password: password))
        save(loginData, "login.json", dump)
        let payload: SessionPayload
        do {
            payload = try JSONDecoder().decode(SessionPayload.self, from: JSONNormalizer.normalize(loginData))
        } catch {
            return XCTFail("login decode: \(APIClient.describe(error))")
        }
        print("LOGIN status=\(payload.status ?? -1) message=\(payload.message ?? "-") user=\(payload.user != nil) token=\(payload.token != nil) app_data=\(payload.appData?.count ?? -1) club_games=\(payload.clubGames?.count ?? -1) player=\(payload.userinfo?.idPlayer ?? -1) club=\(payload.userinfo?.idClub ?? "-") clubs=\(payload.userinfo?.activeClubs?.count ?? -1)")
        guard payload.status == 1, let token = payload.token, let user = payload.user else {
            return XCTFail("login rejected: \(payload.message ?? "-")")
        }
        ctx.token = token

        for club in user.info.activeClubs ?? [] {
            let d = try await rawData(client, .refreshData(clubID: club.clubID))
            save(d, "refreshdata-\(club.id).json", dump)
            let r = try JSONDecoder().decode(SessionPayload.self, from: JSONNormalizer.normalize(d))
            let ids = (r.appData ?? []).map(\.id)
            print("CLUB \(club.id) \(club.clubName ?? "-"): app_data=\(ids.count) first=\(ids.prefix(3))")
        }
        let past = try await WebHistoryClient().pastEntries(email: email, password: password, playerID: user.info.idPlayer ?? 0,
                                                            seasonID: user.info.idSeason ?? "", clubID: user.info.idClub ?? "")
        print("WEBHISTORY past=\(past.count) newest=\(past.first.map { "\($0.id) \($0.event.name ?? "") \($0.event.agegroup ?? "")/\($0.event.practicegroup ?? "")" } ?? "-") oldest=\(past.last?.event.date ?? "-")")
        let refreshData = try await rawData(client, .refreshData(clubID: user.info.idClub))
        save(refreshData, "refreshdata.json", dump)
        do {
            let r = try JSONDecoder().decode(SessionPayload.self, from: JSONNormalizer.normalize(refreshData))
            print("REFRESH app_data=\(r.appData?.count ?? -1) club_games=\(r.clubGames?.count ?? -1)")
            for e in (r.appData ?? []).prefix(3) {
                guard let kind = e.kind, let id = e.primaryID else { continue }
                let d = try await rawData(client, .getEvent(kind: kind, eventID: id, playerID: user.info.idPlayer ?? 0, clubID: user.info.idClub))
                save(d, "getevent-\(e.id).json", dump)
                do {
                    let det = try JSONDecoder().decode(EventDetailResponse.self, from: JSONNormalizer.normalize(d))
                    print("DETAIL \(e.id) start=\(EventDates.start(of: e).map { "\($0)" } ?? "nil") type=\(det.eventData?.type ?? "-") staff=\(det.eventData?.convocation?.staff?.count ?? -1) players=\(det.eventData?.convocation?.available?.count ?? -1) msgs=\(det.eventData?.notifications?.count ?? -1)")
                } catch {
                    XCTFail("getevent \(e.id) decode: \(APIClient.describe(error))")
                }
            }
        } catch {
            XCTFail("refreshdata decode: \(APIClient.describe(error))")
        }
    }

    private func parse(_ raw: String) throws -> (String, String) {
        func value(_ key: String) -> String? {
            guard let r = raw.range(of: "\(key)\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let rest = raw[r.upperBound...]
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            var v = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
            if key == "User", let p = v.range(of: #"\s+Pass\s*:"#, options: [.regularExpression, .caseInsensitive]) { v = String(v[..<p.lowerBound]) }
            return v
        }
        guard let u = value("User"), let p = value("Pass"), !u.isEmpty, !p.isEmpty else { throw XCTSkip("cannot parse login file") }
        return (u, p)
    }

    private func rawData(_ client: APIClient, _ e: Endpoint) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: await client.makeRequest(e))
        let http = response as! HTTPURLResponse
        print("HTTP \(e.path) \(http.statusCode) \(http.value(forHTTPHeaderField: "content-type") ?? "-") bytes=\(data.count)")
        return data
    }

    private func save(_ data: Data, _ name: String, _ dir: URL?) {
        guard let dir else { return }
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: #""token"\s*:\s*"[^"]*""#, with: #""token":"<redacted>""#, options: .regularExpression)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
