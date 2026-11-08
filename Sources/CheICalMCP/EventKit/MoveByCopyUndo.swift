import Foundation

/// #466 — the undo of a move that split one occurrence out (span "this") or fell back to copy and
/// delete (`UndoOperation.moveByCopy`). Before #466 it was a `.deleteEvent` record of the source:
/// undo restored the source and left the copy, so the event was there twice. PR #474 round 1 made it
/// a batch of the copy's create record and the source's delete record, but a batch is checked whole
/// before its first write, so a copy changed since the move (a sync can change alarms, time zone or
/// place on its own), deleted elsewhere, or given a new identifier refused the whole undo, and the
/// source did not come back either. Now the source is always restored first, as a delete-undo
/// restores it, and the copy is removed only when it is found under its recorded identifier and
/// unchanged; otherwise it stays and the answer says why. Nothing after the restore throws, so the
/// record is used up once the source is back: a thrown error would put it back, and the next undo
/// would restore the source a second time. Closure seam, so the order is unit-tested without
/// EventKit (`MoveByCopyUndoTests`).
enum MoveByCopyUndo {
    /// What the restore of the source did.
    enum Restore: Equatable, Sendable {
        /// The source was recreated; the restore's own text (title, new ID, notes).
        case written(String)
        /// A split's source was not recreated: an occurrence of its series (or of one undo recreated
        /// from it) already holds its rule slot in its calendar (#285's slot check, by series and
        /// slot since #321). The copy is kept, not even looked up (PR #474 round 3).
        case slotAlreadyHeld

        /// From the occurrence or event undo's text and outcome.
        init(text: String, outcome: UndoEventOutcome?) {
            self = outcome == .occurrenceAlreadyHeld || outcome == .editedOccurrenceAlreadyHeld ? .slotAlreadyHeld : .written(text)
        }
    }

    /// What became of the copy.
    enum Copy: Equatable, Sendable {
        case removed
        /// The source was not recreated (`Restore.slotAlreadyHeld`); the copy was kept unchecked.
        case keptSlotHeld
        /// The move recorded no identifier for the copy; it was not looked up.
        case noIdentifier
        /// Not found under its recorded identifier (deleted, or given a new one by its account).
        case notFound
        /// Changed after the move in the fields named (the #236 compare of a created event).
        case changed([String])
        /// Unchanged in the compared fields, but it has attendees now (the move refuses an event with
        /// attendees, so they were added after it): removing it could send them a cancellation.
        case hasAttendees
        /// The check failed for another reason (a lookup that raised, #288; an access gate).
        case unchecked
        /// Found and unchanged, but its removal failed with this sanitized code.
        case removalFailed(String)
    }

    /// What `removing` throws: the removal of a copy that passed its check failed, with the code.
    struct RemovalFailure: Error {
        let code: String
    }

    /// What `checkAndRemove` throws for a copy that passed the #236 compare but has attendees.
    struct CopyHasAttendees: Error {}

    /// Runs the removal inside `checkAndRemove`, so its failure is told apart from the check's, and
    /// describes the failure there (round 3: on the caller's actor, as the removal is; `run` takes no
    /// synchronous closure, which it would call off the actor). Synchronous: it runs where its caller
    /// runs.
    static func removing(_ removal: () throws -> Void, describe: (Error) -> String) throws {
        do { try removal() } catch { throw RemovalFailure(code: describe(error)) }
    }

    /// Restore the source, then check the copy and remove it. Only the restore's error is thrown
    /// (nothing of the copy was touched then); every outcome after it is returned. A source not
    /// recreated because its slot is held keeps the copy (round 3, MEDIUM: removing it could leave
    /// the occurrence nowhere).
    ///
    /// PR #474 round 2: this function is nonisolated (Swift 5 mode, SE-0338), so it resumes off the
    /// caller's actor after each await. The check and the removal are therefore one async closure,
    /// `checkAndRemove`, which the caller forms on its actor: the whole closure runs there, so no
    /// other call of this server runs between the #236 check and the removal (actor reentrancy; a
    /// change another process saves in between is not excluded), and the removal never runs off the
    /// actor. It wraps the removal in `removing`; any other error it throws is the check's. A
    /// synchronous removal closure, which this took in round 1, ran off the actor after the check.
    static func run(copyID: String,
                    restoreOriginal: () async throws -> Restore,
                    checkAndRemove: () async throws -> Void) async throws -> (restore: Restore, copy: Copy) {
        let restore = try await restoreOriginal()
        guard restore != .slotAlreadyHeld else { return (restore, .keptSlotHeld) }
        guard !copyID.isEmpty else { return (restore, .noIdentifier) }
        do {
            try await checkAndRemove()
        } catch let failure as RemovalFailure {
            return (restore, .removalFailed(failure.code))
        } catch {
            return (restore, copyState(afterCheckFailure: error))
        }
        return (restore, .removed)
    }

    /// The copy's state from the error its check threw: the two #236 errors by type, anything else
    /// unchecked. Never a reason to refuse the source's restore, which has already run.
    static func copyState(afterCheckFailure error: Error) -> Copy {
        if let changed = error as? UndoTargetChangedError { return .changed(changed.changedFields) }
        if error is UndoTargetMissingError { return .notFound }
        if error is CopyHasAttendees { return .hasAttendees }
        return .unchecked
    }

    /// The answer: the source's own restore text (title and new ID), then what became of the copy.
    /// Not an error: the source is back. When the copy stays, the text says the event is in both
    /// calendars where the copy is known to be in the target (found unchanged but not removed, or
    /// changed in fields that leave out its calendar), and otherwise only that it may be (round 2,
    /// LOW 1: a copy moved elsewhere is `changed(["calendar", …])`); and that this entry is used up, and leaves removing the copy to the user, naming no
    /// tool. Field names come from the #236 compare (author-controlled); `copyID` is the store's
    /// identifier, as the restore text gives the new one.
    static func message(restore: Restore, title: String, copyID: String, copy: Copy) -> String {
        let id = copyID.isEmpty ? "" : " (id \(copyID))"
        let used = " This history entry is used up: running undo again undoes the operation before it, not this copy."
        let both = "and the event is now in both calendars: remove the copy there if it should go."
        guard case .written(let restored) = restore else {
            return "Undone: the moved occurrence of '\(undoVisibleTitle(title))' was not recreated in its original calendar: its series already holds its original slot there (the series, or one an undo recreated from it, matched by identifier, #321). So this undo did not look up or remove the copy the move made\(id); if it is still in the calendar it was moved to, the occurrence is now in both calendars: remove the copy there if it should go." + used
        }
        switch copy {
        case .removed:
            return restored + ". The copy the move made was removed from the calendar it was moved to."
        case .keptSlotHeld:
            // Unreachable with `.written` (`run` gives it only for `.slotAlreadyHeld`); worded anyway.
            return restored + ". The copy the move made\(id) was kept in the calendar it was moved to, " + both + used
        case .noIdentifier:
            return restored + ". The move did not record the copy's identifier, so the copy was not looked up and nothing was removed; if it is still in the calendar it was moved to, the event is in both calendars: remove the copy there if it should go." + used
        case .notFound:
            return restored + ". The copy the move made\(id) was not found under its recorded identifier (deleted, or given a new identifier by its account), so nothing was removed; if it is still in the calendar it was moved to, the event is in both calendars: remove the copy there if it should go." + used
        case .changed(let fields) where fields.contains("calendar"):
            return restored + ". The copy the move made\(id) was changed after the move (\(fields.joined(separator: ", "))), so it was not removed; it may be in another calendar now: check where it is, since the event may be in both calendars, and remove the copy if it should go." + used
        case .changed(let fields):
            return restored + ". The copy the move made\(id) was changed after the move (\(fields.joined(separator: ", "))), so it was left in the calendar it was moved to, " + both + used
        case .hasAttendees:
            return restored + ". The copy the move made\(id) has attendees now, so it was not removed (removing it could send them a cancellation); it was left in the calendar it was moved to, " + both + used
        case .unchecked:
            return restored + ". The copy the move made\(id) could not be checked, so it was not removed; if it is still in the calendar it was moved to, the event is in both calendars: remove the copy there if it should go." + used
        case .removalFailed(let code):
            return restored + ". Then removing the copy the move made failed (\(code)): the copy\(id) is still in the calendar it was moved to, so the event is now in both calendars: remove the copy there if it should go." + used
        }
    }
}
