import XCTest
@testable import CheICalMCP

/// #428 verify r6: the series-id route reaches the first edited occurrence through an inner
/// `updateEvent` call, and its refusals (the started-series one among them) must run there before
/// anything is assigned or saved. `updateEvent` works on the event store, which no seam reaches, so
/// this is a source pin; the refusals' decisions are tested in `DetachedOccurrenceSpanTests`.
final class SeriesIdRouteWiringTests: XCTestCase {
    private func updateEventBody() throws -> String {
        let source = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source("EventKit/EventKitManager.swift")))
        let start = try XCTUnwrap(source.range(of: "func updateEvent("))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "func occurrenceZone("))
        return String(rest[..<end.lowerBound])
    }

    /// The outer call writes nothing before the inner one: no assignment and no save sit between
    /// the route's start and the inner call.
    func testTheRouteWritesNothingBeforeTheInnerCall() throws {
        let body = try updateEventBody()
        let route = try XCTUnwrap(body.range(of: "if applyToAll, let first = try firstEditedOccurrenceID(of: identifier) {"))
        let inner = try XCTUnwrap(body.range(of: "saved = try await updateEvent(", range: route.upperBound..<body.endIndex))
        let between = String(body[route.upperBound..<inner.lowerBound])
        XCTAssertFalse(between.contains("eventStore."), between)
        XCTAssertFalse(between.contains("event."), between)
        let call = String(body[inner.lowerBound...].prefix(700))
        XCTAssertTrue(call.contains("reachedThroughSeriesID: true)"), call)
    }

    /// In the inner call the refusal that carries `throughSeriesID` (and with it the started-series
    /// refusal) comes before the snapshot, the first field assignment and the save.
    func testTheStartedRefusalRunsBeforeTheFirstAssignmentAndTheSave() throws {
        let body = try updateEventBody()
        let refusal = try XCTUnwrap(body.range(of: "if let refusal = try DetachedOccurrenceSpan.updateRefusal("))
        let call = String(body[refusal.lowerBound...].prefix(1200))
        XCTAssertTrue(call.contains("throughSeriesID: reachedThroughSeriesID"), call)
        for later in ["let oldSnapshot = EventSnapshot(from: masterEvent)", "if let t = title { event.title = t }",
                      "event.startDate = dates.start", "try eventStore.save("] {
            let at = try XCTUnwrap(body.range(of: later), later)
            XCTAssertLessThan(refusal.lowerBound, at.lowerBound, later)
        }
        let throwAfter = try XCTUnwrap(body.range(of: "throw EventKitError.occurrenceAddressRefused(reason: refusal)", range: refusal.upperBound..<body.endIndex))
        XCTAssertLessThan(throwAfter.lowerBound, try XCTUnwrap(body.range(of: "if let t = title { event.title = t }")).lowerBound)
    }
}
