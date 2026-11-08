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
    private let notFound = "Event not found"

    /// `<series>/RID=<slot>`, the id of an occurrence edited on its own (`UndoPostState.originalSlot`).
    private func rid(_ days: Double, series: String = "S") -> String {
        "\(series)/RID=\(Int(start.addingTimeInterval(days * day).timeIntervalSinceReferenceDate))"
    }

    private func slot(_ days: Double) -> Date { start.addingTimeInterval(days * day) }

    /// By event_ids: the occurrence at day 7 cut with span future, its id and the one at day 21
    /// resolving before the call.
    private func cutAtSeven(resolving ids: [String]) -> BatchRowSequence {
        var sequence = BatchRowSequence(span: .futureEvents)
        for id in ids { sequence.resolvedBeforeTheCall(id, hasRecurrenceRules: false) }
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        return sequence
    }

    func testNothingIsSkippedBeforeAnyRow() {
        for span in [EKSpan.thisEvent, .futureEvents] {
            var sequence = BatchRowSequence(span: span)
            XCTAssertEqual(sequence.before(identifier: "A", listed: nil, slot: nil), .lookUp)
            XCTAssertEqual(sequence.before(identifier: rid(7), listed: nil, slot: nil), .lookUp)
        }
    }

    /// A repeated id: the real call's second lookup finds nothing (the first row deleted it), so the
    /// row fails, with both spans and for a one-off as for an occurrence's own id.
    func testARepeatedIdIsDeletedEarlier() {
        for span in [EKSpan.thisEvent, .futureEvents] {
            for id in ["A", rid(7)] {
                var sequence = BatchRowSequence(span: span)
                sequence.deletedWhole(identifier: id, requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: nil)
                XCTAssertEqual(sequence.before(identifier: id, listed: nil, slot: nil),
                               .failed(EventKitManager.batchRowDeletedEarlier), "\(span.rawValue) \(id)")
                XCTAssertEqual(sequence.before(identifier: "B", listed: nil, slot: nil), .lookUp)
            }
        }
    }

    /// By date range one id holds several occurrences of a series: deleting one of them is not
    /// deleting the id, so the next occurrence of that id is still looked up with span `this`.
    func testAnOccurrenceOfASeriesIsNotTheWholeId() {
        var sequence = BatchRowSequence(span: .thisEvent)
        sequence.deletedOccurrence(identifier: "S", requested: slot(0), requestedSlot: slot(0), removedStart: slot(0), removedSlot: slot(0))
        XCTAssertEqual(sequence.before(identifier: "S", listed: slot(1), slot: slot(1)), .lookUp)
    }

    /// Review r1 item 1: by event_ids a covered row is looked up first. Only when the lookup finds
    /// nothing, and the id resolved before the call, is it counted as already removed.
    func testByEventIdsACoveredRowIsLookedUpFirst() {
        var sequence = cutAtSeven(resolving: [rid(7), rid(21)])
        XCTAssertEqual(sequence.before(identifier: rid(21), listed: nil, slot: nil), .lookUp, "covered, still looked up")
        XCTAssertTrue(sequence.removedByAnEarlierRow(identifier: rid(21)))
        XCTAssertEqual(sequence.notFound(identifier: rid(21), listed: nil, reason: { self.notFound }), .alreadyRemoved)
    }

    /// An earlier occurrence, another series, or span this: not covered, so not found is a failure.
    func testANotFoundRowOutsideTheCutFails() {
        var sequence = cutAtSeven(resolving: [rid(7), rid(0), rid(21, series: "T")])
        for id in [rid(0), rid(21, series: "T")] {
            XCTAssertFalse(sequence.removedByAnEarlierRow(identifier: id), id)
            XCTAssertEqual(sequence.notFound(identifier: id, listed: nil, reason: { self.notFound }), .failed(notFound), id)
        }
        var this = BatchRowSequence(span: .thisEvent)
        this.resolvedBeforeTheCall(rid(21), hasRecurrenceRules: false)
        this.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(this.notFound(identifier: rid(21), listed: nil, reason: { self.notFound }), .failed(notFound))
    }

    /// Review r1 item 2: a covered id that did not resolve before the call (stale, mistyped) was not
    /// removed by this call: it fails as not found.
    func testACoveredIdThatNeverResolvedFails() {
        var sequence = cutAtSeven(resolving: [rid(7)])
        XCTAssertEqual(sequence.notFound(identifier: rid(21), listed: nil, reason: { self.notFound }), .failed(notFound))
    }

    /// Review r1 item 2: `[S/RID=7, S/RID=21, S/RID=21]` counts the one occurrence once; the repeat
    /// is answered as a row deleted earlier.
    func testACoveredIdIsCountedOnce() {
        var sequence = cutAtSeven(resolving: [rid(7), rid(21)])
        XCTAssertEqual(sequence.notFound(identifier: rid(21), listed: nil, reason: { self.notFound }), .alreadyRemoved)
        XCTAssertEqual(sequence.before(identifier: rid(21), listed: nil, slot: nil), .failed(EventKitManager.batchRowDeletedEarlier))
    }

    /// Moved: the occurrence's start is not its slot. The coverage is read from the slot in its id.
    func testAMovedOccurrenceCoversFromItsSlot() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.resolvedBeforeTheCall(rid(14), hasRecurrenceRules: false)
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(20), removedSlot: nil)
        XCTAssertTrue(sequence.removedByAnEarlierRow(identifier: rid(14)))
    }

    /// A one-off removed with span future is one event: nothing else is covered.
    func testAOneOffCoversNothing() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: "A", requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: nil)
        XCTAssertFalse(sequence.removedByAnEarlierRow(identifier: rid(14, series: "A")))
    }

    /// By date range the rows come from a listing: a covered listed row is skipped before any
    /// lookup, as before #452, and the requested start is still checked. A listed series id is not
    /// remembered, as its other occurrences follow under the same id.
    func testByDateRangeACoveredRowIsSkippedBeforeTheLookup() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.deletedWhole(identifier: rid(7), requested: slot(8), requestedSlot: slot(7), removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(sequence.before(identifier: rid(14), listed: slot(14), slot: slot(14)), .lookUp,
                       "another start than requested records nothing")
        var listed = BatchRowSequence(span: .futureEvents)
        listed.deletedOccurrence(identifier: "S", requested: slot(7), requestedSlot: slot(7), removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(listed.before(identifier: "S", listed: slot(14), slot: slot(14)), .alreadyRemoved)
        XCTAssertEqual(listed.before(identifier: "S", listed: slot(21), slot: slot(21)), .alreadyRemoved)
        XCTAssertEqual(listed.before(identifier: "S", listed: slot(0), slot: slot(0)), .lookUp)
    }

    /// The repeated id is the first answer: an occurrence's own id deleted earlier is reported as the
    /// real lookup reports it, not as covered.
    func testARepeatedOccurrenceIdIsDeletedEarlierEvenWhenCovered() {
        var sequence = cutAtSeven(resolving: [rid(7)])
        XCTAssertEqual(sequence.before(identifier: rid(7), listed: nil, slot: nil), .failed(EventKitManager.batchRowDeletedEarlier))
    }

    func testOnlyAnOccurrenceIdWithSpanFutureDeletesLaterOccurrences() {
        XCTAssertTrue(BatchRowSequence.deletesLaterOccurrences(identifier: rid(7), span: .futureEvents))
        XCTAssertFalse(BatchRowSequence.deletesLaterOccurrences(identifier: rid(7), span: .thisEvent))
        XCTAssertFalse(BatchRowSequence.deletesLaterOccurrences(identifier: "A", span: .futureEvents))
    }

    /// Review r1 item 5: the one switch over an answer, which the manager's loop and the test model
    /// both call. Each arm lands in its own counter.
    func testSettleCountsEachAnswerInItsOwnPlace() {
        var failures: [(String, String)] = []
        var covered = 0
        XCTAssertFalse(BatchRowSequence.settle(.lookUp, identifier: "A", failures: &failures, coveredCount: &covered))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(covered, 0)
        XCTAssertTrue(BatchRowSequence.settle(.failed("why"), identifier: "B", failures: &failures, coveredCount: &covered))
        XCTAssertEqual(failures.map(\.0), ["B"])
        XCTAssertEqual(failures.map(\.1), ["why"])
        XCTAssertEqual(covered, 0)
        XCTAssertTrue(BatchRowSequence.settle(.alreadyRemoved, identifier: "C", failures: &failures, coveredCount: &covered))
        XCTAssertEqual(failures.count, 1, "an already removed row is not a failure")
        XCTAssertEqual(covered, 1)
    }

    /// The real call goes through the sequence: its batch loop asks it before each row and after a
    /// lookup that found nothing, settles both answers through `settle`, and tells it after each
    /// deletion (an in-memory store cannot run that loop). It does not switch over an answer itself.
    func testTheManagerBatchLoopGoesThroughTheSequence() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func deleteEventsBatch(",
                                                 in: try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(body.contains("BatchRowSequence(span:"), "the loop builds one sequence")
        XCTAssertTrue(body.contains(".resolvedBeforeTheCall(item.identifier, hasRecurrenceRules:"),
                      "the ids that resolve before the call are noted, with whether they have rules (r2 LOW 1)")
        XCTAssertEqual(SourcePins.ranges(of: "BatchRowSequence.settle(", in: body).count, 2, "both answers are settled by the helper")
        XCTAssertTrue(body.contains(".before(identifier:"), "each row is asked first")
        XCTAssertTrue(body.contains(".notFound(identifier:"), "a row not found is asked again")
        XCTAssertTrue(body.contains(".deletedWhole("), "a whole-event deletion is told")
        XCTAssertTrue(body.contains(".deletedOccurrence("), "an occurrence deletion is told")
        XCTAssertFalse(body.contains("case .alreadyRemoved") || body.contains("case .failed"), "no switch of its own")
        XCTAssertFalse(body.contains("FutureDeletionCoverage("), "the coverage is not kept beside the sequence")
        XCTAssertTrue(body.contains("followingOccurrencesDeleted.append("), "the rows whose undo refuses the batch are reported")
        // Review r3 item 5: the first pass runs before the row loop.
        let firstPass = try XCTUnwrap(body.range(of: ".resolvedBeforeTheCall("), "first pass")
        let rowLoop = try XCTUnwrap(body.range(of: "for (index, item) in items.enumerated()"), "row loop")
        XCTAssertLessThan(firstPass.lowerBound, rowLoop.lowerBound, "the ids that resolve are noted before any row runs")
    }

    /// Review r2 LOW 1: an occurrence's own id that resolves to an event with rules is not a row the
    /// call deletes whole (it is refused for want of a date), so a later miss is not counted.
    func testAnIdThatResolvesWithRulesIsNotCountedAfterACut() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.resolvedBeforeTheCall(rid(21), hasRecurrenceRules: true)
        sequence.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        XCTAssertEqual(sequence.notFound(identifier: rid(21), listed: nil, reason: { self.notFound }), .failed(notFound))
    }

    /// Review r2 MEDIUM: the dry run marks a covered row that resolves as covered, without saying
    /// what the store will do with it; a repeat of it then fails as a row deleted earlier, as in the
    /// real call (where it is either counted or deleted).
    func testTheDryRunMarksACoveredRowWithoutCountingIt() {
        var sequence = cutAtSeven(resolving: [rid(7), rid(21)])
        XCTAssertTrue(sequence.coveredInTheDryRun(identifier: rid(21)))
        XCTAssertEqual(sequence.before(identifier: rid(21), listed: nil, slot: nil), .failed(EventKitManager.batchRowDeletedEarlier))
        XCTAssertFalse(sequence.coveredInTheDryRun(identifier: rid(0)), "an earlier slot is not covered")
        var rules = BatchRowSequence(span: .futureEvents)
        rules.resolvedBeforeTheCall(rid(21), hasRecurrenceRules: true)
        rules.deletedWhole(identifier: rid(7), requested: nil, requestedSlot: nil, removedStart: slot(7), removedSlot: slot(7))
        XCTAssertFalse(rules.coveredInTheDryRun(identifier: rid(21)))
    }

    /// Review r2 LOW 5: a row named by id (no listed date) is never answered as already removed
    /// before its lookup, so the dry run maps only the failure.
    func testARowNamedByIdIsNeverAlreadyRemovedBeforeItsLookup() {
        var sequence = cutAtSeven(resolving: [rid(7), rid(14), rid(21)])
        for id in [rid(14), rid(21), rid(0)] {
            XCTAssertEqual(sequence.before(identifier: id, listed: nil, slot: nil), .lookUp, id)
        }
    }

    /// Review r3 item 4: a `/RID=` slot before 2001 is a negative number, which
    /// `UndoPostState.originalSlot` does not parse (`UndoRefusalTests` keeps it malformed). Such a cut
    /// then covers nothing: a later row of that series is looked up, and when it is gone it fails as
    /// not found instead of being counted.
    func testAPre2001SlotIsNotParsedSoTheCutCoversNothing() {
        var sequence = BatchRowSequence(span: .futureEvents)
        sequence.resolvedBeforeTheCall("S/RID=-500", hasRecurrenceRules: false)
        sequence.deletedWhole(identifier: "S/RID=-1000", requested: nil, requestedSlot: nil,
                              removedStart: Date(timeIntervalSinceReferenceDate: -1000), removedSlot: nil)
        XCTAssertFalse(sequence.removedByAnEarlierRow(identifier: "S/RID=-500"))
        XCTAssertEqual(sequence.notFound(identifier: "S/RID=-500", listed: nil, reason: { self.notFound }), .failed(notFound))
    }
}
