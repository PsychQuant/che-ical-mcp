import XCTest
@testable import CheICalMCP

/// #364 / #348: what an all-day (start, end) pair means, independent of whether the event is
/// already all-day when the dates are written. Inputs are the rows of the device matrix
/// (https://github.com/PsychQuant/che-ical-mcp/issues/364#issuecomment-6561732339), read in the
/// host zone. The rule is the exclusive boundary: an end exactly at a midnight of a day later than
/// the start day excludes that day; any other end includes its day; start = end is one day.
final class AllDayRangeTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private var calendar: Calendar { Calendar.gregorian(in: taipei) }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0,
                    in zone: TimeZone? = nil) -> Date {
        var c = Calendar.gregorian(in: zone ?? taipei)
        c.timeZone = zone ?? taipei
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    /// The days the normalized pair covers, as "MM-DD" strings, read in the host zone.
    private func days(_ start: Date, _ end: Date) throws -> (first: String, last: String) {
        let r = try AllDayRange.normalize(start: start, end: end, calendar: calendar)
        let f = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: r.start)
        let l = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: r.end)
        XCTAssertEqual([f.hour, f.minute, f.second], [0, 0, 0], "start is the start of its day")
        XCTAssertEqual([l.hour, l.minute, l.second], [23, 59, 59], "end is the last day at 23:59:59")
        return (String(format: "%02d-%02d", f.month!, f.day!), String(format: "%02d-%02d", l.month!, l.day!))
    }

    // MARK: create rows (C1-C6): the reading create_event already gives

    func testMidnightOfTheNextDayIsAnExclusiveBoundary() throws {          // C1
        let r = try days(at(2027, 2, 10), at(2027, 2, 11))
        XCTAssertEqual([r.first, r.last], ["02-10", "02-10"])
    }

    func testStartEqualToEndIsOneDay() throws {                           // C2, U4, T3
        let r = try days(at(2027, 2, 11), at(2027, 2, 11))
        XCTAssertEqual([r.first, r.last], ["02-11", "02-11"])
    }

    func testATimeOfDayIncludesItsDay() throws {                          // C3
        let r = try days(at(2027, 2, 12), at(2027, 2, 12, 12))
        XCTAssertEqual([r.first, r.last], ["02-12", "02-12"])
    }

    func testTheReadBackValueIsOneDay() throws {                          // C4, T2
        let r = try days(at(2027, 2, 13), at(2027, 2, 13, 23, 59, 59))
        XCTAssertEqual([r.first, r.last], ["02-13", "02-13"])
    }

    func testMultiDayExclusiveEnd() throws {                              // C5
        let r = try days(at(2027, 2, 14), at(2027, 2, 17))
        XCTAssertEqual([r.first, r.last], ["02-14", "02-16"])
    }

    func testOneSecondAfterMidnightIncludesThatDay() throws {             // C6
        let r = try days(at(2027, 2, 18), at(2027, 2, 18, 0, 0, 1))
        XCTAssertEqual([r.first, r.last], ["02-18", "02-18"])
    }

    // MARK: update of an already all-day event (U1-U3): now the same reading as create

    func testUpdateWithAMidnightEndNoLongerAddsThatDay() throws {         // U1 (was 03-01..03-03)
        let r = try days(at(2027, 3, 1), at(2027, 3, 3))
        XCTAssertEqual([r.first, r.last], ["03-01", "03-02"])
    }

    func testUpdateWithTheReadBackValueKeepsItsDay() throws {             // U2
        let r = try days(at(2027, 3, 4), at(2027, 3, 5, 23, 59, 59))
        XCTAssertEqual([r.first, r.last], ["03-04", "03-05"])
    }

    func testUpdateWithMiddayEndKeepsItsDay() throws {                    // U3
        let r = try days(at(2027, 3, 7), at(2027, 3, 8, 12))
        XCTAssertEqual([r.first, r.last], ["03-07", "03-08"])
    }

    // MARK: timed turned all-day (T1)

    func testATimedStartIsMovedToTheStartOfItsDay() throws {              // T1 with a timed start
        let r = try days(at(2027, 3, 15, 10), at(2027, 3, 16))
        XCTAssertEqual([r.first, r.last], ["03-15", "03-15"])
    }

    // MARK: offsets (O2): the instant is read in the host zone

    func testAnEndWithAnotherOffsetIsReadInTheHostZone() throws {         // O2
        let plus7 = TimeZone(secondsFromGMT: 7 * 3600)!
        let r = try days(at(2027, 4, 11), at(2027, 4, 11, 23, 59, 59, in: plus7))
        XCTAssertEqual([r.first, r.last], ["04-11", "04-12"])
    }

    // MARK: refusals

    func testAnEndDayBeforeTheStartDayIsRefused() {
        XCTAssertThrowsError(try AllDayRange.normalize(
            start: at(2027, 2, 11), end: at(2027, 2, 10, 12), calendar: calendar))
    }

    func testAMidnightEndBeforeTheStartDayIsRefused() {
        XCTAssertThrowsError(try AllDayRange.normalize(
            start: at(2027, 2, 11), end: at(2027, 2, 10), calendar: calendar))
    }

    func testAnEarlierTimeOnTheStartDayIsStillOneDay() throws {
        let r = try days(at(2027, 2, 11, 10), at(2027, 2, 11, 8))
        XCTAssertEqual([r.first, r.last], ["02-11", "02-11"])
    }

    // MARK: a day that is not 24 hours long

    func testADSTDayEndsAtItsOwnLastSecond() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let ny = Calendar.gregorian(in: newYork)
        // 2027-03-14 is 23 hours long in New York (clocks go forward at 02:00).
        let start = ny.date(from: DateComponents(year: 2027, month: 3, day: 14))!
        let end = ny.date(from: DateComponents(year: 2027, month: 3, day: 15))!
        let r = try AllDayRange.normalize(start: start, end: end, calendar: ny)
        let l = ny.dateComponents([.month, .day, .hour, .minute, .second], from: r.end)
        XCTAssertEqual([l.month, l.day, l.hour, l.minute, l.second], [3, 14, 23, 59, 59])
    }
}
