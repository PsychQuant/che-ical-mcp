import XCTest
@testable import CheICalMCP

/// #466: the undo of a move that split an occurrence out or fell back to copy and delete. It is its
/// own record kind (`UndoOperation.moveByCopy`), not a batch: the original is always restored as a
/// delete-undo restores it, and the copy is removed only when it is found under its recorded
/// identifier and unchanged; otherwise it stays and the answer says so. Pure: the order runs through
/// closure seams (`MoveByCopyUndo.run`), the texts and the classification are values.
final class MoveByCopyUndoTests: XCTestCase {
    private static let originalFixture = UndoSnapshotFixtures.event(title: "Standup")
    private static let copyFixture = UndoSnapshotFixtures.event(title: "Standup")
    private var original: EventSnapshot { Self.originalFixture }
    private var copy: EventSnapshot { Self.copyFixture }
    private var record: UndoOperation { .moveByCopy(original: original, copyID: "COPY-1", copy: copy) }

    enum Failure: Error { case restore, remove, lookup }
    private let restored = "Undone: restored event 'Standup' (new ID: NEW-1)"

    private func run(copyID: String = "COPY-1", restore: @escaping () throws -> String,
                     check: @escaping () throws -> String = { "copy" },
                     remove: @escaping (String) throws -> Void = { _ in }) async throws -> (calls: [String], result: (restored: String, copy: MoveByCopyUndo.Copy)) {
        var calls: [String] = []
        let result = try await MoveByCopyUndo.run(
            copyID: copyID,
            restoreOriginal: { calls.append("restore"); return try restore() },
            checkCopy: { calls.append("check"); return try check() },
            removeCopy: { calls.append("remove"); try remove($0) },
            describeRemovalFailure: { _ in "error_code_1" })
        return (calls, result)
    }

    // MARK: - order

    /// The original comes back first; only then is the copy checked and removed, so a failure in
    /// between leaves the event twice, never in neither calendar.
    func testTheOriginalIsRestoredBeforeTheCopyIsCheckedAndRemoved() async throws {
        let outcome = try await run(restore: { self.restored })
        XCTAssertEqual(outcome.calls, ["restore", "check", "remove"])
        XCTAssertEqual(outcome.result.restored, restored)
        XCTAssertEqual(outcome.result.copy, .removed)
    }

    /// A failed restore throws as a delete-undo does (the record is kept or dropped by its error),
    /// and the copy is not touched.
    func testAFailedRestoreThrowsAndLeavesTheCopyAlone() async {
        do {
            _ = try await run(restore: { throw Failure.restore }, check: { XCTFail("must not check"); return "" },
                              remove: { _ in XCTFail("must not remove") })
            XCTFail("expected the restore error")
        } catch {
            XCTAssertEqual(error as? Failure, .restore)
        }
    }

    /// Verify round 1 (both MEDIUM findings): a copy changed since the move used to refuse the
    /// whole undo, original included. Now the original comes back and the copy stays.
    func testAChangedCopyStaysAndTheOriginalStillComesBack() async throws {
        let outcome = try await run(restore: { self.restored }, check: {
            throw UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup", changedFields: ["alarms", "timezone"])
        }, remove: { _ in XCTFail("must not remove a changed copy") })
        XCTAssertEqual(outcome.calls, ["restore", "check"])
        XCTAssertEqual(outcome.result.copy, .changed(["alarms", "timezone"]))
    }

    /// A copy deleted elsewhere, or given a new identifier by its account: the original still comes back.
    func testAMissingCopyLeavesNothingToRemoveAndTheOriginalStillComesBack() async throws {
        let outcome = try await run(restore: { self.restored }, check: {
            throw UndoTargetMissingError(verb: .undo, kind: .event, title: "Standup", hasIdentifier: true)
        })
        XCTAssertEqual(outcome.calls, ["restore", "check"])
        XCTAssertEqual(outcome.result.copy, .notFound)
    }

    /// Any other failure of the check (a lookup that raised, #288, an access gate) leaves the copy
    /// as unchecked: never removed, never a reason to refuse the original.
    func testAnyOtherCheckFailureLeavesTheCopyUnchecked() async throws {
        let outcome = try await run(restore: { self.restored }, check: { throw Failure.lookup })
        XCTAssertEqual(outcome.result.copy, .unchecked)
        XCTAssertEqual(MoveByCopyUndo.copyState(afterCheckFailure: EventKitError.historyLookupFailed(verb: .undo)), .unchecked)
        XCTAssertEqual(MoveByCopyUndo.copyState(afterCheckFailure: UnrecoverableUndoError(message: "x")), .unchecked)
    }

    /// Round 1 LOW: a copy recorded without an identifier made the whole undo impossible. It is
    /// not looked up now; the original comes back and the answer says the copy was not removed.
    func testACopyWithoutAnIdentifierIsNotLookedUp() async throws {
        let outcome = try await run(copyID: "", restore: { self.restored }, check: { XCTFail("must not check"); return "" })
        XCTAssertEqual(outcome.calls, ["restore"])
        XCTAssertEqual(outcome.result.copy, .noIdentifier)
    }

    /// A removal that fails after the original is back is answered, not thrown: a thrown error
    /// would put the record back, and the next undo would restore the original a second time.
    func testAFailedRemovalIsReportedAfterTheRestoreNotThrown() async throws {
        let outcome = try await run(restore: { self.restored }, remove: { _ in throw Failure.remove })
        XCTAssertEqual(outcome.calls, ["restore", "check", "remove"])
        XCTAssertEqual(outcome.result.copy, .removalFailed("error_code_1"))
    }

    // MARK: - texts

    func testTheAnswerSaysWhatBecameOfTheCopy() {
        let removed = MoveByCopyUndo.message(restored: restored, copyID: "COPY-1", copy: .removed)
        XCTAssertTrue(removed.hasPrefix(restored), removed)
        XCTAssertTrue(removed.contains("removed the copy the move made in the calendar it was moved to"), removed)
        XCTAssertFalse(removed.contains("both calendars"), removed)

        let left: [MoveByCopyUndo.Copy] = [.noIdentifier, .notFound, .changed(["title"]), .unchecked, .removalFailed("error_code_1")]
        for state in left {
            let text = MoveByCopyUndo.message(restored: restored, copyID: "COPY-1", copy: state)
            XCTAssertTrue(text.hasPrefix(restored), "the original's restore and its new ID come first: \(text)")
            XCTAssertTrue(text.contains("both calendars"), text)
            XCTAssertTrue(text.contains("running undo again undoes the operation before it"), text)
            XCTAssertFalse(text.contains("second copy"), "nothing a retry does can add a copy: \(text)")
            XCTAssertFalse(text.contains("discard_id"), "the entry is used up, nothing to give up: \(text)")
            XCTAssertFalse(text.contains("delete_event"), "removing the copy is the user's call, no tool named: \(text)")
        }
        let changed = MoveByCopyUndo.message(restored: restored, copyID: "COPY-1", copy: .changed(["title", "alarms"]))
        XCTAssertTrue(changed.contains("was changed after the move (title, alarms)") && changed.contains("COPY-1"), changed)
        let missing = MoveByCopyUndo.message(restored: restored, copyID: "COPY-1", copy: .notFound)
        XCTAssertTrue(missing.contains("was not found under its recorded identifier"), missing)
        let noID = MoveByCopyUndo.message(restored: restored, copyID: "", copy: .noIdentifier)
        XCTAssertTrue(noID.contains("did not record the copy's identifier"), noID)
        let failed = MoveByCopyUndo.message(restored: restored, copyID: "COPY-1", copy: .removalFailed("error_code_1"))
        XCTAssertTrue(failed.contains("removing the copy the move made failed (error_code_1)"), failed)
    }

    /// Round 1 LOW: the listing read `Batch (2 operations)`, which the refusal's way on could not
    /// tell apart from another batch.
    func testTheListingNamesTheMoveAndItsTitle() {
        XCTAssertEqual(record.description,
                       "Moved event: Standup (by copy: undo restores it in its original calendar and removes the copy if unchanged)")
    }

    /// Round 1 LOW: redo answered the generic batch line, which points at create_event and
    /// delete_event. It names move_events_batch, and that a copy left by the undo would be doubled.
    func testRedoWritesNothingAndNamesMoveEventsBatch() throws {
        XCTAssertFalse(record.redoWrites)
        let text = try XCTUnwrap(record.redoInstruction)
        XCTAssertTrue(text.hasPrefix("Cannot redo the move of event 'Standup': redo does not move events again. Use move_events_batch to move it again."), text)
        XCTAssertTrue(text.contains("If the undo left the copy in the calendar it was moved to, moving the event again adds a second one there: check that calendar first."), text)
        XCTAssertTrue(text.hasSuffix(" Nothing was written."), text)
        XCTAssertFalse(text.contains("COPY-1"), text)
    }

    // MARK: - classification

    /// Every exhaustive switch over `UndoOperation` classifies the new kind on purpose.
    func testTheNewKindIsClassifiedLikeTheDeleteOfTheOriginalWhereItRestoresIt() throws {
        guard case .eventCalendar(let destination)? = record.restoreDestination(verb: .undo) else {
            return XCTFail("the original is recreated in its recorded calendar")
        }
        XCTAssertEqual(destination.calendarIdentifier, original.calendarIdentifier)
        XCTAssertNil(record.restoreDestination(verb: .redo))
        XCTAssertEqual(record.restoredItemTitle, "Standup")
        XCTAssertEqual(record.restoredItemWhen, UndoOperation.deleteEvent(snapshot: original).restoredItemWhen)
        XCTAssertFalse(record.mayRunLastAfterAFailure, "it writes to an existing item (the copy); no batch records it")
        XCTAssertNil(record.undoPostState, "the original is recreated; the copy is checked inside the arm")
        XCTAssertNil(record.redoPostState)
        XCTAssertNil(record.batchMemberUndoRefusal)
        XCTAssertFalse(record.resolvesThroughStandIn)
        XCTAssertNil(record.moveBackCalendarMissing)
        XCTAssertNil(record.recurringTargetRefusal(hasRecurrenceRules: true, isDetached: true))
        XCTAssertEqual(record.seriesRecreatedFromRules, 0)
        XCTAssertNil(record.completionWrite(undo: true, now: Date()))
    }
}
