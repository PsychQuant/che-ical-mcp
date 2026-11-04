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

    private let exceptionsListing = "occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events; not for a first occurrence edited or deleted on its own, one moved more than a year outside the window, or a record that does not match the recreated series"
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

    /// #323: the batch text names the exceptions restore once, with the totals of what the
    /// members returned.
    func testBatchUndoTextNamesTheExceptionsRestoreOnceWithTotals() {
        let message = UndoOperation.batchUndoneMessage(count: 2, events: [
            .seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 0)),
            .seriesWithExceptions(.init(stayedDeleted: 2, oneOffs: 1, firstOccurrenceKeptFromRule: true)),
        ])
        XCTAssertEqual(message.components(separatedBy: "inside the checked window").count - 1, 1, message)
        XCTAssertTrue(message.contains("2 series were restored from their rules with their exceptions inside the checked window: 3 occurrence(s) deleted on their own earlier stayed deleted, 1 occurrence(s) edited on their own came back"), message)
        XCTAssertTrue(message.contains("In 1 of them the first occurrence"), message)
        XCTAssertFalse(message.contains(UndoOperation.seriesRulesRestoreNote), message)
    }

    func testBatchUndoTextOfAMixedBatchNamesBothNotes() {
        let message = UndoOperation.batchUndoneMessage(count: 2, events: [.seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0)), .seriesFromRules])
        XCTAssertTrue(message.contains(UndoOperation.seriesRulesRestoreNote), message)
        XCTAssertTrue(message.contains("1 series was restored from its rules with its exceptions inside the checked window"), message)
    }

    func testBatchUndoTextSaysWhichSeriesHadNoExceptionApplied() {
        let message = UndoOperation.batchUndoneMessage(count: 2, events: [
            .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true)),
            .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true)),
        ])
        XCTAssertEqual(message, "Undone batch (2 operations). 2 series were restored from their rules alone: their recorded exceptions did not match the occurrences of the recreated series, so none was applied (an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit)")
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
        XCTAssertTrue(message.contains("more than a year"), message)
    }
    func testUndoTextSaysWhenTheRecordedExceptionsDidNotMatchTheRecreatedSeries() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
        let message = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW",
                                                         exceptionsOutcome: .init(stayedDeleted: 0, oneOffs: 0, notApplied: true))
        XCTAssertTrue(message.contains("did not match"), message)
        XCTAssertTrue(message.contains("none was applied"), message)
        XCTAssertFalse(message.contains("stayed deleted"), message)
    }

    func testBatchNoteStatesTheWindowLimitAndNoLongerSaysItCannotKnow() {
        // #323: built from the members' outcomes, so it says what happened (PR #318 verify round 2
        // had it built before them, with "Per series this text cannot say").
        let note = UndoOperation.seriesExceptionsBatchNote([.init(stayedDeleted: 0, oneOffs: 0)])
        XCTAssertTrue(note.contains("more than a year"), note)
        XCTAssertFalse(note.contains("cannot say"), note)
        XCTAssertFalse(note.contains("first occurrence was edited"), "only when a member kept it: \(note)")
    }
}
