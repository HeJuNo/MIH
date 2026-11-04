import XCTest
@testable import MyIceKit

/// Regression test for the "day-section header says Morgen for an event that is actually
/// today" bug (see /BUGS.md): `date` and `datetime` disagreeing by one calendar day used to
/// put `start(of:)` (used by "Als Nächstes") and `groupedByDay` (used by the day headers) on
/// different days for the same event.
final class EventDatesTests: XCTestCase {
    func event(_ json: String) -> Event {
        try! JSONDecoder().decode(Event.self, from: Data(json.utf8))
    }

    func testGroupedByDayAgreesWithStartOfWhenDateAndDatetimeDisagree() {
        // `date` says the 2nd, `datetime` (the one the backend actually times the event by)
        // says 23:00 on the 1st — a UTC-midnight boundary effect on the server for a late event.
        let e = event(#"{"id_practice":1,"name":"Spätes Training","date":"2026-11-02","datetime":"2026-11-01 23:00:00","time_start":"23:00:00","time_end":"23:59:00"}"#)

        let startDay = Calendar.current.startOfDay(for: EventDates.start(of: e)!)
        let grouped = EventDates.groupedByDay([e])

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].day, startDay,
                        "groupedByDay must land on the same day as start(of:) for the same event")
    }

    func testGroupedByDayFallsBackToDateWhenDatetimeIsMissing() {
        let e = event(#"{"id_practice":2,"name":"Training","date":"2026-11-05","time_start":"18:00:00"}"#)
        let grouped = EventDates.groupedByDay([e])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].day, EventDates.parseDay("2026-11-05"))
    }

    func testEndAgreesWithStartsDay() {
        let e = event(#"{"id_practice":3,"name":"Spätes Training","date":"2026-11-02","datetime":"2026-11-01 23:00:00","time_start":"23:00:00","time_end":"23:59:00"}"#)
        let start = EventDates.start(of: e)!
        let end = EventDates.end(of: e)!
        XCTAssertEqual(Calendar.current.startOfDay(for: start), Calendar.current.startOfDay(for: end))
        XCTAssertGreaterThan(end, start)
    }
}
