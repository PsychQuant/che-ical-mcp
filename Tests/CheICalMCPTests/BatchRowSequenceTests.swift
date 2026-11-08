import EventKit
import XCTest
@testable import CheICalMCP

/// #452: what the earlier rows of one `delete_events_batch` call did to a later row, with span
/// `this` or `future`. The real call (`EventKitManager.deleteEventsBatch`) and the `event_ids` dry
/// run (`previewDeletionRows`) both go through `BatchRowSequence`, so the dry run gives the real
/// call's rows. `FutureDeletionCoverageTests` covers the slot rules underneath.
final class BatchRowSequenceTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// `<series>/RID=<slot>`, the id of an occurrence edited on its own (`UndoPostState.originalSlot`).
    private func rid(_ days: Double, series: String = "S") -> String {
        "\(series)/RID=\(Int(start.addingTimeInterval(days * day).timeIntervalSinceReferenceDate))"
    }

    private func slot(_ days: Double) -> Date { start.addingTimeInterval(days * day) }

    func testNothingIsSkippedBeforeAnyRow() {
        for span in [EKSpan.thisEvent, .futureEvents] {
            let sequence = BatchRowSequence(span: span)
            XCTAssertEqual(sequence.before(identifier: "A", slot: nil), .lookUp)
            XCTAssertEqual(sequence.before(identifier: rid(7), slot: nil), .lookUp)
        }
    }

    /// A repeated id: the real call's second lookup finds nothing (the first row deleted it), so the
    /// row fails, with both spans and for a one-off as for an occurrence's own id.
    func testARepeatedIdIsDeletedEarlier() {
        for span in [EKSpan.thisEvent, .futureEvents] {
            for id in ["A", rid(7)] {
                var sequence = BatchRowSequence(span: span)
                sequence.deletedWhole(identifier: id, requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: nil)
                XCTAssertEqual(sequence.before(identifier: id, slot: nil), .deletedEarlier, "\(span.rawValue) \(id)")
                XCTAssertEqual(sequence.before(identifier: "B", slot: nil), .lookUp)
            }
        }
    }

    /// By date range one id holds several occurrences of a series: deleting one of them is not
    /// deleting the id, so the next occurrence of that id is still looked up with span `this`.
    func testAnOccurrenceOfASeriesIsNotTheWholeId() {
        var sequence = BatchRowSequence(span: .thisEvent)
        sequence.deletedOccurrence(identifier: "S", requested: slot(0), requestedSlot: slot(0), removedStart: slot(0), removedSlot: slot(0))
        XCTAssertEqual(sequence.before(identifier: "S", slot: slot(1)), .lookUp)
    }

    /// By event_ids no occurrence date is passed. A row naming one occurrence by its own id still
    /// removes the series from that slot on with span `future`, so a later occurrence's own id of the
    /// same series is already removed; an earlier one, or another series, is not.
    func testSpanFutureOnAnOccurrenceIdCoversTheLaterOnesOfItsSeries() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(sequence.before(identifier: rid(14), slot: nil), .alreadyRemoved)
        XCTAssertEqual(sequence.before(identifier: rid(0), slot: nil), .lookUp)
        XCTAssertEqual(sequence.before(identifier: rid(14, series: "T"), slot: nil), .lookUp)
    }

    /// Moved: the occurrence's start is not its slot. The coverage is read from the slot in its id.
    func testAMovedOccurrenceCoversFromItsSlot() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(20), removedSlot: nil)
        XCTAssertEqual(sequence.before(identifier: rid(14), slot: nil), .alreadyRemoved)
    }

    func testSpanThisCoversNothingElse() {
        var sequence = BatchRowSequence(span: .thisEvent)
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(sequence.before(identifier: rid(14), slot: nil), .lookUp)
    }

    /// A one-off removed with span future is one event: nothing else is covered.
    func testAOneOffCoversNothing() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: "A", requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: nil)
        XCTAssertEqual(sequence.before(identifier: rid(14, series: "A"), slot: nil), .lookUp)
    }

    /// By date range the requested start is given and checked, as before #452.
    func testByDateRangeTheRequestedStartIsStillChecked() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: rid(7), requested: slot(8), requestedSlot: slot(7), removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(sequence.before(identifier: rid(14), slot: nil), .lookUp, "another start than requested records nothing")
        var listed = BatchRowSequence(span: .futureEvents)
        listed.deletedOccurrence(identifier: "S", requested: slot(7), requestedSlot: slot(7), removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(listed.before(identifier: "S", slot: slot(14)), .alreadyRemoved)
        XCTAssertEqual(listed.before(identifier: "S", slot: slot(0)), .lookUp)
    }

    /// The repeated id is the first answer: an occurrence's own id deleted earlier is reported as the
    /// real lookup reports it, not as covered.
    func testARepeatedOccurrenceIdIsDeletedEarlierEvenWhenCovered() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(sequence.before(identifier: rid(7), slot: nil), .deletedEarlier)
    }

    func testOnlyAnOccurrenceIdWithSpanFutureDeletesLaterOccurrences() {
        XCTAssertTrue(BatchRowSequence.deletesLaterOccurrences(identifier: rid(7), span: .futureEvents))
        XCTAssertFalse(BatchRowSequence.deletesLaterOccurrences(identifier: rid(7), span: .thisEvent))
        XCTAssertFalse(BatchRowSequence.deletesLaterOccurrences(identifier: "A", span: .futureEvents))
    }

    /// The real call goes through the sequence: its batch loop asks it before each row and tells it
    /// after each deletion (an in-memory store cannot run that loop).
    func testTheManagerBatchLoopGoesThroughTheSequence() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func deleteEventsBatch(",
                                                 in: try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(body.contains("BatchRowSequence(span:"), "the loop builds one sequence")
        XCTAssertTrue(body.contains(".before(identifier:"), "each row is asked first")
        XCTAssertTrue(body.contains(".deletedWhole("), "a whole-event deletion is told")
        XCTAssertTrue(body.contains(".deletedOccurrence("), "an occurrence deletion is told")
        XCTAssertTrue(body.contains("batchRowDeletedEarlier"), "a repeated id fails with the shared reason")
        XCTAssertFalse(body.contains("FutureDeletionCoverage("), "the coverage is not kept beside the sequence")
    }
}
