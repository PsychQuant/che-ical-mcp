import EventKit
import Foundation

/// #236 — the manager side of the post-state guard (the comparison is in
/// `UndoPostStateGuard.swift`). A record captures the state its write left by reading the item
/// back the way undo will read it; undo resolves the item, refreshes it, compares, and refuses
/// with `UndoTargetChangedError` before writing anything.
extension EventKitManager {
    /// The state an undo of this event write compares with, read the way the undo reads it
    /// (by identifier, refreshed): for a recurring event that is the series' first occurrence,
    /// not necessarily the object the write saved. Falls back to the saved object when the
    /// identifier does not resolve yet; the undo then fails as not found, which keeps the record.
    func postWriteSnapshot(eventID: String, saved: EKEvent) -> EventSnapshot {
        if !eventID.isEmpty, let event = eventStore.event(withIdentifier: eventID), event.refresh() {
            return EventSnapshot(from: event)
        }
        return EventSnapshot(from: saved)
    }

    /// Reminder counterpart of `postWriteSnapshot(eventID:saved:)`.
    func postWriteSnapshot(reminderID: String, saved: EKReminder) -> ReminderSnapshot {
        if !reminderID.isEmpty, let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder,
           reminder.refresh() {
            return ReminderSnapshot(from: reminder)
        }
        return ReminderSnapshot(from: saved)
    }

    /// The event an undo or redo writes to, by identifier and refreshed: a long-lived store can
    /// return stale fields after an edit made elsewhere until the object is refreshed
    /// (diagnosis evidence 2), and the guard must compare, and the arm write to, the current
    /// state. A `false` from `refresh()` means the event is gone: not found, which keeps the
    /// record for a retry (#191).
    func historyEvent(id: String) throws -> EKEvent {
        refreshIfNeeded()
        guard let event = eventStore.event(withIdentifier: id), event.refresh() else {
            throw EventKitError.eventNotFound(identifier: id)
        }
        return event
    }

    /// Reminder counterpart of `historyEvent(id:)`.
    func historyReminder(id: String) throws -> EKReminder {
        refreshIfNeeded()
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder, reminder.refresh() else {
            throw EventKitError.reminderNotFound(identifier: id)
        }
        return reminder
    }

    /// The item an undo (or redo) of `operation` writes to: resolved, refreshed, and checked
    /// against the state the operation (for a redo: its undo) left. Throws
    /// `UndoTargetChangedError` instead of returning an item that was changed since; `nil` for
    /// records that write to no existing item. A recurring completion goes through the #204
    /// identity guard first: a different occurrence is permanent, a changed completion is not.
    func verifiedHistoryTarget(of operation: UndoOperation, verb: UndoHistoryVerb) async throws -> EKCalendarItem? {
        guard let expected = verb == .undo ? operation.undoPostState : operation.redoPostState else { return nil }
        let item: EKCalendarItem
        if case .completeRecurringReminder(let before, _, _) = operation {
            try await ensureReminderAccess()
            item = try resolveRecurringOccurrence(before, verb: verb.rawValue)
        } else {
            switch expected.kind {
            case .event:
                item = try historyEvent(id: expected.itemID)
            case .reminder:
                try await ensureReminderAccess()
                item = try historyReminder(id: expected.itemID)
            }
        }
        let changed = expected.changedFields(in: item)
        guard changed.isEmpty else {
            throw UndoTargetChangedError(verb: verb, kind: expected.kind, title: expected.title, changedFields: changed)
        }
        return item
    }

    /// D4 pre-flight for one member of a batch (nested batches are walked).
    func verifyHistoryTarget(of operation: UndoOperation, verb: UndoHistoryVerb) async throws {
        if case .batch(let operations) = operation {
            for member in operations { try await verifyHistoryTarget(of: member, verb: verb) }
            return
        }
        _ = try await verifiedHistoryTarget(of: operation, verb: verb)
    }

    /// Each undo arm knows its record kind, so a mismatch is unreachable by construction; it
    /// throws rather than force-unwrapping, like `apply(_:to:)`.
    func verifiedEvent(of operation: UndoOperation, verb: UndoHistoryVerb) async throws -> EKEvent {
        guard let event = try await verifiedHistoryTarget(of: operation, verb: verb) as? EKEvent else {
            throw UnrecoverableUndoError(message: "Undo record has no event post-state.")
        }
        return event
    }

    func verifiedReminder(of operation: UndoOperation, verb: UndoHistoryVerb) async throws -> EKReminder {
        guard let reminder = try await verifiedHistoryTarget(of: operation, verb: verb) as? EKReminder else {
            throw UnrecoverableUndoError(message: "Undo record has no reminder post-state.")
        }
        return reminder
    }
}
