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
