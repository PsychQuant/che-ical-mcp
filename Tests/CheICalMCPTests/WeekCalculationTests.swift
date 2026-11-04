import XCTest
import Foundation

/// Tests for week calculation with internationalization support
/// These tests verify the week_starts_on parameter handles different
/// cultural conventions for first day of week correctly
final class WeekCalculationTests: XCTestCase {

    /// #306: the Gregorian calendar in the host zone. `Calendar.current` follows the host's region
    /// calendar, so under a Buddhist host `DateComponents(year: 2026, …)` was Buddhist 2026
    /// (Gregorian 1483, before the Gregorian reform, where the weekdays do not line up either).
    /// This file does not import the module, so it does not use `Calendar.gregorian(in:)`.
    private func gregorian() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: - Week Start Calculation Tests

    /// Test that Monday-start week correctly identifies week boundaries
    func testMondayWeekStart() {
        var calendar = gregorian()
        calendar.firstWeekday = 2 // Monday

        // Wednesday, January 29, 2026
        let wednesday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 29
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: wednesday
        ))!

        // Should be Monday, January 26, 2026
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: weekStart)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 26)
        XCTAssertEqual(components.weekday, 2, "Week should start on Monday (weekday=2)")
    }

    /// Test that Sunday-start week correctly identifies week boundaries
    func testSundayWeekStart() {
        var calendar = gregorian()
        calendar.firstWeekday = 1 // Sunday

        // Wednesday, January 29, 2026
        let wednesday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 29
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: wednesday
        ))!

        // Should be Sunday, January 25, 2026
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: weekStart)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 25)
        XCTAssertEqual(components.weekday, 1, "Week should start on Sunday (weekday=1)")
    }

    /// Test that Saturday-start week correctly identifies week boundaries
    func testSaturdayWeekStart() {
        var calendar = gregorian()
        calendar.firstWeekday = 7 // Saturday

        // Wednesday, January 29, 2026
        let wednesday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 29
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: wednesday
        ))!

        // Should be Saturday, January 24, 2026
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: weekStart)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 24)
        XCTAssertEqual(components.weekday, 7, "Week should start on Saturday (weekday=7)")
    }

    // MARK: - Edge Case: Today is the First Day of Week

    /// Test behavior when today is Monday and week starts on Monday
    func testTodayIsFirstDayOfWeek_Monday() {
        var calendar = gregorian()
        calendar.firstWeekday = 2 // Monday

        // Monday, January 26, 2026
        let monday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 26
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: monday
        ))!

        // Should be the same day (January 26)
        let components = calendar.dateComponents([.day], from: weekStart)
        XCTAssertEqual(components.day, 26, "When today is Monday and week starts on Monday, week start should be today")
    }

    /// Test behavior when today is Sunday and week starts on Sunday
    func testTodayIsFirstDayOfWeek_Sunday() {
        var calendar = gregorian()
        calendar.firstWeekday = 1 // Sunday

        // Sunday, January 25, 2026
        let sunday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 25
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: sunday
        ))!

        // Should be the same day (January 25)
        let components = calendar.dateComponents([.day], from: weekStart)
        XCTAssertEqual(components.day, 25, "When today is Sunday and week starts on Sunday, week start should be today")
    }

    // MARK: - Edge Case: Week Spanning Month/Year Boundary

    /// Test week calculation across month boundary
    func testWeekSpanningMonthBoundary() {
        var calendar = gregorian()
        calendar.firstWeekday = 2 // Monday

        // Thursday, February 2, 2026
        let thursday = calendar.date(from: DateComponents(
            year: 2026, month: 2, day: 2
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: thursday
        ))!

        // Week started on Monday, February 2, 2026
        let components = calendar.dateComponents([.year, .month, .day], from: weekStart)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 2)
    }

    /// Test week calculation across year boundary
    func testWeekSpanningYearBoundary() {
        var calendar = gregorian()
        calendar.firstWeekday = 2 // Monday

        // Friday, January 2, 2026
        let friday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 2
        ))!

        let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: friday
        ))!

        // Week should start on Monday, December 29, 2025
        let components = calendar.dateComponents([.year, .month, .day], from: weekStart)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 29, "Week starting Monday should go back to Dec 29, 2025")
    }

    // MARK: - Next Week Calculation

    /// Test next_week calculation with Monday start
    func testNextWeekCalculation_Monday() {
        var calendar = gregorian()
        calendar.firstWeekday = 2 // Monday

        // Wednesday, January 29, 2026
        let wednesday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 29
        ))!

        let thisWeekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: wednesday
        ))!
        let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeekStart)!

        // Next week should start Monday, February 2, 2026
        let components = calendar.dateComponents([.year, .month, .day], from: nextWeekStart)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 2)
    }

    /// Test next_week calculation with Sunday start
    func testNextWeekCalculation_Sunday() {
        var calendar = gregorian()
        calendar.firstWeekday = 1 // Sunday

        // Wednesday, January 29, 2026
        let wednesday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 29
        ))!

        let thisWeekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: wednesday
        ))!
        let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeekStart)!

        // Next week should start Sunday, February 1, 2026
        let components = calendar.dateComponents([.year, .month, .day], from: nextWeekStart)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 1)
    }

    // MARK: - Week Duration Tests

    /// Verify that week duration is always 7 days regardless of start day
    func testWeekDurationIsSevenDays() {
        var calendar = gregorian()

        let testDate = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 29
        ))!

        for firstWeekday in [1, 2, 7] { // Sunday, Monday, Saturday
            calendar.firstWeekday = firstWeekday
            let weekStart = calendar.date(from: calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: testDate
            ))!
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

            let duration = calendar.dateComponents([.day], from: weekStart, to: weekEnd)
            XCTAssertEqual(duration.day, 7, "Week should always be 7 days for firstWeekday=\(firstWeekday)")
        }
    }
}
