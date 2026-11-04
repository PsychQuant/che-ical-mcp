import EventKit
import Foundation

/// #308: the timed due of `create_reminder` (and of each row of `create_reminders_batch`, which
/// goes through the same `EventKitManager.createReminder`) and the read-back after its save,
/// behind closures (the closure-seam variant, #182), so they are tested on in-memory reminders.
///
/// Before #308 only a date-only create was read back (#301). A timed create was never re-read,
/// returned no `date_sync`, and had no #237 fallback, although zone loss on save (#134 / #237) is
/// the known failure of a timed write. Now every dated create is judged on the saved reminder by
/// `ReminderDateSync.confirmSaved`, as `update_reminder` judges its writes.
enum ReminderCreateWrite {
    /// Writes a create's timed due as before (#134: the zoned components, a plain assignment on the
    /// new reminder; `components` comes from `ReminderDateSync.timedDueComponents`) and returns the
    /// report the read-back judges: nothing moved or removed (the reminder is new), the start as the
    /// write left it (EventKit gives a reminder without a start one equal to its due, #235), and
    /// `aligned` in memory, which `readBack` replaces with the value judged on the saved reminder.
    static func writeTimedDue(_ reminder: EKReminder, components: DateComponents) -> ReminderDateSync.Report {
        reminder.dueDateComponents = components
        return ReminderDateSync.Report(startDate: reminder.startDateComponents == nil ? .absent : .set,
                                       absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0,
                                       aligned: ReminderDateSync.isAligned(reminder, requestedTime: true),
                                       writtenDue: components)
    }

    /// Judges a created reminder after its save, or returns nil for a create without a due date
    /// (nothing to judge; it is not re-read). `save` writes to the store, `reload` re-reads the
    /// reminder (`EKObject.refresh()`), `rollback` discards unsaved changes (`EKObject.rollback()`).
    /// A timed due that read back without its time or zone runs the #237 fallback, which saves the
    /// new reminder a second time; a failed second save is rolled back and reported as
    /// `aligned: false`, never thrown, since the create itself is saved. A date-only due never runs
    /// the fallback. The caller judges before it records the undo entry, so the entry holds what a
    /// fallback save left.
    static func readBack(_ reminder: EKReminder, report: ReminderDateSync.Report?, save: () throws -> Void,
                         reload: () -> Bool, rollback: () -> Void,
                         log: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) -> ReminderDateSync.Report? {
        guard let report else { return nil }
        return ReminderDateSync.confirmSaved(reminder, report: report, save: save, reload: reload, rollback: rollback,
                                             tool: "create_reminder", log: log)
    }
}
