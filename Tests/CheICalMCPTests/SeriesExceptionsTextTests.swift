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
                       "Deleted event: Standup (undo recreates the series and its exceptions within the checked window (\(UndoOperation.windowRange(window))): \(exceptionsListing))")
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

    /// PR #406 verify r1, 3: one series from its rules keeps the single wording; more say how many.
    func testBatchUndoTextCountsTheSeriesRestoredFromTheirRulesAlone() {
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: 1, events: [.seriesFromRules]),
                       "Undone batch (1 operation). " + UndoOperation.seriesRulesRestoreNote)
        let message = UndoOperation.batchUndoneMessage(count: 3, events: [.seriesFromRules, .seriesFromRules, .seriesFromRules])
        XCTAssertEqual(message, "Undone batch (3 operations). 3 series were restored from their rules alone, because their exceptions were not checked when they were deleted: an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit; undoing the earlier delete of that occurrence afterwards writes nothing when the restored series already holds its slot")
        XCTAssertFalse(message.contains(UndoOperation.seriesRulesRestoreNote), message)
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

    // MARK: - #319: the window by its instants, and a series that reaches past it

    private func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var aroundTheDelete: DateInterval {
        DateInterval(start: iso("2025-11-08T12:00:00Z"), end: iso("2029-11-07T12:00:00Z"))
    }
    private let windowRule = "at most four years, from three years before the delete, or from one day before the first occurrence when that is later, moved earlier for a rule that ends sooner; for a count whose end cannot be shown, also the four years from one day before its first occurrence"

    private func restored(startsBefore: Bool, continuesAfter: Bool) -> String {
        var exceptions = SeriesExceptions(window: aroundTheDelete, keptSlots: [], detached: [])
        exceptions.seriesStartsBeforeWindow = startsBefore
        exceptions.seriesContinuesAfterWindow = continuesAfter
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4).withExceptions(exceptions)
        return UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW", exceptionsOutcome: .init(stayedDeleted: 1, oneOffs: 0))
    }

    func testTheUndoTextNamesTheWindowAndSaysTheSeriesReachesPastIt() {
        let message = restored(startsBefore: true, continuesAfter: true)
        XCTAssertTrue(message.contains("Exceptions outside the checked window (\(UndoOperation.windowRange(aroundTheDelete)); \(windowRule)) are not restored"), message)
        XCTAssertTrue(message.contains("This series has occurrences outside that window, before and after it"), message)
    }

    func testTheUndoTextSaysWhichSideTheSeriesReachesPastTheWindow() {
        XCTAssertTrue(restored(startsBefore: true, continuesAfter: false).contains("This series has occurrences outside that window, before it"))
        XCTAssertTrue(restored(startsBefore: false, continuesAfter: true).contains("This series has occurrences outside that window, after it"))
    }

    func testASeriesInsideTheWindowSaysNothingMore() {
        let message = restored(startsBefore: false, continuesAfter: false)
        XCTAssertFalse(message.contains("This series has occurrences outside that window"), message)
        XCTAssertTrue(message.contains("checked window (\(UndoOperation.windowRange(aroundTheDelete));"), message)
    }

    func testTheHistoryLineNamesTheWindow() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
            .withExceptions(SeriesExceptions(window: aroundTheDelete, keptSlots: [], detached: []))
        XCTAssertEqual(UndoOperation.deleteEvent(snapshot: snapshot).description,
                       "Deleted event: Standup (undo recreates the series and its exceptions within the checked window (\(UndoOperation.windowRange(aroundTheDelete))): \(exceptionsListing))")
    }

    /// The batch note states the window's rule, without days: its members' windows differ.
    func testTheBatchNoteStatesTheWindowRule() {
        let message = UndoOperation.batchUndoneMessage(count: 1, events: [.seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 0))])
        XCTAssertTrue(message.contains("Exceptions outside the checked window (\(windowRule)) are not restored"), message)
        XCTAssertFalse(message.contains("first occurrence to the end of the rule"), message)
    }

    // MARK: - PR #494 round 1

    /// The window is given by its instants (it starts and ends at the time of day of the delete or
    /// of the first occurrence, not at midnight), in the host zone.
    func testTheWindowIsGivenByItsInstants() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let expected = "from \(formatter.string(from: aroundTheDelete.start)) up to \(formatter.string(from: aroundTheDelete.end))"
        XCTAssertEqual(UndoOperation.windowRange(aroundTheDelete), expected)
        XCTAssertTrue(restored(startsBefore: false, continuesAfter: false).contains("checked window (\(expected); "))
    }

    func testTheUndoTextSaysASeriesMayContinueAfterTheWindow() {
        var exceptions = SeriesExceptions(window: aroundTheDelete, keptSlots: [], detached: [])
        exceptions.seriesStartsBeforeWindow = true
        exceptions.seriesMayContinueAfterWindow = true
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4).withExceptions(exceptions)
        let message = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW", exceptionsOutcome: .init(stayedDeleted: 0, oneOffs: 0))
        XCTAssertTrue(message.contains("This series has occurrences before that window and may have occurrences after it"), message)
    }

    /// A batch counts an edited occurrence held by its series with the others, and says its edit
    /// did not come back.
    func testTheBatchTextSaysAHeldEditedOccurrenceLostItsEdit() {
        let message = UndoOperation.batchUndoneMessage(count: 2, events: [.occurrenceAlreadyHeld, .editedOccurrenceAlreadyHeld])
        // Round 2: the held edited occurrence is not counted as "already restored".
        XCTAssertTrue(message.contains("1 deleted occurrence was already restored by its series, so nothing was written for it"), message)
        XCTAssertTrue(message.contains("1 deleted occurrence that had been edited on its own was not written: its restored series already has an occurrence at its slot, which is not the edited one, so its edit did not come back"), message)
        XCTAssertFalse(message.contains("2 deleted occurrences were already restored"), message)
    }

    /// A split move's source held by its series keeps the copy, edited or not.
    func testAMoveByCopyRestoreTreatsAHeldEditedOccurrenceAsHeld() {
        XCTAssertEqual(MoveByCopyUndo.Restore(text: "x", outcome: .editedOccurrenceAlreadyHeld), .editedSlotAlreadyHeld)
    }

    /// Round 2 (LOW): the move-by-copy text of a held slot names the series, not a title match.
    func testTheMoveByCopyHeldSlotTextNamesTheSeries() {
        let message = MoveByCopyUndo.message(restore: .slotAlreadyHeld, title: "Standup", copyID: "C1", copy: .keptSlotHeld)
        XCTAssertFalse(message.contains("with its title"), message)
        XCTAssertFalse(message.contains("another series of the same title"), message)
        XCTAssertTrue(message.contains("its series already holds its original slot there"), message)
    }

    func testTheSplitMoveHistoryLineNamesTheSeries() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup")
        let line = UndoOperation.moveByCopy(original: snapshot, isSplit: true, notCarriedOver: [], copyID: "C1", copy: snapshot).description
        XCTAssertTrue(line.contains("if its series there already holds its original slot, nothing is recreated and the copy stays"), line)
    }

    /// Round 3: the held text does not claim what holds the slot came from the rules (it may be an
    /// occurrence moved there); it says the edit did not come back.
    func testTheEditedHeldTextDoesNotSayTheRulesHoldIt() {
        let text = UndoOperation.occurrenceAlreadyRestoredMessage(title: "Standup", edited: true)
        XCTAssertFalse(text.contains("as its rules give it"), text)
        XCTAssertTrue(text.contains("which is not the edited one, so its edit did not come back"), text)
    }

    /// Round 3: a split move of an occurrence edited on its own whose slot the series holds: the copy
    /// is the only version with the edit, so the text says to keep it, not to remove it.
    func testAHeldEditedSplitSaysTheCopyIsTheOnlyEditedVersion() {
        let message = MoveByCopyUndo.message(restore: .editedSlotAlreadyHeld, title: "Standup", copyID: "C1", copy: .keptSlotHeld)
        XCTAssertTrue(message.contains("the copy the move made (id C1) is the only version with that edit"), message)
        XCTAssertFalse(message.contains("remove the copy there if it should go"), message)
    }

    /// The move-by-copy run keeps the copy for an edited held slot too.
    func testAHeldEditedSplitKeepsTheCopy() async throws {
        let result = try await MoveByCopyUndo.run(copyID: "C1", restoreOriginal: { .editedSlotAlreadyHeld },
                                                  checkAndRemove: { XCTFail("must not check") })
        XCTAssertEqual(result.copy, .keptSlotHeld)
    }

    // MARK: - PR #494 round 4: two windows

    private var fromTheFirst: DateInterval {
        DateInterval(start: iso("2019-03-01T12:00:00Z"), end: iso("2023-02-28T12:00:00Z"))
    }

    func testTheUndoTextNamesBothWindows() {
        var exceptions = SeriesExceptions(window: aroundTheDelete, keptSlots: [], detached: [], extraWindows: [fromTheFirst])
        exceptions.seriesMayContinueAfterWindow = true
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4).withExceptions(exceptions)
        let message = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: "NEW", exceptionsOutcome: .init(stayedDeleted: 1, oneOffs: 0))
        let both = "\(UndoOperation.windowRange(aroundTheDelete)), and \(UndoOperation.windowRange(fromTheFirst))"
        XCTAssertTrue(message.contains("inside the checked windows: "), message)
        XCTAssertTrue(message.contains("Exceptions outside the checked windows (\(both); \(windowRule)) are not restored"), message)
        XCTAssertTrue(message.contains("This series may have occurrences outside those windows"), message)
    }

    func testTheHistoryLineNamesBothWindows() {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
            .withExceptions(SeriesExceptions(window: aroundTheDelete, keptSlots: [], detached: [], extraWindows: [fromTheFirst]))
        let both = "\(UndoOperation.windowRange(aroundTheDelete)), and \(UndoOperation.windowRange(fromTheFirst))"
        XCTAssertEqual(UndoOperation.deleteEvent(snapshot: snapshot).description,
                       "Deleted event: Standup (undo recreates the series and its exceptions within the checked windows (\(both)): \(exceptionsListing))")
    }
}
