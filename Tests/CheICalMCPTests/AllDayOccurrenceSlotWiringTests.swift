import XCTest
@testable import CheICalMCP

/// #563: an in-memory `EKEvent` has no `/RID=` identifier, so whether the scan's `OccurrenceFace` records
/// that its slot came from `/RID=` is pinned on the source of `init(_ event: EKEvent)`.
final class AllDayOccurrenceSlotWiringTests: XCTestCase {
    private func initBody() throws -> String {
        let source = try SourcePins.source("EventKit/UndoPostStateGuard.swift")
        return try XCTUnwrap(SourcePins.body(of: "init(_ event: EKEvent)", in: source))
    }

    func testTheFaceReadsTheRIDAloneAndRecordsWhetherItHadOne() throws {
        let body = try initBody()
        XCTAssertEqual(SourcePins.ranges(of: "occurrenceDate: nil)", in: body).count, 1, "the /RID= read without the occurrenceDate fallback")
        XCTAssertEqual(SourcePins.ranges(of: "slot: fromRID ?? event.occurrenceDate", in: body).count, 1, "the slot is main's: /RID=, else occurrenceDate")
        XCTAssertEqual(SourcePins.ranges(of: "slotFromRID: fromRID != nil", in: body).count, 1)
    }

    /// The scan compares through the face's flag and the host zone (the default argument).
    func testTheScanPassesTheFacesItBuilds() throws {
        let source = try SourcePins.source("EventKit/UndoPostStateGuard.swift")
        let scan = try XCTUnwrap(SourcePins.body(of: "static func modifiedOccurrenceCount(of event: EKEvent", in: source))
        XCTAssertEqual(SourcePins.ranges(of: "differsFromSeries(OccurrenceFace(occurrence), series: seriesFace)", in: scan).count, 1)
        let differs = try XCTUnwrap(SourcePins.body(of: "static func differsFromSeries(", in: source))
        XCTAssertEqual(SourcePins.ranges(of: "slotFromRID: occurrence.slotFromRID", in: differs).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "allDay: one.isAllDay && all.isAllDay, zone: zone)", in: differs).count, 1)
    }
}
