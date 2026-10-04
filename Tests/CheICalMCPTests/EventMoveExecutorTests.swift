import XCTest
@testable import CheICalMCP

/// #226: the order of writes for one move, driven through stub closures (same seam style as
/// `ExclusionExecutorTests`). Invariants: a failed in-place change is reverted before anything
/// else happens, and a refusal never writes.
final class EventMoveExecutorTests: XCTestCase {
    private struct InPlaceFailed: Error {}

    private final class Recorder {
        var calls: [String] = []
    }

    private func input(recurring: Bool = false, span: EventMovePolicy.Span = .this,
                       occurrence: Bool = false, attendees: Int = 0, alreadyInTarget: Bool = false) -> EventMovePolicy.Input {
        .init(isRecurring: recurring, span: span, hasOccurrenceDate: occurrence, attendeeCount: attendees,
              alreadyInTarget: alreadyInTarget)
    }

    private func run(_ input: EventMovePolicy.Input, inPlaceFails: Bool = false, _ rec: Recorder) throws -> EventMoveResult {
        try EventMoveExecutor.run(
            input,
            currentIdentifier: "current-id",
            inPlace: {
                rec.calls.append("inPlace")
                if inPlaceFails { throw InPlaceFailed() }
                return "moved-id"
            },
            restore: { rec.calls.append("restore") },
            copy: { rec.calls.append("copy"); return ("copy-id", ["structured_location"]) },
            split: { rec.calls.append("split"); return ("split-id", []) })
    }

    func testInPlaceSuccessWritesOnce() throws {
        let rec = Recorder()
        let result = try run(input(), rec)
        XCTAssertEqual(result, .init(method: .inPlace, eventIdentifier: "moved-id", notCarriedOver: []))
        XCTAssertEqual(rec.calls, ["inPlace"])
    }

    func testFailedInPlaceIsRevertedThenCopied() throws {
        let rec = Recorder()
        let result = try run(input(), inPlaceFails: true, rec)
        XCTAssertEqual(result, .init(method: .copied, eventIdentifier: "copy-id", notCarriedOver: ["structured_location"]))
        XCTAssertEqual(rec.calls, ["inPlace", "restore", "copy"])
    }

    func testFailedInPlaceWithAttendeesIsRevertedAndRefusedWithoutCopying() {
        let rec = Recorder()
        XCTAssertThrowsError(try run(input(attendees: 1), inPlaceFails: true, rec)) { error in
            guard case EventKitError.moveRefused(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("attendees"))
        }
        XCTAssertEqual(rec.calls, ["inPlace", "restore"])
    }

    func testFailedInPlaceOfASeriesIsRevertedAndRefused() {
        let rec = Recorder()
        XCTAssertThrowsError(try run(input(recurring: true, span: .all), inPlaceFails: true, rec))
        XCTAssertEqual(rec.calls, ["inPlace", "restore"])
    }

    func testOneOccurrenceIsSplitWithoutTryingInPlace() throws {
        let rec = Recorder()
        let result = try run(input(recurring: true, occurrence: true), rec)
        XCTAssertEqual(result.method, .split)
        XCTAssertEqual(result.eventIdentifier, "split-id")
        XCTAssertEqual(rec.calls, ["split"])
    }

    /// Finding 5: a split occurrence is a one-off; say so explicitly.
    func testSplitReportsRecurrenceAsNotCarriedOver() throws {
        let rec = Recorder()
        let result = try run(input(recurring: true, occurrence: true), rec)
        XCTAssertEqual(result.notCarriedOver.first, "recurrence")
    }

    /// Finding 1: an event already in the target calendar touches nothing.
    func testUnchangedWritesNothing() throws {
        let rec = Recorder()
        let result = try run(input(alreadyInTarget: true), rec)
        XCTAssertEqual(result, .init(method: .unchanged, eventIdentifier: "current-id", notCarriedOver: []))
        XCTAssertEqual(rec.calls, [])
    }

    func testRefusalBeforeTheWriteTouchesNothing() {
        let rec = Recorder()
        XCTAssertThrowsError(try run(input(recurring: true), rec)) { error in
            guard case EventKitError.moveRefused = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(rec.calls, [])
    }

    func testRefusalReasonReachesTheResponseUnchanged() {
        let error = EventKitError.moveRefused(reason: "fixed reason")
        XCTAssertEqual(error.errorDescription, "fixed reason")
        XCTAssertEqual(EventKitErrorSanitizer.writeFailureLog(handler: "test", identifier: "x", error: error), "fixed reason")
    }
}
