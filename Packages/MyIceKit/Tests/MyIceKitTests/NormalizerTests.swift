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

    func testEmptyListWhereObjectExpected() throws {
        let json = #"{"eventData":{"convocation":[],"notifications":[],"available":"0"}}"#
        let r = try JSONDecoder().decode(EventDetailResponse.self, from: JSONNormalizer.normalize(Data(json.utf8)))
        XCTAssertNil(r.eventData?.convocation)
        XCTAssertEqual(r.eventData?.available, 0)
    }
}
