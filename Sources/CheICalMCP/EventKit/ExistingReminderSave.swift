import EventKit

/// #274: a save or a removal of a reminder that is already in the store, when it throws. The change
/// cannot be dropped, so the error says it may still land.
///
/// Measured on iCloud (2026-11-06, one store, a commit made to fail with the #261 method): the failed
/// change stays pending in the store, and the next save of anything commits it. That was the new
/// title of an edit, the rollover of a repeating reminder, and a removal, which deleted the reminder
/// with no undo record. `rollback()`, `refresh()` and `reset()` on the reminder did not stop it:
/// `rollback()` only clears `hasChanges`, so it is here to keep the object honest, not to undo the
/// failure. A failed save of an event or a calendar, and a failed removal of an event, left nothing
/// pending, with or without `rollback()`.
///
/// `EKEventStore.reset()` does drop it, and PR #456 used it, but it stays out (verify of that PR).
/// The header says "All objects ever created/fetched, etc. using this store are no longer connected
/// to it and are considered invalid". The manager is a reentrant actor and swift-sdk runs each
/// request in its own task, so a reset would hit unrelated calls: `createReminder` holds a calendar
/// across `await findDuplicateReminder`, the undo paths hold objects across awaits, the handlers read
/// `EKEvent`s off the actor, and a `fetchReminders` in flight might never call back. That means false
/// successes, hangs or a crash in calls that did nothing wrong, against a rare failure whose change
/// is what the caller asked for. What a reset would need is on #459.
enum ExistingReminderSave {
    /// Closure seam (#182), so the order is tested without a store.
    static func run(write: () throws -> Void, rollback: () -> Void, report: (Error) -> Error) throws {
        do {
            try write()
        } catch {
            rollback()
            throw report(error)
        }
    }
}

extension EventKitManager {
    /// `handler` names the failure on stderr; the response gets the code and the warning.
    func saveExistingReminder(_ reminder: EKReminder, handler: String) throws {
        try ExistingReminderSave.run(
            write: { try eventStore.save(reminder, commit: true) },
            rollback: { reminder.rollback() },
            report: { error in
                EventKitError.reminderSaveMayLand(code: EventKitErrorSanitizer.writeFailureLog(
                    handler: handler, identifier: reminder.calendarItemIdentifier, error: error))
            })
    }

    func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {
        try ExistingReminderSave.run(
            write: { try eventStore.remove(reminder, commit: true) },
            rollback: { reminder.rollback() },
            report: { error in
                EventKitError.reminderRemovalMayLand(code: EventKitErrorSanitizer.writeFailureLog(
                    handler: handler, identifier: reminder.calendarItemIdentifier, error: error))
            })
    }
}
