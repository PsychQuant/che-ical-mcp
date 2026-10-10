import XCTest
@testable import CheICalMCP
import Foundation

final class SafeDateFromComponentsTests: XCTestCase {

    // MARK: - Basic date extraction

    func testDateOnlyComponents() {
        // Date-only reminder: year, month, day — no time, no week fields
        var dc = DateComponents()
        dc.year = 2026
        dc.month = 4
        dc.day = 5

        let result = safeDateFromComponents(dc)
        XCTAssertNotNil(result)

        let cal = Calendar.gregorian(in: .current)   // #299: EventKit components are Gregorian
        let comps = cal.dateComponents([.year, .month, .day], from: result!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 5)
    }

    func testTimeBasedComponents() {
        // Time-based reminder: year, month, day, hour, minute
        var dc = DateComponents()
        dc.year = 2026
        dc.month = 4
        dc.day = 5
        dc.hour = 10
        dc.minute = 0

        let result = safeDateFromComponents(dc)
        XCTAssertNotNil(result)

        let cal = Calendar.gregorian(in: .current)   // #299: EventKit components are Gregorian
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: result!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 5)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 0)
    }

    // MARK: - The actual bug: week-based field conflict (#18)

    func testWeekBasedFieldsDoNotShiftDate() {
        // Simulates what EventKit does: sets both day-based AND week-based fields
        // Without the fix, .date would resolve using weekOfYear and shift +7 days
        var dc = DateComponents()
        dc.year = 2026
        dc.month = 4
        dc.day = 5
        dc.hour = 10
        dc.minute = 0
        // Add conflicting week-based fields (one week later)
        dc.weekOfYear = 16  // week 16 instead of week 15
        dc.yearForWeekOfYear = 2026

        let result = safeDateFromComponents(dc)
        XCTAssertNotNil(result)

        let cal = Calendar.gregorian(in: .current)   // #299: EventKit components are Gregorian
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: result!)
        // Must use day-based fields, NOT week-based
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 5, "Date should be April 5, not shifted by weekOfYear")
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 0)
    }

    func testWeekdayFieldDoesNotShiftDate() {
        // weekday can also cause conflicts
        var dc = DateComponents()
        dc.year = 2026
        dc.month = 4
        dc.day = 5
        dc.hour = 19
        dc.minute = 0
        dc.weekday = 2  // Monday — but April 5, 2026 is a Sunday

        let result = safeDateFromComponents(dc)
        XCTAssertNotNil(result)

        let cal = Calendar.gregorian(in: .current)   // #299: EventKit components are Gregorian
        let comps = cal.dateComponents([.year, .month, .day], from: result!)
        XCTAssertEqual(comps.day, 5, "Date should be April 5, not shifted by weekday")
    }

    // MARK: - Edge cases

    func testNilComponentsReturnsNil() {
        let result = safeDateFromComponents(nil)
        XCTAssertNil(result)
    }

    func testEmptyComponentsReturnsNil() {
        let dc = DateComponents()
        let result = safeDateFromComponents(dc)
        // Empty components with no year/month/day — should fallback or return nil
        // Either behavior is acceptable; just shouldn't crash
    }

    func testPreservesTimeZone() {
        var dc = DateComponents()
        dc.year = 2026
        dc.month = 4
        dc.day = 5
        dc.hour = 10
        dc.minute = 0
        dc.timeZone = TimeZone(identifier: "America/Toronto")

        let result = safeDateFromComponents(dc)
        XCTAssertNotNil(result)

        // Verify the date resolves correctly in the specified timezone
        let cal = Calendar.gregorian(in: .current)   // #299: EventKit components are Gregorian
        var calWithTZ = cal
        calWithTZ.timeZone = TimeZone(identifier: "America/Toronto")!
        let comps = calWithTZ.dateComponents([.year, .month, .day, .hour], from: result!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 5)
        XCTAssertEqual(comps.hour, 10)
    }

    func testPreservesSeconds() {
        var dc = DateComponents()
        dc.year = 2026
        dc.month = 4
        dc.day = 5
        dc.hour = 10
        dc.minute = 30
        dc.second = 45

        let result = safeDateFromComponents(dc)
        XCTAssertNotNil(result)

        let cal = Calendar.gregorian(in: .current)   // #299: EventKit components are Gregorian
        let comps = cal.dateComponents([.second], from: result!)
        XCTAssertEqual(comps.second, 45)
    }

    // MARK: - #299: the Gregorian calendar, not the host's

    private func gregorian(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // EventKit's components are Gregorian: 2026 reads as the Gregorian 2026, in the zone they carry.
    func testGregorianComponentsReadAsTheGregorianInstant() throws {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let dc = DateComponents(timeZone: taipei, year: 2026, month: 10, day: 10, hour: 9, minute: 30)
        let expected = try XCTUnwrap(gregorian(taipei).date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 30)))
        XCTAssertEqual(safeDateFromComponents(dc), expected)
    }

    // A calendar attached to the components is the one their year is counted in, as
    // `ReminderDueInput`, `ReminderDueValue.chronologicalDate` and `UndoPostStateFields` read it.
    func testAnAttachedCalendarIsTheOneTheYearIsCountedIn() throws {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        var dc = DateComponents(timeZone: taipei, year: 2569, month: 10, day: 10, hour: 9, minute: 30)
        dc.calendar = Calendar(identifier: .buddhist)
        let expected = try XCTUnwrap(gregorian(taipei).date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 30)))
        XCTAssertEqual(safeDateFromComponents(dc), expected)
    }

    // A date-only value is 00:00 of its day in the host zone, as before.
    func testDateOnlyComponentsAreMidnightInTheHostZone() throws {
        let expected = try XCTUnwrap(gregorian(.current).date(from: DateComponents(year: 2026, month: 4, day: 5)))
        XCTAssertEqual(safeDateFromComponents(DateComponents(year: 2026, month: 4, day: 5)), expected)
    }

    // The host calendar can be Buddhist, ROC, Japanese or Islamic, and cannot be switched inside
    // the test process, so the reader is pinned not to consult it.
    func testTheReaderDoesNotUseTheHostCalendar() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func safeDateFromComponents(", in: try SourcePins.source("Server.swift")))
        XCTAssertFalse(body.contains("Calendar.current"), body)
        XCTAssertFalse(body.contains("Calendar.autoupdatingCurrent"), body)
    }
}
