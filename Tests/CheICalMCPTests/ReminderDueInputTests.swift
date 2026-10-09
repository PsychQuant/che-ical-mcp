import XCTest
@testable import CheICalMCP

/// #267: a reminder `due_date` given as a bare `YYYY-MM-DD` is a date-only due (a day, no time);
/// anything else is parsed as a timed due, as before. The duplicate check compares like with like.
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

    // MARK: - Duplicate check, like with like

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

    func testADayDoesNotMatchATimedDueAtMidnight() {
        var midnight = day(2026, 10, 18)
        midnight.hour = 0
        midnight.minute = 0
        midnight.timeZone = .current
        XCTAssertFalse(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: midnight))
    }

    func testATimedDueMatchesWithinAMinute() throws {
        var stored = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        stored.timeZone = .current
        XCTAssertTrue(ReminderDueInput.matches(.timed(instant.addingTimeInterval(30)), existing: stored))
        XCTAssertFalse(ReminderDueInput.matches(.timed(instant.addingTimeInterval(120)), existing: stored))
    }

    func testATimedDueDoesNotMatchADateOnlyDue() {
        let midnight = try! XCTUnwrap(Calendar.current.date(from: day(2026, 10, 18)))
        XCTAssertFalse(ReminderDueInput.matches(.timed(midnight), existing: day(2026, 10, 18)))
    }

    func testNoDueMatchesOnlyNoDue() {
        XCTAssertTrue(ReminderDueInput.matches(nil, existing: nil))
        XCTAssertFalse(ReminderDueInput.matches(nil, existing: day(2026, 10, 18)))
        XCTAssertFalse(ReminderDueInput.matches(.day(day(2026, 10, 18)), existing: nil))
        XCTAssertFalse(ReminderDueInput.matches(.timed(instant), existing: nil))
    }
}
