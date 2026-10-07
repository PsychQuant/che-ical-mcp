import CheMCPKit
import Foundation

/// #248 — a batch undo restores all of its members or none of them when one cannot be restored.
/// The batch record is the unit of history while the writes are per member, so a member that
/// failed after earlier members were written used to put the whole record back, and the next undo
/// recreated those members again.

/// B: where the undo of a batch member recreates its item. Only the delete records recreate; every
/// other record writes to an existing item, which the post-state check covers, or writes nothing.
enum UndoRestoreDestination {
    /// The recorded calendar, resolved as `applySnapshot` resolves it (`EventSnapshot.resolveCalendar`).
    case eventCalendar(EventSnapshot)
    /// The list `applyReminderSnapshot` picks.
    case reminderList(ReminderSnapshot)

    /// The refusal when the destination is gone.
    var missingError: UndoRestoreDestinationMissingError {
        switch self {
        case .eventCalendar(let snapshot):
            return UndoRestoreDestinationMissingError(item: "event", title: snapshot.title, container: "calendar",
                                                      containerTitle: snapshot.calendarTitle,
                                                      accountTitle: snapshot.calendarSource)
        case .reminderList(let snapshot):
            return UndoRestoreDestinationMissingError(item: "reminder", title: snapshot.title, container: "list",
                                                      containerTitle: snapshot.calendarTitle,
                                                      accountTitle: snapshot.calendarSource)
        }
    }
}

extension UndoOperation {
    /// Where an undo of this record recreates the item, or nil. A redo of a delete writes nothing
    /// (#247). A batch is walked member by member by the caller. Exhaustive, so a new record kind
    /// must be classified to compile (#196 convention).
    func restoreDestination(verb: UndoHistoryVerb) -> UndoRestoreDestination? {
        guard verb == .undo else { return nil }
        switch self {
        case .deleteEvent(let snapshot):
            return .eventCalendar(snapshot)
        case .deleteReminder(let snapshot):
            return .reminderList(snapshot)
        case .createEvent, .updateEvent, .updateRecurringEvent, .moveEvent, .createReminder, .updateReminder,
             .completeReminder, .completeRecurringReminder, .batch:
            return nil
        }
    }
}

/// B: a batch member cannot be restored because the calendar or list it would be recreated in is
/// not there. Raised by the batch pre-check, so nothing of the batch was written; kept like a
/// not-found (`UndoFailureDisposition.of` maps it to `.restore`), since the calendar may only be
/// syncing.
///
/// The message is author-controlled text: the item and container words come from this file, and
/// the store-derived titles (a shared calendar's title is set by someone else, #37 F1) pass
/// `undoShownTitle`. That is the condition under which this type conforms to `TrustedErrorMessage`.
struct UndoRestoreDestinationMissingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(item: String, title: String, container: String, containerTitle: String, accountTitle: String?) {
        let account = accountTitle.map { " in '\(undoShownTitle($0))'" } ?? ""
        message = "Cannot undo: the deleted \(item) '\(undoShownTitle(title))' cannot be restored because the \(container) it was in ('\(undoShownTitle(containerTitle))'\(account)) is not available. Nothing in this batch was written and this history entry was kept. If that \(container) was deleted or its account removed, no retry can restore it: ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id. Run undo again only if the \(container) may still be syncing."
    }
}

extension UndoRestoreDestinationMissingError: TrustedErrorMessage {}

/// A: a batch undo stopped part-way, after `restoredCount` members were written. `handleUndo`
/// puts back a record of `remaining` only, under the same id and timestamp
/// (`CalendarUndoManager.restoreFailedUndo(_:remaining:)`), so the next undo does not recreate the
/// restored members a second time.
///
/// The message is author-controlled text plus `memberError`, which is either a sanitized code or
/// the verbatim message of a `TrustedErrorMessage` (`EventKitErrorSanitizer.writeFailureLog`). That
/// is the condition under which this type conforms to `TrustedErrorMessage`.
struct UndoBatchPartiallyUndoneError: LocalizedError, Sendable {
    /// The members not yet restored, in record order, the failing one included.
    let remaining: [UndoOperation]
    let restoredCount: Int
    let memberError: String
    let message: String
    var errorDescription: String? { message }

    init(remaining: [UndoOperation], restoredCount: Int, memberError: String) {
        self.remaining = remaining
        self.restoredCount = restoredCount
        self.memberError = memberError
        let restored = restoredCount == 1 ? "1 item was" : "\(restoredCount) items were"
        let left = remaining.count == 1 ? "the 1 item not yet restored" : "the \(remaining.count) items not yet restored"
        message = "Undo of this batch stopped part-way: \(restored) restored, then restoring the next one failed (\(memberError)). This history entry was kept with only \(left), under the same id, so running undo again does not restore the others a second time. If the failure will not go away (for example, the calendar or list was deleted), ask the user whether to give up the rest of this undo; if they agree, read undo_history and call undo with discard_id set to its id."
    }
}

extension UndoBatchPartiallyUndoneError: TrustedErrorMessage {}

extension UndoOperation {
    /// A: the error a batch undo reports when a write failed. `members` are in record order; the
    /// undo ran them in reverse, so the `interrupted.completed` members written are the last ones,
    /// and the record keeps the others, the failing one included. When nothing was written the
    /// member error stands and the record is kept whole, as before. A failing member that is itself
    /// a batch stopped part-way is replaced by its own remainder (no nested batch is recorded today).
    /// `describe` gives the member error for the message; it is called only when the batch stopped
    /// part-way.
    static func batchUndoFailure(members: [UndoOperation], interrupted: UndoBatchRunner.Interrupted,
                                 describe: (Error) -> String) -> Error {
        let failedIndex = members.count - 1 - interrupted.completed
        guard members.indices.contains(failedIndex) else { return interrupted.underlying }
        let inner = interrupted.underlying as? UndoBatchPartiallyUndoneError
        if interrupted.completed == 0 && inner == nil { return interrupted.underlying }
        let failing: UndoOperation = inner.map { .batch($0.remaining) } ?? members[failedIndex]
        return UndoBatchPartiallyUndoneError(remaining: Array(members[..<failedIndex]) + [failing],
                                             restoredCount: interrupted.completed + (inner?.restoredCount ?? 0),
                                             memberError: inner?.memberError ?? describe(interrupted.underlying))
    }
}
