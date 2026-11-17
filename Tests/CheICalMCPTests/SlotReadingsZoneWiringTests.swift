import XCTest
@testable import CheICalMCP

/// PR #558 round 1 (ruling A): which places take the wall-clock reading of a `/RID=`, read from
/// `Sources/` (comments stripped, whitespace collapsed), since the in-memory store cannot run them:
/// the capture of a whole-series delete asks the store whether the series has a time zone; each place
/// that records an occurrence's origin passes whether the event it resolved has one; the #263 captures
/// and the slot guard's holders take the instant reading only.
final class SlotReadingsZoneWiringTests: XCTestCase {
    private func code(_ file: String) throws -> String {
        SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source(file)))
    }

    private func count(_ piece: String, in text: String) -> Int { text.components(separatedBy: piece).count - 1 }

    func testTheDeleteCaptureTakesTheWallClockReadingOnlyForASeriesWithoutATimeZone() throws {
        let seam = try code("EventKit/SeriesExceptionsUndo.swift")
        XCTAssertEqual(count("let floating = store.isFloating(series)", in: seam), 1)
        XCTAssertEqual(count("SeriesExceptionsPlanner.capture(both, of: seriesIDs, windows: windows, zone: zone, floating: floating)", in: seam), 1)
        XCTAssertEqual(count("SeriesExceptionsPlanner.capture(observed, of: seriesIDs, window: window, zone: zone, floating: floating)", in: seam), 1)
        // #263's captures: the instant reading only, as before #539.
        XCTAssertEqual(count("return SeriesExceptionsPlanner.capture(observed, of: seriesIDs, windows: windows)", in: seam), 1)
        XCTAssertEqual(count("floating:", in: seam), 2)
        let store = try code("EventKit/SeriesExceptionsStoreSource.swift")
        XCTAssertEqual(count("func isFloating(_ series: EKEvent) -> Bool { OccurrenceOrigin.isFloating(series) }", in: store), 1)
        let origin = try code("EventKit/DeleteUndo.swift")
        XCTAssertEqual(count("static func isFloating(_ event: EKEvent) -> Bool { !event.isAllDay && event.timeZone == nil }", in: origin), 1)
    }

    /// The three places that record an origin: a delete through `DeletedEventSnapshots` (the series object,
    /// or the occurrence addressed by its own identifier), the whole-series delete of an occurrence
    /// addressed by its own identifier, and a split move (the event the move resolved).
    func testEachOriginIsTakenWithTheZoneOfTheEventItsCallResolved() throws {
        let deletes = try code("EventKit/DeleteUndo.swift")
        XCTAssertEqual(count("removedSnapshot.withOccurrenceOrigin(OccurrenceOrigin.of(removed, floating: OccurrenceOrigin.isFloating(series)))", in: deletes), 1)
        XCTAssertEqual(count("snapshot.withOccurrenceOrigin(OccurrenceOrigin.of(event, floating: OccurrenceOrigin.isFloating(event)))", in: deletes), 1)
        let manager = try code("EventKit/EventKitManager.swift")
        XCTAssertEqual(count("copied.withOccurrenceOrigin(OccurrenceOrigin.of(subject, floating: OccurrenceOrigin.isFloating(master)))", in: manager), 1)
        // No other place takes an origin from an event.
        let sources = try ["EventKit/DeleteUndo.swift", "EventKit/EventKitManager.swift", "EventKit/SeriesExceptionsUndo.swift",
                           "EventKit/EventKitManager+SeriesExceptions.swift", "Server.swift"].map(code).joined(separator: " ")
        XCTAssertEqual(count("OccurrenceOrigin.of(", in: sources), 3)
    }

    /// The holders: no wall-clock reading; an edited one is marked, so the guard compares it by its
    /// instant reading only.
    func testTheHoldersTakeTheInstantReadingOnly() throws {
        let guardCode = try code("EventKit/SeriesExceptions.swift")
        XCTAssertEqual(count("edited: isDetached || hasSlotSuffix)", in: guardCode), 1)
        let holder = try XCTUnwrap(SourceScan.body(of: "static func holder(", in: guardCode))
        XCTAssertFalse(holder.contains("SlotReadings"), holder)
    }
}
