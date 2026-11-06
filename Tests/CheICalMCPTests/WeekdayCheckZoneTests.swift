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
        XCTAssertEqual(SourcePins.ranges(of: "if let rule = recurrenceRule, let days = rule.daysOfWeek, !days.isEmpty {", in: create).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "EventKitError.weekdayMismatch(", in: create).count, 1)
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "let daysToValidate = effectiveRule?.daysOfWeek ?? existingDays", in: update).count, 1)
        XCTAssertTrue(SourcePins.ranges(of: "frequency == .weekly ?", in: update).isEmpty)
        XCTAssertEqual(SourcePins.ranges(of: "WeekdayCheck.storedDaysCount(isWeekly: firstRule.frequency == .weekly, span: span)", in: update).count, 1)
    }

    /// Moving one occurrence of a daily series works and was measured, so span this stays out of it.
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
