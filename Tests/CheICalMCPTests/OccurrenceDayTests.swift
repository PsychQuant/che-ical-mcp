import XCTest
@testable import CheICalMCP

/// #270 round 4: the day `findOccurrence` searches. A mutation that ignored the zone inside
/// `findOccurrence` kept every test green; the window is now a pure function tested with a zone
/// that differs from the host's, and `findOccurrence` is pinned to call it.
final class OccurrenceDayTests: XCTestCase {
    private let day = "2026-12-06"

    func testTheWindowIsTheDayInTheGivenZone() throws {
        let zone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let start = TestZones.midnight(day, in: zone)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: start.addingTimeInterval(13 * 3600), in: zone))
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end, TestZones.midnight("2026-12-07", in: zone))
    }

    /// The same instant in the host zone is another window: the zone is not ignored.
    func testTheZoneChangesTheWindow() throws {
        let zone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let instant = TestZones.midnight(day, in: zone)
        let inZone = try XCTUnwrap(OccurrenceDay.window(containing: instant, in: zone))
        let inHost = try XCTUnwrap(OccurrenceDay.window(containing: instant, in: nil))
        XCTAssertNotEqual(inZone.start, inHost.start)
        XCTAssertEqual(inHost.start, Calendar.current.startOfDay(for: instant), "nil is the host zone")
    }

    func testFindOccurrenceSearchesTheWindow() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        let body = try XCTUnwrap(SourceScan.body(of: "func findOccurrence(identifier: String, on date: Date, in timeZone: TimeZone? = nil, slot: Date? = nil) -> EKEvent? {", in: code))
        XCTAssertEqual(SourcePins.ranges(of: "guard let window = OccurrenceDay.window(containing: date, in: timeZone) else { return nil } let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)", in: body).count, 1)
        XCTAssertFalse(body.contains("startOfDay"), "the window is computed in one place")
        // Final review: a line inserted above the pinned text (shadowing `date` or `timeZone`)
        // survived a substring pin. The body must open with the window and never rebind either.
        let trimmed = body.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "{" || $0 == " " })
        XCTAssertTrue(trimmed.hasPrefix("guard let window = OccurrenceDay.window(containing: date, in: timeZone)"), String(trimmed.prefix(160)))
        for rebinding in ["let date", "var date", "let timeZone", "var timeZone", "date =", "timeZone ="] {
            XCTAssertFalse(body.contains(rebinding), "findOccurrence rebinds an input: \(rebinding)")
        }
    }

    /// Final review: the input the real chain sends is a date-only value parsed to exactly midnight
    /// in the event's zone. `startOfDay(for: date - 1s)` searched the day before and stayed green.
    func testMidnightInTheZoneIsTheStartOfItsOwnDay() throws {
        let zone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let midnight = TestZones.midnight(day, in: zone)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: midnight, in: zone))
        XCTAssertEqual(window.start, midnight)
        let before = try XCTUnwrap(OccurrenceDay.window(containing: midnight.addingTimeInterval(-1), in: zone))
        XCTAssertEqual(before.end, midnight, "the instant before midnight belongs to the previous day")
    }

    /// Final review: `end = start + 86 400` survived; a 25-hour DST day must end at the next midnight.
    func testA25HourDayEndsAtTheNextMidnight() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = TestZones.midnight("2026-11-01", in: ny)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: start.addingTimeInterval(3600), in: ny))
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 25 * 3600)
    }
}
