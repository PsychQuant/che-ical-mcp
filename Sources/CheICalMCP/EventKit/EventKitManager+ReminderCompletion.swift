import EventKit
import Foundation

/// Reminder completion and occurrence guards remain isolated to the manager actor.
extension EventKitManager {
    func completeReminder(identifier: String, completed: Bool = true) async throws -> ReminderCompletionResult {
        try await ensureReminderAccess()
        // Same refresh discipline as the read paths, so the pre-save snapshot the
        // successor comparison is anchored on is not stale from an earlier mutation.
        refreshIfNeeded()
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }
        let before = ReminderCompletionSnapshot(from: reminder)
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        try eventStore.save(reminder, commit: true)
        // Observe exactly once, synchronously, before any suspension point. On
        // iCloud (on-device probe, PR #195) save advances a recurring reminder in
        // place, so this read already reflects the successor; a store that surfaces
        // the successor later or under another identifier yields `unknown`, never a
        // guess. No polling and no refresh here: a later read of the cached store
        // cannot be attributed to this save rather than to another writer.
        let afterSave = ReminderCompletionSnapshot(from: reminder)
        let next = ReminderNextOccurrence.evaluate(before: before, observed: afterSave,
                                                   requestedCompleted: completed)
        markNeedsRefresh()
        // Identity-guarded record for identifiable recurring items (undo refuses and
        // is discarded once the identifier resolves to a later occurrence — see
        // executeUndo); legacy identifier-keyed record for everything else.
        await CalendarUndoManager.shared.record(.forCompletion(before: before, requestedCompleted: completed, savedTitle: afterSave.title))
        return ReminderCompletionResult(before: before, afterSave: afterSave,
                                        requestedCompleted: completed, nextOccurrence: next)
    }

    /// The recorded identifier may now resolve to the NEXT occurrence: on
    /// iCloud, completing a recurring reminder advances the same identifier in
    /// place and files the finished occurrence as a separate completed record
    /// (on-device probe, PR #195). Acting on the advanced item would mutate the
    /// wrong occurrence, and no retry can make the identity match again, so
    /// the failure is permanent and the caller discards the history entry.
    private func resolveRecurringOccurrence(_ before: ReminderCompletionSnapshot, verb: String) throws -> EKReminder {
        let title = EventKitErrorSanitizer.sanitizeForInterpolation(before.title)
        // Same refresh discipline as the read paths: the guard must compare
        // against the store's current state, not the cache this completion
        // itself marked dirty.
        refreshIfNeeded()
        // Not found is treated as transient (store lag) and keeps the entry for a
        // retry, exactly like the legacy arms (#191); a deleted item therefore
        // stays on the stack until the user clears it, same as every other arm.
        // Only a resolved-but-different occurrence is permanent.
        guard let reminder = eventStore.calendarItem(withIdentifier: before.id) as? EKReminder else {
            throw EventKitError.reminderNotFound(identifier: before.id)
        }
        guard before.matchesOccurrence(ReminderCompletionSnapshot(from: reminder)) else {
            throw UnrecoverableUndoError(message: "Cannot \(verb) recurring reminder completion of '\(title)': its identifier no longer resolves to the recorded occurrence — the series advanced (EventKit keeps the finished occurrence as a separate completed record) or the item's due, rules, list or source were edited since. Act on the intended occurrence explicitly (list_reminders with completed=true, then complete_reminder). This history entry was discarded so earlier operations remain undoable.")
        }
        return reminder
    }

    func undoRecurringCompletion(_ operation: UndoOperation, before: ReminderCompletionSnapshot) async throws -> String {
        try await ensureReminderAccess()
        let reminder = try resolveRecurringOccurrence(before, verb: "undo")
        try apply(operation.completionWrite(undo: true, now: Date()), to: reminder)
        try eventStore.save(reminder, commit: true)
        markNeedsRefresh()
        return "Undone: set recurring reminder '\(EventKitErrorSanitizer.sanitizeForInterpolation(before.title))' completion to \(before.isCompleted)"
    }

    func redoRecurringCompletion(_ operation: UndoOperation, before: ReminderCompletionSnapshot, requestedCompleted: Bool) async throws -> String {
        try await ensureReminderAccess()
        let reminder = try resolveRecurringOccurrence(before, verb: "redo")
        try apply(operation.completionWrite(undo: false, now: Date()), to: reminder)
        try eventStore.save(reminder, commit: true)
        markNeedsRefresh()
        return "Redone: set recurring reminder '\(EventKitErrorSanitizer.sanitizeForInterpolation(before.title))' completion to \(requestedCompleted)"
    }
}
