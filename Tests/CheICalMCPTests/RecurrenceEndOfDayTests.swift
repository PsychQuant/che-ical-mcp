import XCTest
@testable import CheICalMCP

/// #584: the last instant of a `YYYY-MM-DD` day in a zone, which a date-only `recurrence.end_date`
/// is stored as. Every zone is passed explicitly, so no result follows `TZ`.
final class RecurrenceEndOfDayTests: XCTestCase {
    private func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier)! }
    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // spec-example: recurrence-end-date / stored end
    func testTheLastInstantOfTheDayInTheZone() {
        XCTAssertEqual(FlexibleDate.endOfDay(ofDateOnly: "2026-12-14", in: zone("Asia/Taipei")), instant("2026-12-14T23:59:59+08:00"))
        XCTAssertEqual(FlexibleDate.endOfDay(ofDateOnly: "2026-12-14", in: zone("America/New_York")), instant("2026-12-14T23:59:59-05:00"))
        XCTAssertEqual(FlexibleDate.endOfDay(ofDateOnly: "2027-03-13", in: zone("America/New_York")), instant("2027-03-13T23:59:59-05:00"),
                       "the next day starts in daylight time")
        XCTAssertEqual(FlexibleDate.endOfDay(ofDateOnly: "2027-11-06", in: zone("America/New_York")), instant("2027-11-06T23:59:59-04:00"),
                       "the next day starts in standard time")
        XCTAssertEqual(FlexibleDate.endOfDay(ofDateOnly: "2028-03-11", in: zone("America/Havana")), instant("2028-03-11T23:59:59-05:00"),
                       "the next day's midnight is skipped: its first instant is 01:00")
        XCTAssertEqual(FlexibleDate.endOfDay(ofDateOnly: "2028-02-29", in: zone("UTC")), instant("2028-02-29T23:59:59Z"))
    }

    func testOnlyAPlainDateHasAnEndOfDay() {
        let taipei = zone("Asia/Taipei")
        for text in ["2026-12-14T00:00:00+08:00", "2026-12-14T10:00:00", "10:00", "2026-12-1", "2026/12/14", "2026-02-30", "20261214XY", ""] {
            XCTAssertNil(FlexibleDate.endOfDay(ofDateOnly: text, in: taipei), text)
        }
    }
}
