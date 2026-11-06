import XCTest
@testable import CheICalMCP

/// #373 verify round 2 (PR #379): the #5 weekday check of `update_event` must read the planned
/// start in the zone the event will have after the update. Before 16bd723 the check ran after
/// `event.isAllDay = true`, which clears the event's time zone in EventKit, so an all-day result
/// was read in the host zone; moving the check before the writes made it read the stored zone
/// and refuse calls the old code accepted.
final class WeekdayCheckZoneTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func testAnAllDayResultIsReadInTheHostZoneWhateverTheStoredZone() {
        XCTAssertNil(WeekdayCheck.zone(resultIsAllDay: true, requested: nil, clearTimezone: false, stored: newYork))
        XCTAssertNil(WeekdayCheck.zone(resultIsAllDay: true, requested: nil, clearTimezone: true, stored: newYork))
    }

    func testATimedResultUsesTheRequestedZoneFirst() {
        XCTAssertEqual(WeekdayCheck.zone(resultIsAllDay: false, requested: tokyo, clearTimezone: false, stored: newYork), tokyo)
    }

    func testATimedResultWithAClearedZoneIsReadInTheHostZone() {
        XCTAssertNil(WeekdayCheck.zone(resultIsAllDay: false, requested: nil, clearTimezone: true, stored: newYork))
    }

    func testATimedResultOtherwiseKeepsTheStoredZone() {
        XCTAssertEqual(WeekdayCheck.zone(resultIsAllDay: false, requested: nil, clearTimezone: false, stored: newYork), newYork)
    }

    /// The reported case: host Asia/Taipei, a weekly Monday series stored in America/New_York,
    /// `all_day: true, start_time: 2026-11-09`. The planned start is Monday 00:00 +08:00, which is
    /// Sunday 11:00 in New York; the all-day result is read in the host zone, so it is a Monday.
    func testTheTaipeiHostNewYorkSeriesAllDayMoveIsAMonday() {
        let host = Calendar.gregorian(in: taipei)
        let start = host.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        XCTAssertEqual(WeekdayCheck.weekday(of: start, resultIsAllDay: true, requested: nil,
                                            clearTimezone: false, stored: newYork, host: host), 2, "Monday")
        XCTAssertEqual(WeekdayCheck.weekday(of: start, resultIsAllDay: false, requested: nil,
                                            clearTimezone: false, stored: newYork, host: host), 1,
                       "a timed result keeps the stored zone: Sunday in New York")
    }

    // MARK: - #454: every frequency uses days_of_week

    /// Measured on iCloud: a start off the days left a stray first occurrence on daily, monthly and
    /// yearly rules, and on a monthly series the store rewrote the rule's weekday.
    func testCreateAndARuleInTheCallCheckEveryFrequency() throws {
        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        let create = try XCTUnwrap(SourcePins.body(of: "func createEvent(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "WeekdayCheck.createRefusal(rule: recurrenceRule, start: startDate, timezone: timezone,", in: create).count, 1)
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "let daysToValidate = WeekdayCheck.daysToCheck(", in: update).count, 1)
        XCTAssertTrue(SourcePins.ranges(of: "frequency == .weekly ?", in: update).isEmpty)
        XCTAssertEqual(SourcePins.ranges(of: "WeekdayCheck.storedDaysCount(isWeekly: $0.frequency == .weekly, span: span)", in: update).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "EventKitError.weekdayOffNumberedRule(", in: update).count, 1)
    }

    /// Thursday 2031-12-04 in Taipei, against Monday and Tuesday, and against Thursday.
    func testEveryFrequencyMatchesAndRefuses() {
        let thursday = ISO8601DateFormatter().date(from: "2031-12-04T02:00:00Z")!
        var host = Calendar(identifier: .gregorian)
        host.timeZone = taipei
        for frequency in [RecurrenceRuleInput.Frequency.daily, .weekly, .monthly, .yearly] {
            func rule(_ days: [Int]?) -> RecurrenceRuleInput {
                RecurrenceRuleInput(frequency: frequency, interval: 1, endDate: nil, occurrenceCount: nil, daysOfWeek: days,
                                    daysOfMonth: nil, excludedOccurrenceDates: nil)
            }
            guard case .weekdayMismatch(let start, let expected)? = WeekdayCheck.createRefusal(rule: rule([2, 3]), start: thursday, timezone: nil, host: host) else {
                XCTFail("\(frequency) took a start off the days")
                continue
            }
            XCTAssertEqual(start, "Thursday")
            XCTAssertEqual(expected, "Monday, Tuesday")
            XCTAssertNil(WeekdayCheck.createRefusal(rule: rule([5]), start: thursday, timezone: nil, host: host), "\(frequency) on the days")
            XCTAssertNil(WeekdayCheck.createRefusal(rule: rule(nil), start: thursday, timezone: nil, host: host), "\(frequency) with no days")
            XCTAssertNil(WeekdayCheck.createRefusal(rule: rule([]), start: thursday, timezone: nil, host: host), "\(frequency) with an empty list")
        }
        XCTAssertNil(WeekdayCheck.createRefusal(rule: nil, start: thursday, timezone: nil, host: host), "a one-off event")
    }

    func testDaysToCheck() {
        func days(requested: [Int]? = nil, ruleInCall: Bool = false, stored: [Int]? = nil, count: Bool = true, moves: Bool) -> [Int]? {
            WeekdayCheck.daysToCheck(requested: requested, ruleInCall: ruleInCall, stored: stored, storedCount: count, startDayMoves: moves)
        }
        // A rule in the call.
        XCTAssertEqual(days(requested: [2], ruleInCall: true, stored: [5], moves: false), [2], "other days, the day staying: the rule would be off")
        XCTAssertEqual(days(requested: [2], ruleInCall: true, stored: [2], moves: true), [2], "the day moves")
        XCTAssertNil(days(requested: [3, 2], ruleInCall: true, stored: [2, 3], moves: false), "its own days again, as ending a series does")
        XCTAssertNil(days(requested: nil, ruleInCall: true, stored: [2], moves: true), "a rule with no days")
        XCTAssertNil(days(requested: [], ruleInCall: true, stored: [2], moves: true))
        // The series' own rule.
        XCTAssertEqual(days(stored: [2], moves: true), [2])
        XCTAssertNil(days(stored: [2], moves: false), "a time on the same day, or a zone, on a series already off its days")
        XCTAssertNil(days(stored: [2], count: false, moves: true), "one occurrence of a non-weekly series")
        XCTAssertNil(days(stored: nil, moves: true))
    }

    /// `clear_timezone` or `all_day` alone can move the day with no `start_time`.
    func testTheDayCanChangeWithAZoneAlone() {
        let host = Calendar(identifier: .gregorian)
        // Monday 22:00 in New York is Tuesday 11:00 in Taipei.
        let start = ISO8601DateFormatter().date(from: "2031-12-02T03:00:00Z")!
        XCTAssertTrue(WeekdayCheck.dayChanges(from: start, in: newYork, to: start, in: taipei, host: host))
        XCTAssertFalse(WeekdayCheck.dayChanges(from: start, in: taipei, to: start, in: taipei, host: host))
        XCTAssertFalse(WeekdayCheck.dayChanges(from: start, in: taipei, to: start.addingTimeInterval(3600), in: taipei, host: host), "a time on the same day")
    }

    func testANumberedRuleIsToldToUseCalendar() {
        XCTAssertTrue(WeekdayCheck.isNumberedRule(weekNumbers: [1], setPositions: nil))
        XCTAssertTrue(WeekdayCheck.isNumberedRule(weekNumbers: [-1], setPositions: nil))
        XCTAssertTrue(WeekdayCheck.isNumberedRule(weekNumbers: [0, 0], setPositions: [-1]))
        XCTAssertFalse(WeekdayCheck.isNumberedRule(weekNumbers: [0], setPositions: nil))
        XCTAssertFalse(WeekdayCheck.isNumberedRule(weekNumbers: [0], setPositions: []))
        let message = EventKitError.weekdayOffNumberedRule(startDay: "Thursday").errorDescription ?? ""
        for phrase in ["numbered weekday", "Thursday", "cannot write", "Calendar", "Nothing was written"] {
            XCTAssertTrue(message.contains(phrase), message)
        }
        XCTAssertFalse(message.contains("recurrence"), "recurrence would drop the week number: \(message)")
    }

    func testTheMismatchNamesBothWaysOut() {
        let message = EventKitError.weekdayMismatch(startDay: "Thursday", expectedDays: "Monday").errorDescription ?? ""
        for phrase in ["start_time", "recurrence", "Thursday", "Monday"] {
            XCTAssertTrue(message.contains(phrase), message)
        }
    }

    /// Moving one occurrence of a daily series was measured to work, so span this stays out of it.
    /// A weekly series refuses that move today, and this does not change it.
    func testStoredDaysCountOnASeriesMoveAndNotOnOneOccurrence() {
        XCTAssertTrue(WeekdayCheck.storedDaysCount(isWeekly: true, span: .thisEvent))
        XCTAssertTrue(WeekdayCheck.storedDaysCount(isWeekly: true, span: .futureEvents))
        XCTAssertTrue(WeekdayCheck.storedDaysCount(isWeekly: false, span: .futureEvents), "span all and span future")
        XCTAssertFalse(WeekdayCheck.storedDaysCount(isWeekly: false, span: .thisEvent), "one occurrence")
    }

    func testTheEventSchemasSayTheStartHasToBeOnTheDays() throws {
        let tools = CheICalMCPServer.defineTools()
        for name in ["create_event", "update_event", "create_events_batch"] {
            let schema = "\(String(describing: tools.first { $0.name == name }?.inputSchema))"
            XCTAssertTrue(schema.contains("the start has to fall on one of them"), name)
        }
    }
}
