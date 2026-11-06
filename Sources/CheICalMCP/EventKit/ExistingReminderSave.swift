import EventKit

/// #274: a save of a reminder that is already in the store. When it throws, `discard` runs before
/// the error goes on, so a later, unrelated call cannot write what failed.
///
/// Measured on iCloud (2026-11-06, one store, a commit made to fail with the #261 method): the failed
/// change stays pending in the store, and the next save of anything commits it. For an edit that was
/// the new title; for a completion of a repeating reminder it was the rollover. `rollback()`,
/// `reset()` and `refresh()` on the reminder did not stop it (`rollback()` only cleared
/// `hasChanges`). `EKEventStore.reset()` did: the store kept the old values, later saves of
/// reminders and events, a bare `commit()`, and reads and lists through the same store all worked.
/// Reset alone leaves the failed values on the object, so it is refreshed too.
///
/// Every write of this server commits at once, so the reset drops only the write that failed. A call
/// suspended at that moment keeps the objects it holds (an object fetched before the reset could
/// still be read and refreshed on device). A commit that fails because of the reminder itself was
/// not reached on device: a list deleted through another store did not make the save fail.
enum ExistingReminderSave {
    /// Closure seam (#182), so the order is tested without a store.
    static func run(save: () throws -> Void, discard: () -> Void) throws {
        do {
            try save()
        } catch {
            discard()
            throw error
        }
    }
}

extension EventKitManager {
    func saveExistingReminder(_ reminder: EKReminder) throws {
        try ExistingReminderSave.run(save: { try eventStore.save(reminder, commit: true) },
                                     discard: { discardFailedSave(of: reminder) })
    }

    /// The discard behind `ExistingReminderSave`, also what `update_reminder` and the create
    /// fallback hand their seams as `rollback`.
    func discardFailedSave(of reminder: EKReminder) {
        reminder.rollback()
        eventStore.reset()
        _ = reminder.refresh()
        markNeedsRefresh()
    }
}
