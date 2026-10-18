import XCTest
@testable import MyIceKit

final class NormalizerTests: XCTestCase {
    func testMessyPHPLoginPayloadDecodes() throws {
        let json = #"""
        {"status":1,"token":"abc","userid":7,"useremail":"a@b.c","has_notification":false,
         "userinfo":{"id_player":12,"id_club":3,"fname":"Alex","lname":null,"photo":"","age":15,
                     "active_clubs":{"0":{"club_id":3,"club_name":"HC","club_logo":""},"1":{"club_id":4,"club_name":"EC","club_logo":"https://x.y/l o.png"}}},
         "app_data":{"0":{"id_game":99,"name":"Spiel","date":"2026-11-02","available":1,"health_status":3,"color":"#fff","agegroup":2012}},
         "club_games":[]}
        """#
        let p = try JSONDecoder().decode(SessionPayload.self, from: JSONNormalizer.normalize(Data(json.utf8)))
        XCTAssertEqual(p.status, 1)
        XCTAssertEqual(p.user?.id, "7")
        XCTAssertNil(p.userinfo?.photo)
        XCTAssertEqual(p.userinfo?.activeClubs?.count, 2)
        XCTAssertNotNil(p.userinfo?.activeClubs?.last?.clubLogo)
        XCTAssertEqual(p.appData?.first?.agegroup, "2012")
        XCTAssertEqual(p.appData?.first?.available, 1)
        XCTAssertNil(p.clubGames)
    }

    func testBooleansFromRealAPI() throws {
        let json = #"{"id_game":1,"time_start":"12:40","time_end":"01:00","health_status_notes":false,"event_notes":true,"has_notifications":false}"#
        let e = try JSONDecoder().decode(Event.self, from: JSONNormalizer.normalize(Data(json.utf8)))
        XCTAssertNil(e.healthStatusNotes)
        XCTAssertEqual(e.eventNotes, "1")
        XCTAssertNil(e.hasNotifications)
        XCTAssertEqual(EventDates.timeRange(start: e.timeStart, end: e.timeEnd), "12:40")
        XCTAssertEqual(EventDates.timeRange(start: "17:30", end: "18:20"), "17:30 – 18:20")
        XCTAssertNil(EventDates.meaningfulTime("00:00"))
    }

    func testEmptyListWhereObjectExpected() throws {
        let json = #"{"eventData":{"convocation":[],"notifications":[],"available":"0"}}"#
        let r = try JSONDecoder().decode(EventDetailResponse.self, from: JSONNormalizer.normalize(Data(json.utf8)))
        XCTAssertNil(r.eventData?.convocation)
        XCTAssertEqual(r.eventData?.available, 0)
    }
}

final class WebHistoryTests: XCTestCase {
    func testParsePlayersFilterRows() throws {
        let json = #"""
        {"draw":1,"data":[
         {"id_practice":"862805","id_group":"15832","name":"U-14 (Winter)","type":"Trockentraining","place":"Halle","date":"2026-10-16","time_start":"18:25:00","time_end":"19:10:00","health_status":"1","health_notes":"","notes":"Abholen bis 19:40","color":"#81c881","editable":"false"},
         {"id_game":"162754","name":"EAC Junior Capitals","agegroup":"U-14 (pre season)","type":"Freundschaft","place":"Halle B","date":"2026-08-15","time_start":"13:00:00","time_end":"15:00:00","meeting":"00:00","departure":"00:00","health_status":"1","notes":"Treffpunkt 11:45<br />","health_notes":"None","available":"0","color":"#81c881"}
        ]}
        """#
        let entries = try WebHistoryClient.parse(Data(json.utf8), clubID: "86", fetchedAt: .now)
        XCTAssertEqual(entries.map(\.id), ["p862805", "g162754"])
        let p = entries[0]
        XCTAssertEqual(p.event.name, "Trockentraining")
        XCTAssertEqual(p.event.agegroup, "U-14")
        XCTAssertEqual(p.event.practicegroup, "Winter")
        XCTAssertNotNil(EventDates.start(of: p.event))
        let g = entries[1]
        XCTAssertNil(g.event.healthStatusNotes)
        XCTAssertNil(EventDates.meaningfulTime(g.detail?.departureTime))
        XCTAssertEqual(PlainText.from(html: g.detail?.notes), "Treffpunkt 11:45")
        XCTAssertEqual(g.clubID, "86")
        XCTAssertEqual(EventDates.timeRange(start: "00:00", end: "00:00"), "")
    }
}
