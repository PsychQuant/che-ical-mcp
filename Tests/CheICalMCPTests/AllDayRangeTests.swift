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

    // MARK: planUpdate — the dates update_event writes

    private func plan(storedStart: Date, storedEnd: Date, storedAllDay: Bool,
                      newStart: Date? = nil, newEnd: Date? = nil, requestedAllDay: Bool? = nil) throws -> AllDayRange.UpdatePlan {
        try AllDayRange.planUpdate(storedStart: storedStart, storedEnd: storedEnd, storedAllDay: storedAllDay,
                                   newStart: newStart, newEnd: newEnd, requestedAllDay: requestedAllDay,
                                   calendar: calendar)
    }

    func testPlanUpdateTimedToOneDayAllDayWithStartEqualToEndIsAccepted() throws {   // T3
        let p = try plan(storedStart: at(2027, 3, 21, 10), storedEnd: at(2027, 3, 21, 11), storedAllDay: false,
                         newStart: at(2027, 3, 21), newEnd: at(2027, 3, 21), requestedAllDay: true)
        XCTAssertTrue(p.isAllDay)
        XCTAssertEqual(p.start, at(2027, 3, 21))
        XCTAssertEqual(p.end, at(2027, 3, 21, 23, 59, 59))
    }

    func testPlanUpdateOfAnAllDayEventUsesTheExclusiveEnd() throws {                 // U1
        let p = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1, 23, 59, 59), storedAllDay: true,
                         newStart: at(2027, 3, 1), newEnd: at(2027, 3, 3))
        XCTAssertEqual(p.end, at(2027, 3, 2, 23, 59, 59))
    }

    func testPlanUpdateStartOnlyKeepsTheNumberOfDays() throws {                      // S2
        let p = try plan(storedStart: at(2027, 3, 28), storedEnd: at(2027, 3, 29, 23, 59, 59), storedAllDay: true,
                         newStart: at(2027, 4, 1, 10))
        XCTAssertEqual(p.start, at(2027, 4, 1))
        XCTAssertEqual(p.end, at(2027, 4, 2, 23, 59, 59))
    }

    /// #364 verify round 1: a stored all-day end may be an exclusive next-midnight (another
    /// client or source wrote it). A start-only move must count days with the same rule.
    func testPlanUpdateStartOnlyCountsAStoredMidnightEndAsExclusive() throws {
        let p = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 2), storedAllDay: true,
                         newStart: at(2027, 4, 1))
        XCTAssertEqual(p.end, at(2027, 4, 1, 23, 59, 59), "one day stays one day")
        let q = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 4), storedAllDay: true,
                         newStart: at(2027, 4, 1))
        XCTAssertEqual(q.end, at(2027, 4, 3, 23, 59, 59), "three days stay three days")
    }

    func testPlanUpdateFlagOnlyTurnsATimedEventIntoItsDay() throws {
        let p = try plan(storedStart: at(2027, 3, 25, 10), storedEnd: at(2027, 3, 25, 11), storedAllDay: false,
                         requestedAllDay: true)
        XCTAssertEqual(p.start, at(2027, 3, 25))
        XCTAssertEqual(p.end, at(2027, 3, 25, 23, 59, 59))
    }

    func testPlanUpdateOfATimedEventKeepsItsTimesAndChecksThem() {
        XCTAssertThrowsError(try plan(storedStart: at(2027, 3, 25, 10), storedEnd: at(2027, 3, 25, 11), storedAllDay: false,
                                      newStart: at(2027, 3, 25, 12)  , newEnd: at(2027, 3, 25, 12)))
        XCTAssertNoThrow(try {
            let p = try self.plan(storedStart: self.at(2027, 3, 25, 10), storedEnd: self.at(2027, 3, 25, 11), storedAllDay: false,
                                  newStart: self.at(2027, 3, 26, 10))
            XCTAssertFalse(p.isAllDay)
            XCTAssertEqual(p.end, self.at(2027, 3, 26, 11))
        }())
    }

    func testPlanUpdateAllDayToTimedKeepsTheGivenTimes() throws {
        let p = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1, 23, 59, 59), storedAllDay: true,
                         newStart: at(2027, 3, 1, 9), newEnd: at(2027, 3, 1, 10), requestedAllDay: false)
        XCTAssertFalse(p.isAllDay)
        XCTAssertEqual([p.start, p.end], [at(2027, 3, 1, 9), at(2027, 3, 1, 10)])
    }

    func testPlanUpdateOfAnAllDayEventWithoutDateChangesLeavesItsDates() throws {
        let p = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 2, 23, 59, 59), storedAllDay: true)
        XCTAssertNil(p.datesToWrite, "nothing about the dates was requested, so nothing is written")
    }

    /// #364 verify round 2: a flag-only `all_day: false` turns the stored pair into a timed range,
    /// so it is checked like one (it used to skip the check and could save a zero-length event).
    func testPlanUpdateFlagOnlyAllDayToTimedIsChecked() throws {
        XCTAssertThrowsError(try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1), storedAllDay: true,
                                      requestedAllDay: false))
        let p = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1, 23, 59, 59), storedAllDay: true,
                         requestedAllDay: false)
        XCTAssertFalse(p.isAllDay)
        XCTAssertEqual([p.start, p.end], [at(2027, 3, 1), at(2027, 3, 1, 23, 59, 59)])
    }

    /// #364 verify round 3: the day count of a start-only move came from elapsed time, and in a
    /// zone that starts DST at midnight the first day begins at 01:00, so 01:00 → next 00:00 is
    /// 23 h and counted as zero days. Days are counted from calendar dates.
    func testPlanUpdateStartOnlyKeepsTheDaysAcrossAMidnightDSTDay() throws {
        let santiago = TimeZone(identifier: "America/Santiago")!
        let sc = Calendar.gregorian(in: santiago)
        func d(_ m: Int, _ dd: Int, _ h: Int = 0) -> Date { sc.date(from: DateComponents(year: 2026, month: m, day: dd, hour: h))! }
        let stored = try AllDayRange.normalize(start: d(9, 6, 12), end: d(9, 9), calendar: sc)   // 09-06 .. 09-08
        let p = try AllDayRange.planUpdate(storedStart: stored.start, storedEnd: stored.end, storedAllDay: true,
                                           newStart: d(9, 20), newEnd: nil, requestedAllDay: nil, calendar: sc)
        let l = sc.dateComponents([.month, .day], from: p.end)
        XCTAssertEqual([l.month, l.day], [9, 22], "three days stay three days")
    }

    /// #364 verify round 3: a flag-only `all_day: false` must not write the dates while the event is
    /// still all-day (that order is #364's root cause); it only checks them.
    func testPlanUpdateFlagOnlyAllDayToTimedWritesNoDates() throws {
        let p = try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1, 23, 59, 59), storedAllDay: true,
                         requestedAllDay: false)
        XCTAssertNil(p.datesToWrite)
    }

    func testPlanUpdateFlagOnlyRefusalAsksForTheTimedTimes() {
        XCTAssertThrowsError(try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1), storedAllDay: true,
                                      requestedAllDay: false)) { error in
            XCTAssertTrue("\(error)".contains("start_time and end_time for the timed event"), "\(error)")
        }
    }

    // MARK: #373 — all-day → timed with only one of start_time / end_time

    /// #373: a start-only `all_day: false` on an all-day event used to keep the stored length, so a
    /// one-day event (00:00 – 23:59:59) became a timed event of 23 h 59 min 59 s. It is refused and
    /// asks for both times.
    func testPlanUpdateAllDayToTimedWithOnlyStartTimeIsRefused() {
        XCTAssertThrowsError(try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1, 23, 59, 59), storedAllDay: true,
                                      newStart: at(2027, 3, 1, 9), requestedAllDay: false)) { error in
            XCTAssertTrue("\(error)".contains("start_time and end_time for the timed event"), "\(error)")
        }
    }

    /// #373: an end-only `all_day: false` used to keep the stored start (00:00 of the day), so the
    /// event became a timed event starting at midnight. Same refusal, naming both fields.
    func testPlanUpdateAllDayToTimedWithOnlyEndTimeIsRefused() {
        XCTAssertThrowsError(try plan(storedStart: at(2027, 3, 1), storedEnd: at(2027, 3, 1, 23, 59, 59), storedAllDay: true,
                                      newEnd: at(2027, 3, 1, 10), requestedAllDay: false)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("start_time") && text.contains("end_time"), text)
        }
    }

    /// #373: the guard is only for the flip. A start-only move of an event that stays timed still
    /// keeps its duration (the documented update_event behaviour).
    func testPlanUpdateStartOnlyOfATimedEventStillKeepsItsDuration() throws {
        let p = try plan(storedStart: at(2027, 3, 25, 10), storedEnd: at(2027, 3, 25, 11), storedAllDay: false,
                         newStart: at(2027, 3, 26, 14), requestedAllDay: false)
        XCTAssertEqual([p.start, p.end], [at(2027, 3, 26, 14), at(2027, 3, 26, 15)])
    }

    // MARK: #374 — timed → all-day with only start_time keeps the days the timed range touched

    /// #374: a stored 22:00 – 02:00 event touches two days. `all_day: true, start_time: <date>` used
    /// to keep the 4 h, so a date-only start (00:00) gave 00:00 – 04:00, one day.
    func testPlanUpdateTimedToAllDayStartOnlyKeepsTheDaysTheTimedRangeTouched() throws {
        let p = try plan(storedStart: at(2027, 3, 25, 22), storedEnd: at(2027, 3, 26, 2), storedAllDay: false,
                         newStart: at(2027, 4, 1), requestedAllDay: true)
        XCTAssertTrue(p.isAllDay)
        XCTAssertEqual([p.start, p.end], [at(2027, 4, 1), at(2027, 4, 2, 23, 59, 59)])
    }

    /// #374: the day count does not depend on the time of day of the new start.
    func testPlanUpdateTimedToAllDayStartOnlyIgnoresTheTimeOfDayOfTheNewStart() throws {
        let p = try plan(storedStart: at(2027, 3, 25, 22), storedEnd: at(2027, 3, 26, 2), storedAllDay: false,
                         newStart: at(2027, 4, 1, 23), requestedAllDay: true)
        XCTAssertEqual([p.start, p.end], [at(2027, 4, 1), at(2027, 4, 2, 23, 59, 59)])
        let q = try plan(storedStart: at(2027, 3, 25, 22), storedEnd: at(2027, 3, 26, 2), storedAllDay: false,
                         newStart: at(2027, 4, 1, 1), requestedAllDay: true)
        XCTAssertEqual([q.start, q.end], [at(2027, 4, 1), at(2027, 4, 2, 23, 59, 59)])
    }

    /// #374: an end exactly at the next midnight is a boundary, so 22:00 – 00:00 is one day.
    func testPlanUpdateTimedToAllDayStartOnlyCountsAMidnightEndAsExclusive() throws {
        let p = try plan(storedStart: at(2027, 3, 25, 22), storedEnd: at(2027, 3, 26), storedAllDay: false,
                         newStart: at(2027, 4, 1, 23), requestedAllDay: true)
        XCTAssertEqual([p.start, p.end], [at(2027, 4, 1), at(2027, 4, 1, 23, 59, 59)])
    }

    /// #374: a zero-length timed event (start = end) counts as one day.
    func testPlanUpdateTimedToAllDayStartOnlyOfAZeroLengthEventIsOneDay() throws {
        let p = try plan(storedStart: at(2027, 3, 25, 10), storedEnd: at(2027, 3, 25, 10), storedAllDay: false,
                         newStart: at(2027, 4, 1, 15), requestedAllDay: true)
        XCTAssertEqual([p.start, p.end], [at(2027, 4, 1), at(2027, 4, 1, 23, 59, 59)])
    }

    /// #374: the start-only call and the flag-only call count the same days for the same stored range.
    func testPlanUpdateTimedToAllDayStartOnlyAgreesWithTheFlagOnlyCall() throws {
        let storedStart = at(2027, 3, 25, 22), storedEnd = at(2027, 3, 27, 2)
        let flagOnly = try plan(storedStart: storedStart, storedEnd: storedEnd, storedAllDay: false, requestedAllDay: true)
        let moved = try plan(storedStart: storedStart, storedEnd: storedEnd, storedAllDay: false,
                             newStart: at(2027, 3, 25, 23), requestedAllDay: true)
        XCTAssertEqual([flagOnly.start, flagOnly.end], [at(2027, 3, 25), at(2027, 3, 27, 23, 59, 59)])
        XCTAssertEqual([moved.start, moved.end], [flagOnly.start, flagOnly.end])
    }

    /// #374 in a zone that starts DST at midnight (America/Santiago, 2026-09-06 begins at 01:00):
    /// 22:00 on 09-05 to 02:00 on 09-06 is 3 h of elapsed time but touches two days.
    func testPlanUpdateTimedToAllDayStartOnlyKeepsTheDaysAcrossAMidnightDSTDay() throws {
        let santiago = TimeZone(identifier: "America/Santiago")!
        let sc = Calendar.gregorian(in: santiago)
        func d(_ m: Int, _ dd: Int, _ h: Int = 0) -> Date { sc.date(from: DateComponents(year: 2026, month: m, day: dd, hour: h))! }
        let p = try AllDayRange.planUpdate(storedStart: d(9, 5, 22), storedEnd: d(9, 6, 2), storedAllDay: false,
                                           newStart: d(9, 20), newEnd: nil, requestedAllDay: true, calendar: sc)
        let f = sc.dateComponents([.month, .day], from: p.start)
        let l = sc.dateComponents([.month, .day], from: p.end)
        XCTAssertEqual([f.month, f.day, l.month, l.day], [9, 20, 9, 21], "two days stay two days")
    }

    // MARK: a day that is not 24 hours long

    /// #364 verify round 2: zones that start DST at midnight begin that day at 01:00, so "one day
    /// after the start of the day, minus a second" lands on 00:59:59 of the NEXT day. The last
    /// second must come from the start of the next day.
    func testADayThatStartsAt0100EndsOnItself() throws {
        let santiago = TimeZone(identifier: "America/Santiago")!
        let sc = Calendar.gregorian(in: santiago)
        let day = sc.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        let r = try AllDayRange.normalize(start: day, end: day, calendar: sc)
        let l = sc.dateComponents([.month, .day, .hour, .minute, .second], from: r.end)
        XCTAssertEqual([l.month, l.day, l.hour, l.minute, l.second], [9, 6, 23, 59, 59])
    }

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
