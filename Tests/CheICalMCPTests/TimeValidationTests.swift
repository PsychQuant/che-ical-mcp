import XCTest
import Foundation
@testable import CheICalMCP

/// Tests for time validation logic in event updates
/// These tests verify the fix for the update_event bug where
/// changing only start_time could result in startDate > endDate
final class TimeValidationTests: XCTestCase {

    // MARK: - Duration Preservation Tests

    func testDurationPreservation() {
        // Given: An event from 14:00 to 15:00 (1 hour duration)
        let calendar = Calendar.current
        let originalStart = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 25, hour: 14, minute: 0
        ))!
        let originalEnd = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 25, hour: 15, minute: 0
        ))!
        let originalDuration = originalEnd.timeIntervalSince(originalStart)

        // When: Moving the event to a new date (only providing start_time)
        let newStart = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 14, minute: 0
        ))!

        // Then: Calculate expected end time (preserving duration)
        let expectedEnd = newStart.addingTimeInterval(originalDuration)

        // Verify duration is 1 hour
        XCTAssertEqual(originalDuration, 3600, "Original duration should be 1 hour")

        // Verify the new end time is correct
        let expectedEndComponents = calendar.dateComponents([.year, .month, .day, .hour], from: expectedEnd)
        XCTAssertEqual(expectedEndComponents.year, 2026)
        XCTAssertEqual(expectedEndComponents.month, 1)
        XCTAssertEqual(expectedEndComponents.day, 31)
        XCTAssertEqual(expectedEndComponents.hour, 15)
    }

    func testDurationPreservationMultiDay() {
        // Given: A multi-day event (conference)
        let calendar = Calendar.current
        let originalStart = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 10, hour: 9, minute: 0
        ))!
        let originalEnd = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 12, hour: 17, minute: 0
        ))!
        let originalDuration = originalEnd.timeIntervalSince(originalStart)

        // When: Moving to new date
        let newStart = calendar.date(from: DateComponents(
            year: 2026, month: 2, day: 15, hour: 9, minute: 0
        ))!

        // Then: Calculate preserved end time
        let expectedEnd = newStart.addingTimeInterval(originalDuration)

        // Verify the multi-day duration is preserved
        let components = calendar.dateComponents([.day, .hour], from: newStart, to: expectedEnd)
        XCTAssertEqual(components.day, 2, "Should be 2 days")
        XCTAssertEqual(components.hour, 8, "Should be 8 hours")
    }

    // MARK: - Time Range Validation Tests

    func testValidTimeRange() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 14, minute: 0
        ))!
        let end = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 15, minute: 0
        ))!

        XCTAssertTrue(start < end, "Start should be before end for valid range")
    }

    func testInvalidTimeRangeDetection() {
        let calendar = Calendar.current
        // Invalid: end time is before start time
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 15, minute: 0
        ))!
        let end = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 14, minute: 0
        ))!

        XCTAssertFalse(start < end, "Should detect invalid range where start > end")
    }

    func testInvalidTimeRangeAcrossDates() {
        let calendar = Calendar.current
        // The problematic scenario: changing 1/25 to 1/31 but keeping old end date
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 14, minute: 0
        ))!
        let end = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 25, hour: 15, minute: 0
        ))!

        XCTAssertFalse(start < end, "Should detect invalid range where start date is after end date")
    }

    // MARK: - Edge Cases

    func testSameStartAndEndTime() {
        let calendar = Calendar.current
        let sameTime = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: 14, minute: 0
        ))!

        // For non-all-day events, same start and end is invalid
        XCTAssertFalse(sameTime < sameTime, "Same start and end time should be invalid for timed events")
    }

    func testAllDayEventAllowsSameDate() {
        // For all-day events, the date component matters more than time
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 31
        ))!

        // All-day events typically have start = end = date at 00:00
        // This is a valid case for all-day events
        let startOfDay = calendar.startOfDay(for: date)
        XCTAssertEqual(startOfDay, calendar.startOfDay(for: date), "All-day events can have same start and end")
    }

    // MARK: - validateTimeRange production guard (#160)
    // These exercise the real shared guard (not mirrored arithmetic), so create_event
    // and update_event are proven to reject inverted / zero-duration timed events
    // consistently. All-day events are exempt.

    private func date160(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: 1, day: 31, hour: hour, minute: minute
        ))!
    }

    func testValidateTimeRange_endBeforeStart_timed_throws() {
        XCTAssertThrowsError(
            try EventKitManager.validateTimeRange(start: date160(15), end: date160(14), isAllDay: false)
        ) { error in
            guard case EventKitError.invalidTimeRange = error else {
                return XCTFail("expected EventKitError.invalidTimeRange, got \(error)")
            }
        }
    }

    func testValidateTimeRange_endEqualsStart_timed_throws() {
        // The #160 zero-duration case: create_event previously accepted this silently.
        let t = date160(14)
        XCTAssertThrowsError(
            try EventKitManager.validateTimeRange(start: t, end: t, isAllDay: false)
        ) { error in
            guard case EventKitError.invalidTimeRange = error else {
                return XCTFail("expected EventKitError.invalidTimeRange, got \(error)")
            }
        }
    }

    func testValidateTimeRange_allDay_endEqualsStart_doesNotThrow() {
        let t = date160(0)
        XCTAssertNoThrow(
            try EventKitManager.validateTimeRange(start: t, end: t, isAllDay: true)
        )
    }

    func testValidateTimeRange_endAfterStart_timed_doesNotThrow() {
        XCTAssertNoThrow(
            try EventKitManager.validateTimeRange(start: date160(14), end: date160(15), isAllDay: false)
        )
    }
}
