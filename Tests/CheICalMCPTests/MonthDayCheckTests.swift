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
        // The series' own rule, when the start's day moves on span all or future: the measured 4th.
        XCTAssertEqual(days(stored: [1, 15], moves: true), [1, 15])
        XCTAssertNil(days(stored: [1, 15], moves: false), "a time on the same day")
        XCTAssertNil(days(stored: [1, 15], span: .thisEvent, moves: true), "one occurrence: not measured, not refused")
        XCTAssertNil(days(stored: [15], storedUses: false, moves: true), "a daily or weekly rule ignores its days_of_month")
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
    }
}
