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
        XCTAssertTrue(call.contains("identifier: first.id,"), call)
        // verify r7: the #451 checks on a started series hold only with the call's span and applyToAll.
        XCTAssertTrue(call.contains("span: span,"), call)
        XCTAssertTrue(call.contains("applyToAll: applyToAll,"), call)
        let after = String(body[inner.upperBound...].prefix(900))
        XCTAssertTrue(after.contains("} catch EventKitError.seriesWriteRefused {"), after)
        XCTAssertTrue(after.contains("DetachedOccurrenceSpan.throughSeriesIDStartedRule(allEdited: first.allEdited)"), after)
    }

    /// In the inner call, on the occurrence's own id, #416's refusal and #451's checks for a started
    /// series (`SeriesRuleWrite`: later occurrence, start, started rule) all come before the snapshot,
    /// the first field assignment, the date assignment and the save. The series-id route relies on
    /// them for a started series (measured after #471, 2026-11-08).
    func testTheRefusalsRunBeforeTheFirstAssignmentAndTheSave() throws {
        let body = try updateEventBody()
        let checks = ["if let refusal = try DetachedOccurrenceSpan.updateRefusal(", "SeriesRuleWrite.laterOccurrenceRefusal(",
                      "SeriesRuleWrite.startRefusal(", "SeriesRuleWrite.startedRuleRefusal("]
        let writes = ["if let t = title { event.title = t }", "event.startDate = dates.start", "try eventStore.save("]
        for check in checks {
            let at = try XCTUnwrap(body.range(of: check), check)
            for write in writes {
                XCTAssertLessThan(at.lowerBound, try XCTUnwrap(body.range(of: write), write).lowerBound, "\(check) before \(write)")
            }
        }
        let refusal = try XCTUnwrap(body.range(of: checks[0]))
        XCTAssertLessThan(refusal.lowerBound, try XCTUnwrap(body.range(of: "let oldSnapshot = EventSnapshot(from: masterEvent)")).lowerBound)
    }
}
