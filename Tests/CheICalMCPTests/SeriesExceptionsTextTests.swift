import XCTest
@testable import CheICalMCP

/// #285: what undo, `undo_history` and a batch undo say about a series restored with its
/// exceptions, and about an occurrence whose slot the series already holds.
final class SeriesExceptionsTextTests: XCTestCase {
    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000 - 86_400),
                                      end: Date(timeIntervalSince1970: 1_800_000_000 + 30 * 86_400))

    private func series(_ title: String = "Standup", withExceptions: Bool) -> UndoOperation {
        let snapshot = UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 4)
        return .deleteEvent(snapshot: withExceptions
                            ? snapshot.withExceptions(SeriesExceptions(window: window, keptSlots: [], detached: []))
                            : snapshot)
    }

    private let exceptionsListing = "occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events"
    private let rulesListing = "occurrences deleted on their own earlier come back, edited ones without their edits"

    // MARK: - undo_history

    func testSingleRecordWithExceptionsIsListedAsRestoringThem() {
        XCTAssertEqual(series(withExceptions: true).description,
                       "Deleted event: Standup (undo recreates the series and its exceptions within the checked window: \(exceptionsListing))")
    }

    func testSingleRecordWithoutExceptionsKeepsItsListing() {
        XCTAssertEqual(series(withExceptions: false).description,
                       "Deleted event: Standup (undo recreates the series from its rules: \(rulesListing))")
    }

    func testBatchOfSeriesWithExceptionsSaysSo() {
        let batch = UndoOperation.batch([series("A", withExceptions: true), series("B", withExceptions: true)])
        XCTAssertEqual(batch.description,
                       "Batch (2 operations; undo recreates 2 series and their exceptions within the checked window: \(exceptionsListing))")
    }

    func testBatchWithOneSeriesWithExceptionsUsesTheSingularForm() {
        XCTAssertEqual(UndoOperation.batch([series(withExceptions: true)]).description,
                       "Batch (1 operation; undo recreates 1 series and its exceptions within the checked window: \(exceptionsListing))")
    }

    func testMixedBatchSaysBoth() {
        let batch = UndoOperation.batch([series("A", withExceptions: true), series("B", withExceptions: false)])
        XCTAssertEqual(batch.description,
                       "Batch (2 operations; undo recreates 1 series from its rules: \(rulesListing); undo recreates 1 series and its exceptions within the checked window: \(exceptionsListing))")
    }

    // MARK: - undo text

    func testUndoTextNamesTheCounts() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
        let message = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW",
                                                         exceptionsOutcome: .init(stayedDeleted: 2, oneOffs: 1))
        XCTAssertTrue(message.hasPrefix("Undone: restored event 'Standup' (new ID: NEW). Restored from the series rules with its exceptions inside the checked window: "), message)
        XCTAssertTrue(message.contains("2 occurrence(s) deleted on their own earlier stayed deleted"), message)
        XCTAssertTrue(message.contains("1 occurrence(s) edited on their own came back as separate one-off events that no longer belong to the series"), message)
        XCTAssertTrue(message.contains("Exceptions outside the checked window"), message)
    }

    func testUndoTextWithoutOutcomeKeepsTheRulesNote() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
        XCTAssertTrue(UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW").hasSuffix(UndoOperation.seriesRulesRestoreNote))
    }

    func testBatchUndoTextNamesTheExceptionsRestoreOnce() {
        let message = UndoOperation.batchUndoneMessage(members: [series("A", withExceptions: true), series("B", withExceptions: true)], count: 2)
        XCTAssertEqual(message.components(separatedBy: "inside the checked window").count - 1, 1, message)
        XCTAssertFalse(message.contains(UndoOperation.seriesRulesRestoreNote), message)
    }

    func testBatchUndoTextOfAMixedBatchNamesBothNotes() {
        let message = UndoOperation.batchUndoneMessage(members: [series("A", withExceptions: true), series("B", withExceptions: false)], count: 2)
        XCTAssertTrue(message.contains(UndoOperation.seriesRulesRestoreNote), message)
        XCTAssertTrue(message.contains("inside the checked window"), message)
    }

    func testAlreadyRestoredOccurrenceSaysNothingWasWritten() {
        XCTAssertEqual(UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup"),
                       "Undone: the deleted occurrence of 'Standup' is already restored by its series, so nothing was written (a one-off event beside it would have been a duplicate)")
    }
    func testUndoTextSaysWhenTheFirstOccurrenceWasKeptFromTheRule() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
        let message = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW",
                                                         exceptionsOutcome: .init(stayedDeleted: 0, oneOffs: 0, firstOccurrenceKeptFromRule: true))
        XCTAssertTrue(message.contains("first occurrence"), message)
        XCTAssertTrue(message.contains("not restored as an exception"), message)
    }

    func testUndoTextStatesAnEditedOccurrenceMovedBeyondTheListedRangeIsNotRestored() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
        let message = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW",
                                                         exceptionsOutcome: .init(stayedDeleted: 1, oneOffs: 0))
        XCTAssertTrue(message.contains("moved far outside"), message)
    }
}
