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
    /// What became of the copy.
    enum Copy: Equatable, Sendable {
        case removed
        /// The move recorded no identifier for the copy; it was not looked up.
        case noIdentifier
        /// Not found under its recorded identifier (deleted, or given a new one by its account).
        case notFound
        /// Changed after the move in the fields named (the #236 compare of a created event).
        case changed([String])
        /// The check failed for another reason (a lookup that raised, #288; an access gate).
        case unchecked
        /// Found and unchanged, but its removal failed with this sanitized code.
        case removalFailed(String)
    }

    /// What `removing` throws: the removal of a copy that passed its check failed.
    struct RemovalFailure: Error {
        let underlying: Error
    }

    /// Runs the removal inside `checkAndRemove`, so its failure is told apart from the check's.
    /// Synchronous: it runs where its caller runs, on the actor of the closure that calls it.
    static func removing(_ removal: () throws -> Void) throws {
        do { try removal() } catch { throw RemovalFailure(underlying: error) }
    }

    /// Restore the source, then check the copy and remove it. Only the restore's error is thrown
    /// (nothing of the copy was touched then); every outcome after it is returned.
    ///
    /// PR #474 round 2: this function is nonisolated (Swift 5 mode, SE-0338), so it resumes off the
    /// caller's actor after each await. The check and the removal are therefore one async closure,
    /// `checkAndRemove`, which the caller forms on its actor: the whole closure runs there, so nothing
    /// suspends between the #236 check and the removal, and the removal never runs off the actor. It
    /// wraps the removal in `removing`; any other error it throws is the check's. A synchronous
    /// removal closure, which this took in round 1, ran off the actor after the check's await.
    static func run(copyID: String,
                    restoreOriginal: () async throws -> String,
                    checkAndRemove: () async throws -> Void,
                    describeRemovalFailure: (Error) -> String) async throws -> (restored: String, copy: Copy) {
        let restored = try await restoreOriginal()
        guard !copyID.isEmpty else { return (restored, .noIdentifier) }
        do {
            try await checkAndRemove()
        } catch let failure as RemovalFailure {
            return (restored, .removalFailed(describeRemovalFailure(failure.underlying)))
        } catch {
            return (restored, copyState(afterCheckFailure: error))
        }
        return (restored, .removed)
    }

    /// The copy's state from the error its check threw: the two #236 errors by type, anything else
    /// unchecked. Never a reason to refuse the source's restore, which has already run.
    static func copyState(afterCheckFailure error: Error) -> Copy {
        if let changed = error as? UndoTargetChangedError { return .changed(changed.changedFields) }
        if error is UndoTargetMissingError { return .notFound }
        return .unchecked
    }

    /// The answer: the source's own restore text (title and new ID), then what became of the copy.
    /// Not an error: the source is back. When the copy stays, the text says the event is in both
    /// calendars where the copy is known to be in the target (found unchanged but not removed, or
    /// changed in fields that leave out its calendar), and otherwise only that it may be (round 2,
    /// LOW 1: a copy moved elsewhere is `changed(["calendar", …])`); and that this entry is used up, and leaves removing the copy to the user, naming no
    /// tool. Field names come from the #236 compare (author-controlled); `copyID` is the store's
    /// identifier, as the restore text gives the new one.
    static func message(restored: String, copyID: String, copy: Copy) -> String {
        let id = copyID.isEmpty ? "" : " (id \(copyID))"
        let used = " This history entry is used up: running undo again undoes the operation before it, not this copy."
        let both = "and the event is now in both calendars: remove the copy there if it should go."
        switch copy {
        case .removed:
            return restored + ", and removed the copy the move made in the calendar it was moved to"
        case .noIdentifier:
            return restored + ". The move did not record the copy's identifier, so the copy was not looked up and nothing was removed; if it is still in the calendar it was moved to, the event is in both calendars: remove the copy there if it should go." + used
        case .notFound:
            return restored + ". The copy the move made\(id) was not found under its recorded identifier (deleted, or given a new identifier by its account), so nothing was removed; if it is still in the calendar it was moved to, the event is in both calendars: remove the copy there if it should go." + used
        case .changed(let fields) where fields.contains("calendar"):
            return restored + ". The copy the move made\(id) was changed after the move (\(fields.joined(separator: ", "))), so it was not removed; it may be in another calendar now: check where it is, since the event may be in both calendars, and remove the copy if it should go." + used
        case .changed(let fields):
            return restored + ". The copy the move made\(id) was changed after the move (\(fields.joined(separator: ", "))), so it was left in the calendar it was moved to, " + both + used
        case .unchecked:
            return restored + ". The copy the move made\(id) could not be checked, so it was not removed; if it is still in the calendar it was moved to, the event is in both calendars: remove the copy there if it should go." + used
        case .removalFailed(let code):
            return restored + ". Then removing the copy the move made failed (\(code)): the copy\(id) is still in the calendar it was moved to, so the event is now in both calendars: remove the copy there if it should go." + used
        }
    }
}
