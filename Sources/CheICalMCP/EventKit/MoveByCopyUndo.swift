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

    /// Restore the source, then check the copy and remove it. Only the restore's error is thrown
    /// (nothing of the copy was touched then); every outcome after it is returned.
    static func run<Item>(copyID: String,
                          restoreOriginal: () async throws -> String,
                          checkCopy: () async throws -> Item,
                          removeCopy: (Item) throws -> Void,
                          describeRemovalFailure: (Error) -> String) async throws -> (restored: String, copy: Copy) {
        let restored = try await restoreOriginal()
        guard !copyID.isEmpty else { return (restored, .noIdentifier) }
        let item: Item
        do {
            item = try await checkCopy()
        } catch {
            return (restored, copyState(afterCheckFailure: error))
        }
        do {
            try removeCopy(item)
        } catch {
            return (restored, .removalFailed(describeRemovalFailure(error)))
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
    /// calendars and that this entry is used up, and leaves removing the copy to the user, naming no
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
        case .changed(let fields):
            return restored + ". The copy the move made\(id) was changed after the move (\(fields.joined(separator: ", "))), so it was left in the calendar it was moved to, " + both + used
        case .unchecked:
            return restored + ". The copy the move made\(id) could not be checked, so it was left in the calendar it was moved to, " + both + used
        case .removalFailed(let code):
            return restored + ". Then removing the copy the move made failed (\(code)): the copy\(id) is still in the calendar it was moved to, so the event is now in both calendars: remove the copy there if it should go." + used
        }
    }
}
