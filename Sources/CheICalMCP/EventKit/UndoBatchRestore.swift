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
