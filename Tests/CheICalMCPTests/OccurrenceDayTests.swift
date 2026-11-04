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
    }
}
