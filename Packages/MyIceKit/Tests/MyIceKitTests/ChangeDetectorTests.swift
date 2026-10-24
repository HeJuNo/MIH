import XCTest
@testable import MyIceKit

final class ChangeDetectorTests: XCTestCase {
    let now = EventDates.parseDateTime("2026-10-18 12:00:00")!

    func entry(_ json: String, detail: String? = nil) -> TrackedEntry {
        let d = JSONDecoder()
        let e = try! d.decode(Event.self, from: Data(json.utf8))
        return TrackedEntry(event: e, detail: detail.map { try! d.decode(EventDetail.self, from: Data($0.utf8)) })
    }

    let game = #"{"id_game":1,"name":"HC A vs HC B","date":"2026-10-25","datetime":"2026-10-25 18:00:00","time_start":"18:00:00","time_end":"20:00:00","place":"Halle 1","available":0,"health_status":3}"#

    func testNoChanges() {
        XCTAssertTrue(ChangeDetector.diff(old: [entry(game)], new: [entry(game)], now: now).isEmpty)
    }

    func testTimePlaceAndAttendance() {
        let moved = game.replacingOccurrences(of: "18:00:00\",\"time_end", with: "19:00:00\",\"time_end")
            .replacingOccurrences(of: "Halle 1", with: "Halle 2")
            .replacingOccurrences(of: "\"available\":0", with: "\"available\":1")
        let kinds = ChangeDetector.diff(old: [entry(game)], new: [entry(moved)], now: now).map(\.kind)
        XCTAssertTrue(kinds.contains(.time(old: "18:00–20:00", new: "19:00–20:00")))
        XCTAssertTrue(kinds.contains(.place(old: "Halle 1", new: "Halle 2")))
        XCTAssertTrue(kinds.contains(.attendance(old: 0, new: 1)))
    }

    func testAddedAndRemovedOnlyWhenUpcoming() {
        let past = #"{"id_practice":7,"name":"Training","date":"2026-10-01","datetime":"2026-10-01 18:00:00"}"#
        let added = ChangeDetector.diff(old: [], new: [entry(game), entry(past)], now: now)
        XCTAssertEqual(added.map(\.kind), [.added])
        let removed = ChangeDetector.diff(old: [entry(game), entry(past)], new: [], now: now)
        XCTAssertEqual(removed.map(\.kind), [.removed])
    }

    func testDetailDiffsRosterMessagesNotes() {
        let d1 = #"{"available":0,"notes":"<p>Treffpunkt &amp; Bus</p>","departure_time":"16:00","convocation":{"available":[{"fname":"Max","lname":"Muster"}],"staff":[{"fname":"Tom","lname":"Coach"}]},"notifications":[{"id_notification":1,"subject":"Alt"}]}"#
        let d2 = #"{"available":0,"notes":"<p>Treffpunkt &amp; Bus um 15:30</p>","departure_time":"15:30","convocation":{"available":[{"fname":"Max","lname":"Muster"},{"fname":"Lena","lname":"Neu"}],"staff":[{"fname":"Tom","lname":"Coach"}]},"notifications":[{"id_notification":1,"subject":"Alt"},{"id_notification":2,"subject":"Neu","message":"Bitte Trikot"}]}"#
        let kinds = ChangeDetector.diff(old: [entry(game, detail: d1)], new: [entry(game, detail: d2)], now: now).map(\.kind)
        XCTAssertTrue(kinds.contains(.departure(label: nil, old: "16:00", new: "15:30")))
        XCTAssertTrue(kinds.contains(.notes(new: "Treffpunkt & Bus um 15:30")))
        XCTAssertTrue(kinds.contains(.players(added: ["Lena Neu"], removed: [])))
        XCTAssertTrue(kinds.contains(.message(subject: "Neu", body: "Bitte Trikot")))
        XCTAssertFalse(kinds.contains { if case .staff = $0 { true } else { false } })
    }

    func testMissingDetailNeverProducesDetailChanges() {
        let d1 = #"{"notes":"x","convocation":{"available":[{"fname":"A","lname":"B"}]}}"#
        XCTAssertTrue(ChangeDetector.diff(old: [entry(game, detail: d1)], new: [entry(game)], now: now).isEmpty)
    }

    func testRosterPublished() {
        let d1 = #"{"convocation":{"available":[]}}"#
        let d2 = #"{"convocation":{"available":[{"fname":"A","lname":"B"},{"fname":"C","lname":"D"}]}}"#
        XCTAssertEqual(ChangeDetector.diff(old: [entry(game, detail: d1)], new: [entry(game, detail: d2)], now: now).map(\.kind), [.rosterPublished(players: 2)])
    }

    func testPlainTextNumericEntities() {
        XCTAssertEqual(PlainText.from(html: "Gr&#252;&#xDF;e<br>Team"), "Grüße\nTeam")
        XCTAssertEqual(PlainText.from(html: "ausw&auml;rts &amp; Stra&szlig;e"), "auswärts & Straße")
    }

    func testPreferences() {
        var p = NotificationPreferences(enabledByDefault: true)
        XCTAssertTrue(p.isEnabled("g1"))
        p.set(false, for: "g1")
        XCTAssertFalse(p.isEnabled("g1"))
        p.enabledByDefault = false
        XCTAssertFalse(p.isEnabled("g2"))
        p.set(false, for: "g1")
        XCTAssertNil(p.overrides["g1"])
    }

    func testChangeCodableRoundTrip() throws {
        let c = EventChange(entry: entry(game), detectedAt: now, kind: .players(added: ["A"], removed: ["B"]))
        let back = try JSONDecoder().decode(EventChange.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}

final class SyncEngineTests: XCTestCase {
    /// Serves canned JSON per path + id_club and records requests.
    final class FakeTransport: HTTPTransport, @unchecked Sendable {
        var responses: [String: String] = [:]
        var delays: [String: UInt64] = [:]
        var statusCodes: [String: Int] = [:]
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url!.lastPathComponent
            if let ns = delays[path] { try await Task.sleep(nanoseconds: ns) }
            if let code = statusCodes[path] {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let club = body.range(of: #"name="id_club"\r\n\r\n([^\r]*)"#, options: .regularExpression)
                .map { String(body[$0]).components(separatedBy: "\r\n\r\n").last ?? "" } ?? ""
            let key = "\(request.url!.lastPathComponent)#\(club)"
            let json = responses[key] ?? responses[request.url!.lastPathComponent] ?? "{}"
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    struct Ctx: RequestContextProviding {
        func currentToken() async -> String? { "t" }
        func currentLanguage() async -> String { "de" }
    }

    func testMultiClubMergeArchiveAndNewClubBaseline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SyncStore(directory: dir)
        let transport = FakeTransport()
        let engine = SyncEngine(api: APIClient(transport: transport, context: Ctx()), store: store)
        let t0 = EventDates.parseDateTime("2026-10-18 08:00:00")!

        transport.responses["refreshdata#86"] = #"{"app_data":[{"id_game":1,"name":"Spiel","datetime":"2026-10-18T12:40:00","date":"2026-10-18"},{"id_practice":2,"name":"Training","datetime":"2026-10-20T17:00:00","date":"2026-10-20","place":"A"}]}"#
        let first = try await engine.sync(clubIDs: ["86"], playerID: 1, now: t0)
        XCTAssertTrue(first.wasBaseline)
        XCTAssertEqual(first.entries.map(\.clubID), ["86", "86"])

        // Next day: game is past and gone, training moved, new club 83 entry appears (baseline for that club).
        transport.responses["refreshdata#86"] = #"{"app_data":[{"id_practice":2,"name":"Training","datetime":"2026-10-20T17:00:00","date":"2026-10-20","place":"B"}]}"#
        transport.responses["refreshdata#83"] = #"{"app_data":[{"id_practice":9,"name":"Akademie","datetime":"2026-10-21T15:00:00","date":"2026-10-21"}]}"#
        let t1 = EventDates.parseDateTime("2026-10-19 08:00:00")!
        let second = try await engine.sync(clubIDs: ["86", "83"], playerID: 1, now: t1)
        XCTAssertEqual(second.changes.map(\.kind), [.place(old: "A", new: "B")])
        XCTAssertEqual(second.entries.count, 2)
        let state = await store.load()
        XCTAssertEqual(state.archive?.map(\.id), ["g1"])

        // Club 83 is now known: a new entry there is reported.
        transport.responses["refreshdata#83"] = #"{"app_data":[{"id_practice":9,"name":"Akademie","datetime":"2026-10-21T15:00:00","date":"2026-10-21"},{"id_game":10,"name":"Neu","datetime":"2026-10-25T15:00:00","date":"2026-10-25"}]}"#
        let third = try await engine.sync(clubIDs: ["86", "83"], playerID: 1, now: t1)
        XCTAssertEqual(third.changes.map(\.kind), [.added])
    }

    func testRemovedUpcomingEntryStaysAsCancelledThenArchives() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SyncStore(directory: dir)
        let transport = FakeTransport()
        let engine = SyncEngine(api: APIClient(transport: transport, context: Ctx()), store: store)
        let t0 = EventDates.parseDateTime("2026-10-18 08:00:00")!
        let both = #"{"app_data":[{"id_game":1,"name":"Spiel","datetime":"2026-10-20T12:00:00","date":"2026-10-20","place":"Halle"},{"id_practice":2,"name":"Training","datetime":"2026-10-21T17:00:00","date":"2026-10-21"}]}"#
        let onlyTraining = #"{"app_data":[{"id_practice":2,"name":"Training","datetime":"2026-10-21T17:00:00","date":"2026-10-21"}]}"#
        transport.responses["refreshdata"] = both
        _ = try await engine.sync(clubIDs: ["86"], playerID: 1, now: t0)

        // Game vanishes: reported once, kept with its data and flagged.
        transport.responses["refreshdata"] = onlyTraining
        let removed = try await engine.sync(clubIDs: ["86"], playerID: 1, now: t0)
        XCTAssertEqual(removed.changes.map(\.kind), [.removed])
        XCTAssertEqual(removed.entries.map(\.id), ["g1", "p2"])
        XCTAssertEqual(removed.entries[0].cancelledAt, t0)
        XCTAssertEqual(removed.entries[0].event.place, "Halle")

        // Still gone: no second report, original cancellation date kept.
        let again = try await engine.sync(clubIDs: ["86"], playerID: 1, now: t0.addingTimeInterval(3600))
        XCTAssertTrue(again.changes.isEmpty)
        XCTAssertEqual(again.entries.first?.cancelledAt, t0)

        // Comes back: reported as added, flag cleared.
        transport.responses["refreshdata"] = both
        let back = try await engine.sync(clubIDs: ["86"], playerID: 1, now: t0.addingTimeInterval(7200))
        XCTAssertEqual(back.changes.map(\.kind), [.added])
        XCTAssertNil(back.entries.first?.cancelledAt)

        // Gone again, then its date passes: archived with the flag.
        transport.responses["refreshdata"] = onlyTraining
        _ = try await engine.sync(clubIDs: ["86"], playerID: 1, now: t0.addingTimeInterval(9000))
        let later = try await engine.sync(clubIDs: ["86"], playerID: 1, now: EventDates.parseDateTime("2026-10-20 20:00:00")!)
        XCTAssertEqual(later.entries.map(\.id), ["p2"])
        let archive = await store.load().archive ?? []
        XCTAssertEqual(archive.map(\.id), ["g1"])
        XCTAssertNotNil(archive.first?.cancelledAt)
    }

    func testOwnStatusChangeIsNotReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SyncStore(directory: dir)
        let transport = FakeTransport()
        let engine = SyncEngine(api: APIClient(transport: transport, context: Ctx()), store: store)
        let now = EventDates.parseDateTime("2026-10-18 08:00:00")!
        transport.responses["refreshdata"] = #"{"app_data":[{"id_practice":2,"datetime":"2026-10-20T17:00:00","date":"2026-10-20","health_status":3,"available":0}]}"#
        _ = try await engine.sync(clubIDs: ["86"], playerID: 1, now: now)

        await engine.applyLocalStatus(eventKey: "p2", submission: .init(status: .sick, notes: "Fieber"))
        transport.responses["refreshdata"] = #"{"app_data":[{"id_practice":2,"datetime":"2026-10-20T17:00:00","date":"2026-10-20","health_status":8,"health_status_notes":"Fieber","available":0}]}"#
        let r = try await engine.sync(clubIDs: ["86"], playerID: 1, now: now)
        XCTAssertTrue(r.changes.isEmpty, "\(r.changes.map(\.kind))")
    }

    /// A day within the detail horizon, as `yyyy-MM-dd`.
    let soon: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date().addingTimeInterval(5 * 24 * 3600))
    }()

    /// A failing/slow sync must not overwrite a change the detail screen detected meanwhile.
    func testDetailChangeSurvivesConcurrentFailingSync() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SyncStore(directory: dir)
        let transport = FakeTransport()
        let engine = SyncEngine(api: APIClient(transport: transport, context: Ctx()), store: store)
        let row = #"{"app_data":[{"id_practice":13,"name":"Spezial","datetime":"\#(soon)T17:30:00","date":"\#(soon)"}]}"#
        transport.responses["refreshdata"] = row
        transport.responses["getevent"] = #"{"eventData":{"convocation":{"available":[{"fname":"Adrian","lname":"S"},{"fname":"Jonas","lname":"O"}]}}}"#
        _ = try await engine.sync(clubIDs: ["86"], playerID: 1)

        transport.delays["refreshdata"] = 300_000_000
        transport.statusCodes["refreshdata"] = 500
        transport.responses["getevent"] = #"{"eventData":{"convocation":{"available":[{"fname":"Jonas","lname":"O"}]}}}"#
        let failing = Task { try await engine.sync(clubIDs: ["86"], playerID: 1) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let entry = await store.load().entries[0]
        _ = try await engine.refreshDetail(for: entry, playerID: 1)
        _ = try? await failing.value

        let state = await store.load()
        XCTAssertEqual(state.changeLog.map(\.kind), [.players(added: [], removed: ["Adrian S"])])
        XCTAssertEqual(state.entries[0].detail?.convocation?.available?.count, 1)
    }

    func testEveryChangedEventGetsItsOwnEntry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SyncStore(directory: dir)
        let transport = FakeTransport()
        let engine = SyncEngine(api: APIClient(transport: transport, context: Ctx()), store: store)
        transport.responses["refreshdata"] = #"{"app_data":[{"id_practice":1,"datetime":"\#(soon)T17:30:00","date":"\#(soon)","place":"A"},{"id_practice":2,"datetime":"\#(soon)T17:30:00","date":"\#(soon)","place":"A"},{"id_game":3,"datetime":"\#(soon)T12:00:00","date":"\#(soon)","place":"A"}]}"#
        _ = try await engine.sync(clubIDs: ["86"], playerID: 1)
        transport.responses["refreshdata"] = transport.responses["refreshdata"]!.replacingOccurrences(of: "\"A\"", with: "\"B\"")
        let r = try await engine.sync(clubIDs: ["86"], playerID: 1)
        XCTAssertEqual(Set(r.changes.map(\.eventKey)), ["p1", "p2", "g3"])
        let log = await store.load().changeLog
        XCTAssertEqual(log.count, 3)
    }

    func testDeadlineSkipsDetailsButKeepsOldOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SyncStore(directory: dir)
        let transport = FakeTransport()
        let engine = SyncEngine(api: APIClient(transport: transport, context: Ctx()), store: store)
        transport.responses["refreshdata"] = #"{"app_data":[{"id_practice":1,"datetime":"\#(soon)T17:30:00","date":"\#(soon)"}]}"#
        transport.responses["getevent"] = #"{"eventData":{"notes":"alt"}}"#
        _ = try await engine.sync(clubIDs: ["86"], playerID: 1)
        transport.responses["getevent"] = #"{"eventData":{"notes":"neu"}}"#
        let r = try await engine.sync(clubIDs: ["86"], playerID: 1, deadline: .distantPast)
        XCTAssertEqual(r.entries.first?.detail?.notes, "alt")
        XCTAssertTrue(r.changes.isEmpty)
    }
}
