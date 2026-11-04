import XCTest
@testable import CheICalMCP

/// #383 verify: `occurrence_start` is ISO 8601 with the offset of the event's zone on that day,
/// or of this Mac's zone for a floating event.
final class OccurrenceStartTests: XCTestCase {
    func testTheOffsetIsTheEventZonesOnThatDay() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let winter = TestZones.midnight("2026-12-06", in: newYork)
        XCTAssertEqual(OccurrenceStart.string(winter, zone: newYork), "2026-12-06T00:00:00-05:00")
        let summer = TestZones.midnight("2026-07-06", in: newYork)
        XCTAssertEqual(OccurrenceStart.string(summer, zone: newYork), "2026-07-06T00:00:00-04:00")
    }

    func testAFloatingEventUsesTheHostZone() {
        let instant = TestZones.midnight("2026-12-06", in: .current)
        XCTAssertEqual(OccurrenceStart.string(instant, zone: nil), OccurrenceStart.string(instant, zone: .current))
        XCTAssertTrue(OccurrenceStart.string(instant, zone: nil).hasPrefix("2026-12-06T00:00:00"))
    }
}
