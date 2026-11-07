import EventKit
import XCTest
@testable import CheICalMCP

/// #461: a start off `days_of_month` is refused, as one off `days_of_week` is (#454). Measured on
/// iCloud: a monthly rule on [15, 20] started on the 1st gave the 1st as a stray first occurrence,
/// a yearly rule on [15] the same, and moving a [1, 15] series to the 4th made the 4th a rule day.
final class MonthDayCheckTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private var host: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei
        return calendar
    }
    /// 2031-12-01 10:00 in Taipei.
    private let first = ISO8601DateFormatter().date(from: "2031-12-01T02:00:00Z")!

    private func rule(_ frequency: RecurrenceRuleInput.Frequency, _ days: [Int]?) -> RecurrenceRuleInput {
        RecurrenceRuleInput(frequency: frequency, interval: 1, endDate: nil, occurrenceCount: 3, daysOfWeek: nil,
                            daysOfMonth: days, excludedOccurrenceDates: nil)
    }

    func testCreateRefusesAStartOffTheDaysOnMonthlyAndYearly() {
        for frequency in [RecurrenceRuleInput.Frequency.monthly, .yearly] {
            guard case .dayOfMonthMismatch(let day, let expected)? = MonthDayCheck.createRefusal(
                rule: rule(frequency, [15, 20]), start: first, timezone: nil, host: host) else {
                XCTFail("\(frequency) took a start off the days"); continue
            }
            XCTAssertEqual(day, 1)
            XCTAssertEqual(expected, "15, 20")
            XCTAssertNil(MonthDayCheck.createRefusal(rule: rule(frequency, [1, 15]), start: first, timezone: nil, host: host), "\(frequency) on the days")
            XCTAssertNil(MonthDayCheck.createRefusal(rule: rule(frequency, nil), start: first, timezone: nil, host: host))
            XCTAssertNil(MonthDayCheck.createRefusal(rule: rule(frequency, []), start: first, timezone: nil, host: host))
        }
        XCTAssertNil(MonthDayCheck.createRefusal(rule: nil, start: first, timezone: nil, host: host), "a one-off event")
    }

    /// The day is read in the event's zone: 2031-11-30 22:00 in New York is the 1st in Taipei.
    func testTheDayIsReadInTheEventsZone() {
        let start = ISO8601DateFormatter().date(from: "2031-12-01T03:00:00Z")!
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertNil(MonthDayCheck.createRefusal(rule: rule(.monthly, [30]), start: start, timezone: newYork, host: host))
        XCTAssertNotNil(MonthDayCheck.createRefusal(rule: rule(.monthly, [30]), start: start, timezone: nil, host: host))
    }

    /// A stored rule from Calendar can count from the end of the month (-1 is the last day).
    func testANegativeDayCountsFromTheEndOfTheMonth() {
        XCTAssertTrue(MonthDayCheck.contains(day: 31, daysInMonth: 31, list: [-1]))
        XCTAssertTrue(MonthDayCheck.contains(day: 30, daysInMonth: 30, list: [-1]))
        XCTAssertFalse(MonthDayCheck.contains(day: 30, daysInMonth: 31, list: [-1]))
        XCTAssertTrue(MonthDayCheck.contains(day: 15, daysInMonth: 31, list: [1, 15]))
        XCTAssertFalse(MonthDayCheck.contains(day: 4, daysInMonth: 31, list: [1, 15]))
    }

    func testDaysToCheck() {
        func days(requested: [Int]? = nil, ruleInCall: Bool = false, stored: [Int]? = nil, storedUses: Bool = true,
                  span: EKSpan = .futureEvents, keeps: Bool = true, moves: Bool) -> [Int]? {
            MonthDayCheck.daysToCheck(requested: requested, ruleInCall: ruleInCall, stored: stored,
                                      storedUsesMonthDays: storedUses, span: span,
                                      ruleKeepsStoredPattern: keeps, startDayMoves: moves)
        }
        // A rule in the call.
        XCTAssertEqual(days(requested: [15], ruleInCall: true, stored: [1], moves: false), [15])
        XCTAssertNil(days(requested: [15, 1], ruleInCall: true, stored: [1, 15], moves: false), "its own days again with a bound")
        XCTAssertEqual(days(requested: [1, 15], ruleInCall: true, stored: [1, 15], keeps: false, moves: false), [1, 15], "another pattern")
        XCTAssertEqual(days(requested: [1, 15], ruleInCall: true, stored: [1, 15], moves: true), [1, 15], "the day moves")
        XCTAssertNil(days(requested: nil, ruleInCall: true, stored: [1], moves: true), "a rule with no days_of_month")
        // With no rule in the call nothing is checked here: a move is `refusesStoredMove`.
        XCTAssertNil(days(stored: [1, 15], moves: true))
    }

    /// Verify round 1, measured on iCloud: moving a [1, 15] series' start on span all to the 4th made
    /// the 4th a day of the rule, and to the 15th, another of its days, put two occurrences on the 15th.
    /// So any move of the start's day with no rule in the call is refused there.
    func testAStoredMoveIsRefused() {
        func refused(ruleInCall: Bool = false, stored: [Int]? = [1, 15], storedUses: Bool = true,
                     span: EKSpan = .futureEvents, moves: Bool = true) -> Bool {
            MonthDayCheck.refusesStoredMove(ruleInCall: ruleInCall, stored: stored, storedUsesMonthDays: storedUses,
                                            span: span, startDayMoves: moves)
        }
        XCTAssertTrue(refused(), "to the 4th or to the 15th")
        XCTAssertFalse(refused(moves: false), "a time on the same day")
        XCTAssertFalse(refused(span: .thisEvent), "one occurrence: not measured, not refused")
        XCTAssertFalse(refused(storedUses: false), "a daily or weekly rule ignores its days_of_month")
        XCTAssertFalse(refused(stored: nil))
        XCTAssertFalse(refused(stored: []))
        XCTAssertFalse(refused(ruleInCall: true), "a rule in the call is checked by daysToCheck")
        // Verify round 2, measured on iCloud: with the series' rule in the call, the same moves were
        // clean ([1, 15] resent with the start on the 15th; [1, 4, 15] with the start on the 4th), so
        // the message names that route, unless the stored rule has a part recurrence cannot write.
        let message = EventKitError.monthDayMoveRefused(expectedDays: "1, 15", unwritable: false, spanAll: true).errorDescription ?? ""
        for phrase in ["days_of_month [1, 15]", "two occurrences", "same day", "pass recurrence", "days_of_week", "span all", "monthly", "Nothing was written"] {
            XCTAssertTrue(message.contains(phrase), message)
        }
        // Verify round 3: the route was measured on span all only; span future meets #443.
        let future = EventKitError.monthDayMoveRefused(expectedDays: "1, 15", unwritable: false, spanAll: false).errorDescription ?? ""
        XCTAssertFalse(future.contains("pass recurrence"), future)
        for phrase in ["not measured", "#443", "span all", "Calendar"] {
            XCTAssertTrue(future.contains(phrase), future)
        }
        let unwritable = EventKitError.monthDayMoveRefused(expectedDays: "-1", unwritable: true, spanAll: true).errorDescription ?? ""
        for phrase in ["cannot write", "Calendar", "Nothing was written"] {
            XCTAssertTrue(unwritable.contains(phrase), unwritable)
        }
        XCTAssertFalse(unwritable.contains("pass recurrence"), unwritable)
    }

    /// Verify round 1: a day counted from the end of the month, months, weeks or days of the year, or
    /// a numbered weekday cannot be written by `recurrence`, so the refusal does not offer it.
    func testAStoredRuleRecurrenceCannotWriteIsToldToUseCalendar() {
        XCTAssertTrue(MonthDayCheck.storedUnwritable(days: [-1], numbered: false, otherParts: false))
        XCTAssertTrue(MonthDayCheck.storedUnwritable(days: [15], numbered: true, otherParts: false))
        XCTAssertTrue(MonthDayCheck.storedUnwritable(days: [15], numbered: false, otherParts: true))
        XCTAssertFalse(MonthDayCheck.storedUnwritable(days: [1, 15], numbered: false, otherParts: false))
        XCTAssertFalse(MonthDayCheck.storedUnwritable(days: nil, numbered: false, otherParts: false))
    }

    /// Verify round 1: the day is read in the Gregorian calendar, as the rules this tool writes,
    /// whatever calendar the host uses.
    func testTheDayIsGregorianOnANonGregorianHost() {
        var hijri = Calendar(identifier: .islamicUmmAlQura)
        hijri.timeZone = taipei
        XCTAssertNil(MonthDayCheck.createRefusal(rule: rule(.monthly, [1]), start: first, timezone: nil, host: hijri),
                     "2031-12-01 is the 1st in the Gregorian calendar")
        XCTAssertEqual(MonthDayCheck.day(of: first, zone: nil, host: hijri).daysInMonth, 31)
    }

    func testTheMessageNamesBothWaysOut() {
        let message = EventKitError.dayOfMonthMismatch(startDay: 4, expectedDays: "1, 15").errorDescription ?? ""
        for phrase in ["day 4", "days_of_month [1, 15]", "start_time", "recurrence", "Nothing was written"] {
            XCTAssertTrue(message.contains(phrase), message)
        }
    }

    /// The two entry points go through these functions, after the weekday check.
    func testCreateAndUpdateGoThroughTheCheck() throws {
        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        let create = try XCTUnwrap(SourcePins.body(of: "func createEvent(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "MonthDayCheck.createRefusal(rule: recurrenceRule, start: startDate, timezone: timezone,", in: create).count, 1)
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "let monthDaysToValidate = MonthDayCheck.daysToCheck(", in: update).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "ruleKeepsStoredPattern: ruleKeepsStoredPattern, startDayMoves: startDayMoves)", in: update).count, 2)
        XCTAssertEqual(SourcePins.ranges(of: "EventKitError.dayOfMonthMismatch(", in: update).count, 1)
        // Verify round 1: the stored side and the day's source, so a hardcoded nil or false fails here.
        XCTAssertEqual(SourcePins.ranges(of: "stored: storedRule?.daysOfTheMonth?.map(\\.intValue),", in: update).count, 2)
        XCTAssertEqual(SourcePins.ranges(of: "storedUsesMonthDays: storedUsesMonthDays,", in: update).count, 2, "refusesStoredMove and daysToCheck")
        XCTAssertEqual(SourcePins.ranges(of: "if MonthDayCheck.refusesStoredMove(", in: update).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "of: originalDay ?? plannedStart,", in: update).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "EventKitError.occurrenceAddressRefused(reason: MonthDayCheck.occurrenceReason)", in: update).count, 1)
        // Verify round 2: the refusal on the rule-in-call path is dayOfMonthMismatch only; the
        // "cannot write" wording belongs to the stored move.
        XCTAssertEqual(SourcePins.ranges(of: "dayOfMonthOffUnwritableRule", in: update).count, 0)
        XCTAssertEqual(SourcePins.ranges(of: "if MonthDayCheck.refusesStoredMove(ruleInCall: effectiveRule != nil,", in: update).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "storedUsesMonthDays: storedUsesMonthDays, span: span, startDayMoves: startDayMoves)", in: update).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "unwritable: MonthDayCheck.storedUnwritable(", in: update).count, 1)
        // Verify round 4: the span flag, so a hardcoded true fails here.
        XCTAssertEqual(SourcePins.ranges(of: "spanAll: applyToAll)", in: update).count, 1)
    }
}
