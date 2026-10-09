import XCTest
@testable import CheICalMCP

/// #267: a reminder `due_date` given as a bare `YYYY-MM-DD` is a date-only due (a day, no time);
/// anything else is parsed as a timed due, as before. The duplicate check keeps its earlier rule.
final class ReminderDueInputTests: XCTestCase {
    private struct Rejected: Error, Equatable {}
    private let instant = Date(timeIntervalSince1970: 1_792_224_000)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
        DateComponents(year: y, month: m, day: d)
    }

    func testABareDateIsADay() throws {
        let due = try ReminderDueInput.parse("2026-10-18", timed: { _ in self.instant })
        XCTAssertEqual(due, .day(day(2026, 10, 18)))
    }

    // The day carries no time and no zone: EventKit drops a zone on a date-only due (device
    // probe, 2026-10-09), so writing one would make the written value differ from the stored one.
    func testADayHasNoTimeAndNoZone() throws {
        guard case .day(let components) = try ReminderDueInput.parse("2026-10-18", timed: { _ in self.instant }) else {
            return XCTFail("expected a day")
        }
        XCTAssertNil(components.hour)
        XCTAssertNil(components.minute)
        XCTAssertNil(components.timeZone)
        XCTAssertNil(components.calendar)
    }

    func testADateWithATimeIsTimed() throws {
        let due = try ReminderDueInput.parse("2026-10-18T09:00:00+08:00", timed: { _ in self.instant })
        XCTAssertEqual(due, .timed(instant))
    }

    // Only the exact ten-character form is a day; every other string goes to the timed parser,
    // which keeps accepting or refusing it as before.
    func testOnlyTheExactDateFormIsADay() throws {
        for text in ["2026-10-18T00:00:00", "2026-1-8", " 2026-10-18", "2026-10-18 ", "20261018", "09:00"] {
            var seen: [String] = []
            let due = try ReminderDueInput.parse(text, timed: { seen.append($0); return self.instant })
            XCTAssertEqual(due, .timed(instant), text)
            XCTAssertEqual(seen, [text], text)
        }
    }

    // A bare date the timed parser refuses (no such day) fails exactly as it does today.
    func testABareDateTheTimedParserRefusesFailsTheSameWay() {
        XCTAssertThrowsError(try ReminderDueInput.parse("2026-02-30", timed: { _ in throw Rejected() })) { error in
            XCTAssertEqual(error as? Rejected, Rejected())
        }
    }

    // A day needs no instant (verify round 1, PR #298): a valid calendar day is a day even where
    // the timed parser would refuse it, for instance a host zone whose midnight is skipped by a
    // daylight-saving change. Only a day that does not exist goes to the timed parser.
    func testAValidDayDoesNotNeedTheTimedParser() throws {
        let due = try ReminderDueInput.parse("2026-10-18", timed: { _ in throw Rejected() })
        XCTAssertEqual(due, .day(day(2026, 10, 18)))
    }

    func testADayThatDoesNotExistGoesToTheTimedParser() {
        for text in ["2026-02-30", "2026-13-01", "2026-00-10", "2026-04-31"] {
            var seen: [String] = []
            XCTAssertThrowsError(try ReminderDueInput.parse(text, timed: { seen.append($0); throw Rejected() }), text)
            XCTAssertEqual(seen, [text], text)
        }
    }

    // MARK: - Duplicate check: unchanged by #267

    // The duplicate check keeps the rule it had before #267 (verify round 1, PR #298): a day
    // compares as 00:00 of that day in the host zone, so a retry after upgrading still finds the
    // reminder an earlier version stored at 00:00 from the same bare date.

    func testADayMatchesADateOnlyDueOnTheSameDay() {
        XCTAssertTrue(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: day(2026, 10, 18)))
        XCTAssertFalse(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: day(2026, 10, 19)))
    }

    // A zone or calendar EventKit attaches to a stored date-only due does not make it another day.
    func testADayMatchesAStoredDateOnlyDueWithAZone() {
        var stored = day(2026, 10, 18)
        stored.timeZone = TimeZone(identifier: "America/New_York")
        stored.calendar = Calendar(identifier: .gregorian)
        XCTAssertTrue(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: stored))
    }

    // What a bare date was stored as before #267: 00:00 of the day, timed, in the host zone.
    private func storedAtMidnightBeforeThisChange(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
        var midnight = day(y, m, d)
        midnight.hour = 0
        midnight.minute = 0
        midnight.timeZone = .current
        return midnight
    }

    func testADayMatchesAReminderStoredAtMidnightBeforeThisChange() {
        XCTAssertTrue(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: storedAtMidnightBeforeThisChange(2026, 10, 18)))
        XCTAssertFalse(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: storedAtMidnightBeforeThisChange(2026, 10, 19)))
    }

    func testADayDoesNotMatchATimedDueLaterThatDay() {
        var nine = storedAtMidnightBeforeThisChange(2026, 10, 18)
        nine.hour = 9
        XCTAssertFalse(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: nine))
    }

    func testATimedDueMatchesWithinAMinute() throws {
        var stored = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        stored.timeZone = .current
        XCTAssertTrue(ReminderDueInput.matches(.timed(instant.addingTimeInterval(30)), existing: stored))
        XCTAssertFalse(ReminderDueInput.matches(.timed(instant.addingTimeInterval(120)), existing: stored))
    }

    // As before: a timed request at 00:00 matches a date-only reminder on that day; one later that
    // day does not.
    func testATimedDueComparesWithADateOnlyDueAtMidnight() {
        let midnight = try! XCTUnwrap(Calendar.current.date(from: day(2026, 10, 18)))
        XCTAssertTrue(ReminderDueInput.matches(.timed(midnight), existing: day(2026, 10, 18)))
        XCTAssertFalse(ReminderDueInput.matches(.timed(midnight.addingTimeInterval(9 * 3600)), existing: day(2026, 10, 18)))
    }

    func testNoDueMatchesOnlyNoDue() {
        XCTAssertTrue(ReminderDueInput.matches(nil, existing: nil))
        XCTAssertFalse(ReminderDueInput.matches(nil, existing: day(2026, 10, 18)))
        XCTAssertFalse(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: nil))
        XCTAssertFalse(ReminderDueInput.matches(.timed(instant), existing: nil))
    }

    // MARK: - create_reminder wiring (source pins: the store path needs a real EKEventStore)

    // A day is written through setDueDay, an instant through the #134 timed write, and the
    // duplicate check is handed the input as given.
    func testCreateReminderWritesADayThroughSetDueDay() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func createReminder(", in: source))
        let flat = SourceScan.collapsingWhitespace(body)
        XCTAssertTrue(flat.contains("if case .day(let day)? = due { _ = ReminderDateSync.setDueDay(reminder, to: day) } else if case .timed(let due)? = due {"), flat)
        XCTAssertTrue(flat.contains("findDuplicateReminder(title: title, due: due, calendar: calendar)"), flat)
    }

    func testTheDuplicateCheckGoesThroughMatches() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func findDuplicateReminder(", in: source))
        let flat = SourceScan.collapsingWhitespace(body)
        XCTAssertTrue(flat.contains("reminder.title == title && ReminderDueInput.matches(due, existing: reminder.dueDateComponents)"), flat)
        XCTAssertFalse(flat.contains("timeIntervalSince"), "the minute window lives in ReminderDueInput.matches only")
    }
}
