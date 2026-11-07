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
    /// A fallback copy of a one-off event.
    private var record: UndoOperation {
        .moveByCopy(original: original, isSplit: false, notCarriedOver: [], copyID: "COPY-1", copy: copy)
    }
    /// One occurrence split out of a series (PR #474 round 2, LOW 2).
    private var split: UndoOperation {
        .moveByCopy(original: original, isSplit: true, notCarriedOver: ["absolute_alarms"], copyID: "COPY-1", copy: copy)
    }

    enum Failure: Error { case restore, remove, lookup }
    private let restored = "Undone: restored event 'Standup' (new ID: NEW-1)"

    private func run(copyID: String = "COPY-1", restore: @escaping () throws -> String,
                     held: Bool = false,
                     check: @escaping () throws -> String = { "copy" },
                     remove: @escaping (String) throws -> Void = { _ in }) async throws
        -> (calls: [String], result: (restore: MoveByCopyUndo.Restore, copy: MoveByCopyUndo.Copy)) {
        var calls: [String] = []
        let result = try await MoveByCopyUndo.run(
            copyID: copyID,
            restoreOriginal: {
                calls.append("restore")
                let text = try restore()
                return held ? .slotAlreadyHeld : .written(text)
            },
            checkAndRemove: {
                calls.append("check")
                let item = try check()
                try MoveByCopyUndo.removing({ calls.append("remove"); try remove(item) }, describe: { _ in "error_code_1" })
            })
        return (calls, result)
    }

    // MARK: - isolation (PR #474 round 2, MEDIUM)

    /// Round 2: `run` is a nonisolated async function, so a synchronous removal closure it called
    /// after awaiting the check ran off the actor, and the actor was released between the #236 check
    /// and the removal. The check and the removal now run in one async closure formed on the actor,
    /// so both run on it with no suspension between them; the probe traps (`assertIsolated`) if the
    /// removal runs anywhere else.
    func testTheCheckAndTheRemovalRunOnTheCallersActor() async throws {
        let probe = IsolationProbe()
        let copy = try await probe.undo()
        XCTAssertEqual(copy, .removed)
        let steps = await probe.steps
        XCTAssertEqual(steps, ["restore", "check", "remove (isolated)"])
    }

    // MARK: - order

    /// The original comes back first; only then is the copy checked and removed, so a failure in
    /// between leaves the event twice, never in neither calendar.
    func testTheOriginalIsRestoredBeforeTheCopyIsCheckedAndRemoved() async throws {
        let outcome = try await run(restore: { self.restored })
        XCTAssertEqual(outcome.calls, ["restore", "check", "remove"])
        XCTAssertEqual(outcome.result.restore, .written(restored))
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
        // Only an error from inside `removing` is a removal failure; one thrown around it is the check's.
        let other = try await MoveByCopyUndo.run(copyID: "COPY-1", restoreOriginal: { .written(self.restored) },
                                                 checkAndRemove: { throw Failure.remove })
        XCTAssertEqual(other.copy, .unchecked)
    }

    // MARK: - round 3

    /// Round 3, MEDIUM: the occurrence undo writes nothing when an occurrence of a recurring event
    /// with its title already holds its time (#285), which may be another series of the same title.
    /// The copy is then the only copy of the occurrence for all this server knows, so it is kept and
    /// not even looked up.
    func testACopyIsKeptWhenTheOriginalWasNotRecreated() async throws {
        let outcome = try await run(restore: { self.restored }, held: true, check: { XCTFail("must not check"); return "" },
                                    remove: { _ in XCTFail("must not remove") })
        XCTAssertEqual(outcome.calls, ["restore"])
        XCTAssertEqual(outcome.result.restore, .slotAlreadyHeld)
        XCTAssertEqual(outcome.result.copy, .keptSlotHeld)
        XCTAssertEqual(MoveByCopyUndo.Restore(text: "t", outcome: .occurrenceAlreadyHeld), .slotAlreadyHeld)
        XCTAssertEqual(MoveByCopyUndo.Restore(text: "t", outcome: .occurrenceOneOff(notCarriedOver: [])), .written("t"))
        XCTAssertEqual(MoveByCopyUndo.Restore(text: "t", outcome: nil), .written("t"))

        let text = MoveByCopyUndo.message(restore: .slotAlreadyHeld, title: "Standup", copyID: "COPY-1", copy: .keptSlotHeld)
        XCTAssertTrue(text.hasPrefix("Undone: the moved occurrence of 'Standup' was not recreated in its original calendar"), text)
        XCTAssertTrue(text.contains("an occurrence of a recurring event with its title already holds its time there"), text)
        XCTAssertTrue(text.contains("the copy the move made (id COPY-1) was kept in the calendar it was moved to"), text)
        XCTAssertFalse(text.contains("nothing was written") || text.contains("removed the copy"), text)
        XCTAssertTrue(text.contains("running undo again undoes the operation before it"), text)
    }

    /// Round 3, LOW: a copy with attendees now (added after the move; a move of an event with
    /// attendees is refused) is kept: removing it could send them cancellations.
    func testACopyWithAttendeesIsKept() async throws {
        let outcome = try await run(restore: { self.restored }, check: { throw MoveByCopyUndo.CopyHasAttendees() },
                                    remove: { _ in XCTFail("must not remove") })
        XCTAssertEqual(outcome.result.copy, .hasAttendees)
        let text = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .hasAttendees)
        XCTAssertTrue(text.contains("has attendees now, so it was not removed (removing it could send them a cancellation)"), text)
        XCTAssertTrue(text.contains("the event is now in both calendars"), text)
    }

    /// Round 3, INFO: the removal's sentence is its own, so it does not read as part of a note the
    /// restore text ends with (an occurrence's absolute_alarms).
    func testTheRemovalIsItsOwnSentence() {
        let withNote = "Undone: restored the deleted occurrence of 'Standup' as a one-off event (new ID: NEW-1). Not carried over: absolute_alarms (an absolute-date alarm of the series is now an alarm at the occurrence's start)"
        let text = MoveByCopyUndo.message(restore: .written(withNote), title: "Standup", copyID: "COPY-1", copy: .removed)
        XCTAssertEqual(text, withNote + ". The copy the move made was removed from the calendar it was moved to.")
    }

    // MARK: - texts

    func testTheAnswerSaysWhatBecameOfTheCopy() {
        let removed = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .removed)
        XCTAssertTrue(removed.hasPrefix(restored), removed)
        XCTAssertTrue(removed.contains("The copy the move made was removed from the calendar it was moved to."), removed)
        XCTAssertFalse(removed.contains("both calendars"), removed)

        let left: [MoveByCopyUndo.Copy] = [.noIdentifier, .notFound, .changed(["title"]), .changed(["calendar", "title"]),
                                           .unchecked, .removalFailed("error_code_1"), .hasAttendees]
        for state in left {
            let text = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: state)
            XCTAssertTrue(text.hasPrefix(restored), "the original's restore and its new ID come first: \(text)")
            XCTAssertTrue(text.contains("both calendars"), text)
            XCTAssertTrue(text.contains("running undo again undoes the operation before it"), text)
            XCTAssertFalse(text.contains("second copy"), "nothing a retry does can add a copy: \(text)")
            XCTAssertFalse(text.contains("discard_id"), "the entry is used up, nothing to give up: \(text)")
            XCTAssertFalse(text.contains("delete_event"), "removing the copy is the user's call, no tool named: \(text)")
        }
        // Where the copy is known to be: found unchanged but not removed, or found changed in fields
        // that do not include its calendar.
        for state: MoveByCopyUndo.Copy in [.changed(["title"]), .removalFailed("error_code_1"), .hasAttendees] {
            let text = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: state)
            XCTAssertTrue(text.contains("the event is now in both calendars"), text)
        }
        // Round 2, LOW 1: where it is not known, the text does not say where it is.
        for state: MoveByCopyUndo.Copy in [.noIdentifier, .notFound, .changed(["calendar", "title"]), .unchecked] {
            let text = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: state)
            XCTAssertFalse(text.contains("is now in both calendars"), text)
            XCTAssertFalse(text.contains("left in the calendar it was moved to"), text)
            XCTAssertTrue(text.contains("if it is still in the calendar it was moved to, the event is in both calendars")
                          || text.contains("check where it is"), text)
        }
        let changed = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .changed(["title", "alarms"]))
        XCTAssertTrue(changed.contains("was changed after the move (title, alarms)") && changed.contains("COPY-1"), changed)
        let moved = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .changed(["calendar", "title"]))
        XCTAssertTrue(moved.contains("was changed after the move (calendar, title)") && moved.contains("it may be in another calendar now"), moved)
        let missing = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .notFound)
        XCTAssertTrue(missing.contains("was not found under its recorded identifier"), missing)
        let unchecked = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .unchecked)
        XCTAssertTrue(unchecked.contains("could not be checked, so it was not removed"), unchecked)
        let noID = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "", copy: .noIdentifier)
        XCTAssertTrue(noID.contains("did not record the copy's identifier"), noID)
        let failed = MoveByCopyUndo.message(restore: .written(restored), title: "Standup", copyID: "COPY-1", copy: .removalFailed("error_code_1"))
        XCTAssertTrue(failed.contains("removing the copy the move made failed (error_code_1)"), failed)
    }

    /// Round 2, INFO: the original's calendar missing is refused in the words of a move, not of a
    /// delete: giving up loses nothing the move did not already do, since the copy is in the target.
    func testAMissingOriginalCalendarIsRefusedInTheWordsOfAMove() throws {
        let text = try XCTUnwrap(EventKitError.undoCalendarMissing(event: "Standup", hasIdentifier: true, kind: .undoMoveByCopy).errorDescription)
        XCTAssertTrue(text.hasPrefix("Cannot undo the move of an event (event 'Standup'): the calendar it was moved from is not available"), text)
        XCTAssertTrue(text.contains("the copy the move made stays in the calendar it was moved to, if it is still there"), text)
        XCTAssertFalse(text.contains("cannot recover the deleted"), text)
        XCTAssertTrue(UndoOperation.failsBeforeAnyWrite(EventKitError.undoCalendarMissing(event: "Standup", hasIdentifier: true, kind: .undoMoveByCopy)))
    }

    /// Round 1 LOW: the listing read `Batch (2 operations)`, which the refusal's way on could not
    /// tell apart from another batch.
    func testTheListingNamesTheMoveAndItsTitle() {
        XCTAssertEqual(record.description,
                       "Moved event: Standup (by copy: undo restores it in its original calendar and removes the copy if unchanged)")
        XCTAssertEqual(split.description,
                       "Moved occurrence of event: Standup (split out: undo restores it as a one-off event in its original calendar and removes the copy if unchanged; if an occurrence there already holds its time, nothing is recreated and the copy stays)")
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
        for operation in [record, split] {
            XCTAssertFalse(operation.redoWrites)
            XCTAssertEqual(operation.restoredItemTitle, "Standup")
        }
    }
}

/// An actor that runs `MoveByCopyUndo.run` the way `EventKitManager.executeUndo` does, with closures
/// formed on it, and records whether the removal ran on it.
private actor IsolationProbe {
    private(set) var steps: [String] = []

    private func restore() async -> String { steps.append("restore"); return "restored" }
    private func check() async throws -> Int { steps.append("check"); return 1 }
    private func remove(_ item: Int) {
        assertIsolated("the removal must run on the actor that made the check")
        steps.append("remove (isolated)")
    }
    private func describe() -> String { assertIsolated("the failure is described on the actor"); return "" }

    func undo() async throws -> MoveByCopyUndo.Copy {
        try await MoveByCopyUndo.run(
            copyID: "COPY-1",
            restoreOriginal: { .written(await self.restore()) },
            checkAndRemove: {
                let item = try await self.check()
                try MoveByCopyUndo.removing({ self.remove(item) }, describe: { _ in self.describe() })
            }).copy
    }
}
