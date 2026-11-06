import EventKit
import Foundation

/// Reminder completion and occurrence guards remain isolated to the manager actor.
extension EventKitManager {
    func completeReminder(identifier: String, completed: Bool = true) async throws -> ReminderCompletionResult {
        try await ensureReminderAccess()
        // Same refresh discipline as the read paths, so the pre-save snapshot the
        // successor comparison is anchored on is not stale from an earlier mutation;
        // and the object refreshed (#236, PR #259 verify #5), so `before` (what undo
        // restores) is not a stale copy either.
        guard let reminder = freshReminder(id: identifier) else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }
        let before = ReminderCompletionSnapshot(from: reminder)
        // #423: the relative alarms before the save, to name the ones that appear at the rollover.
        let beforeRelativeAlarms = ReminderRelativeAlarms.storedMinutesBefore(reminder)
        ReminderCompletionWrite.applyRequest(to: reminder, completed: completed, now: Date())
        let writtenCompletionDate = reminder.completionDate
        try saveExistingReminder(reminder)
        // Observe exactly once, synchronously, before any suspension point. On
        // iCloud (on-device probe, PR #195) save advances a recurring reminder in
        // place, so this read already reflects the successor; a store that surfaces
        // the successor later or under another identifier yields `unknown`, never a
        // guess. No polling: a read of the cached store after a suspension point cannot
        // be attributed to this save rather than to another writer.
        let afterSave = ReminderCompletionSnapshot(from: reminder)
        let next = ReminderNextOccurrence.evaluate(before: before, observed: afterSave,
                                                   requestedCompleted: completed)
        // #423: the one reload, in the same synchronous stretch as `beforeRelativeAlarms` and the
        // save, so no other call of this server can write to the reminder between them. Awaiting
        // the undo manager below would let this actor be re-entered. Another process still can
        // write here, so the response says the alarms appeared, not who wrote them. Reads only;
        // the undo record uses values captured above, so it does not see the reload.
        let rolloverAlarms = ReminderRolloverAlarms.observe(before: beforeRelativeAlarms, next: next, item: reminder,
                                                            reload: { reminder.refresh() ? ReminderCompletionSnapshot(from: reminder) : nil })
        markNeedsRefresh()
        // Identity-guarded record for identifiable recurring items (undo refuses and
        // is discarded once the identifier resolves to a later occurrence — see
        // executeUndo); legacy identifier-keyed record for everything else.
        await CalendarUndoManager.shared.record(.forCompletion(before: before, requestedCompleted: completed, savedTitle: afterSave.title, savedCompletionDate: completed ? (afterSave.completionDate ?? writtenCompletionDate) : nil))
        return ReminderCompletionResult(before: before, afterSave: afterSave,
                                        requestedCompleted: completed, nextOccurrence: next, rolloverAlarms: rolloverAlarms)
    }

    /// The recorded identifier may now resolve to the NEXT occurrence: on
    /// iCloud, completing a recurring reminder advances the same identifier in
    /// place and files the finished occurrence as a separate completed record
    /// (on-device probe, PR #195). Acting on the advanced item would mutate the
    /// wrong occurrence, and no retry can make the identity match again, so
    /// the failure is permanent and the caller discards the history entry.
    /// #236: runs on the reminder `verifiedHistoryTarget` resolved and refreshed
    /// (with the read paths' refresh discipline), before the completion check; not
    /// found stays transient there, as for every other arm (#191).
    func ensureSameOccurrence(_ before: ReminderCompletionSnapshot, _ reminder: EKReminder, verb: String) throws {
        guard before.matchesOccurrence(ReminderCompletionSnapshot(from: reminder)) else {
            throw UndoOperation.occurrenceIdentityRefusal(before: before, verb: verb)
        }
    }

    /// #236: `verifiedReminder` runs the identity guard above (a mismatch is permanent and
    /// discards the record), then the completion post-state check (a mismatch keeps the record).
    func undoRecurringCompletion(_ operation: UndoOperation, before: ReminderCompletionSnapshot) async throws -> String {
        let reminder = try await verifiedReminder(of: operation, verb: .undo)
        try apply(operation.completionWrite(undo: true, now: Date()), to: reminder)
        try saveExistingReminder(reminder)
        markNeedsRefresh()
        return "Undone: set recurring reminder '\(undoVisibleTitle(before.title))' completion to \(before.isCompleted)"
    }

    func redoRecurringCompletion(_ operation: UndoOperation, before: ReminderCompletionSnapshot, requestedCompleted: Bool) async throws -> String {
        let reminder = try await verifiedReminder(of: operation, verb: .redo)
        try apply(operation.completionWrite(undo: false, now: Date()), to: reminder)
        try saveExistingReminder(reminder)
        markNeedsRefresh()
        return "Redone: set recurring reminder '\(undoVisibleTitle(before.title))' completion to \(requestedCompleted)"
    }
}
