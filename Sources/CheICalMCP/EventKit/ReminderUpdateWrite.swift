import CoreLocation
import EventKit
import Foundation

/// The writes `update_reminder` makes to one loaded reminder (PR #256 verify round 1), behind
/// closures (the closure-seam variant, #182), so the order of the writes, the save, the checks on
/// the saved reminder and the rollback can be tested with in-memory EventKit objects.
///
/// Everything that can refuse the call runs before the first write: `checkRealign` and
/// `checkAlarms` here, and the
/// `calendar_name` lookup in the caller, which passes the resolved list in. A refused call leaves
/// the reminder untouched; the reminder object lives on in the server's store, so a change left
/// on it would be written by whatever saves it next.
enum ReminderUpdateWrite {
    /// #486: a value with the flag that clears it, refused before any write, as
    /// `ReminderRecurrenceWrite.bothMessage` is for the rule. The clear used to win silently.
    static let locationTriggerBothMessage = "Cannot specify both location_trigger and clear_location_trigger"
    static let tagsBothMessage = "Cannot specify both tags and clear_tags"

    /// The reminder an update starts from, re-read first (PR #256 verify rounds 2 and 3): the
    /// server's store caches it, and without `refresh()` an edit made in Reminders.app since then
    /// would be overwritten, and recorded wrongly for undo. `refresh() == false` means it is gone:
    /// not found, the #236 convention. `getReminder`, which `update_reminder` reads notes and tags
    /// from, goes through here too.
    static func freshReminder(identifier: String, lookup: (String) -> EKReminder?,
                              refresh: (EKReminder) -> Bool) throws -> EKReminder {
        guard let reminder = lookup(identifier), refresh(reminder) else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }
        return reminder
    }

    /// #235: `realign_to_due` needs a due date to align to, from the request or the reminder, and
    /// cannot go with `clear_due_date`. The server refuses both before calling the store; this is
    /// the same guard at the seam, so `apply` cannot be driven past it.
    static func checkRealign(_ request: ReminderUpdateRequest, existingDue: DateComponents?) throws {
        if request.realignToDue && request.clearDueDate {
            throw ToolError.invalidParameter("Cannot specify both realign_to_due and clear_due_date")
        }
        if request.realignToDue && request.due == nil && existingDue == nil {
            throw ToolError.invalidParameter("realign_to_due needs a due date: the reminder has none, so pass due_date")
        }
    }

    /// #333: a relative alarm needs the reminder to have a timed due date after the call
    /// (`ReminderRelativeAlarms.check`). The caller runs it before its lookups; `apply` again.
    static func checkAlarms(_ request: ReminderUpdateRequest, existingDue: DateComponents?) throws {
        try ReminderRelativeAlarms.check(request.alarmOffsets, due: ReminderRelativeAlarms.dueState(
            requested: request.due, clearDue: request.clearDueDate, existing: existingDue))
    }

    /// Applies `request` to `reminder`, saves it, and returns the date sync judged on the saved
    /// reminder (`ReminderDateSync.confirmSaved`), or `nil` when the due date was not touched.
    /// `save` writes to the store, `reload` re-reads the reminder (`EKObject.refresh()`, false
    /// when the reminder is gone), and
    /// `rollback` is `EKObject.rollback()`, which clears `hasChanges` and does not drop the change
    /// (#274, `ExistingReminderSave`); when `save` throws, it runs and the error is rethrown.
    static func apply(_ request: ReminderUpdateRequest, to reminder: EKReminder, calendar: EKCalendar?,
                      save: () throws -> Void, reload: () -> Bool,
                      rollback: () -> Void,
                      current: (() -> EKReminder)? = nil) throws -> ReminderDateSync.Report? {
        // The seam-level guard: the caller runs it before its own lookups too, but `apply` does not
        // rely on that.
        try checkRealign(request, existingDue: reminder.dueDateComponents)
        try checkAlarms(request, existingDue: reminder.dueDateComponents)
        if request.locationTrigger != nil && request.clearLocationTrigger {   // #486, as in the server
            throw ToolError.invalidParameter(locationTriggerBothMessage)
        }
        try ReminderRecurrenceWrite.check(request, existingDue: reminder.dueDateComponents,
                                          repeats: reminder.hasRecurrenceRules, isCompleted: reminder.isCompleted)   // #354
        if let title = request.title { reminder.title = title }
        if let notes = request.notes { reminder.notes = notes }
        if let priority = request.priority { reminder.priority = priority }

        // #227: the start date and absolute-date alarms follow the due date; Reminders.app
        // displays the alarm's date, so leaving it behind keeps showing the old date.
        // #235: realignToDue puts them onto the due date instead, whatever it moved by.
        // #267: a day makes the reminder date-only and removes the absolute alarms, so there is
        // nothing left for realignToDue to put on it.
        var dateSync: ReminderDateSync.Report?
        if request.clearDueDate {
            dateSync = ReminderDateSync.setDue(reminder, to: nil)
        } else if case .timed(let due)? = request.due {
            dateSync = ReminderDateSync.setDue(reminder, to: due, realignToDue: request.realignToDue)
        } else if case .day(let day)? = request.due {
            dateSync = ReminderDateSync.setDueDay(reminder, to: day)
        } else if request.realignToDue {
            dateSync = ReminderDateSync.realign(reminder)
        }

        if let calendar { reminder.calendar = calendar }

        if request.clearLocationTrigger {
            removeLocationAlarms(from: reminder)
        } else if let trigger = request.locationTrigger {
            removeLocationAlarms(from: reminder)
            let structured = EKStructuredLocation(title: trigger.title)
            structured.geoLocation = CLLocation(latitude: trigger.latitude, longitude: trigger.longitude)
            structured.radius = trigger.radius > 0 ? trigger.radius : 100
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = trigger.proximity
            reminder.addAlarm(alarm)
        }

        // #354: after the due date is written, in the same save (EKErrorDomain 18).
        ReminderRecurrenceWrite.write(request, to: reminder)

        // #333: after the due date is set, so a date-only due no longer has these to keep (#267);
        // only relative alarms are replaced, the location and absolute-date alarms stay.
        if let offsets = request.alarmOffsets {
            ReminderRelativeAlarms.replace(on: reminder, with: offsets)
        }

        do {
            try save()
        } catch {
            rollback()
            throw error
        }
        guard let dateSync else { return nil }
        // PR #507 round 1: `current` is the reminder the save left behind (another object when the
        // save gave it another identifier); the date check reads and, on fallback, writes that one.
        return ReminderDateSync.confirmSaved(current?() ?? reminder, report: dateSync, save: save, reload: reload, rollback: rollback)
    }

    /// What `update_reminder` may say about the alarms after the save (PR #438 verify).
    struct AlarmReadBack: Equatable, Sendable {
        /// The relative alarms off the re-read reminder, when the call passed
        /// `alarms_minutes_offsets`; `nil` otherwise and when it could not be re-read.
        let stored: [Double]?
        /// #433: the call touched the alarms or the due date and the earliest alarm is off the due time.
        let listShowsAlarmTime: Bool
    }

    /// `reload` runs only when the date path did not try one: `dateSync.reread` is what happened
    /// there, and a date sync does not by itself mean a reload (`clear_due_date` writes no due).
    /// A call that touches neither the alarms nor the due date reloads nothing and reports nothing.
    static func alarmReadBack(_ request: ReminderUpdateRequest, saved reminder: EKReminder,
                              dateSync: ReminderDateSync.Report?, reload: () -> Bool) -> AlarmReadBack {
        guard ReminderRelativeAlarms.reportsListTime(request), dateSync?.reread ?? reload() else {
            return AlarmReadBack(stored: nil, listShowsAlarmTime: false)
        }
        return AlarmReadBack(stored: request.alarmOffsets.map { _ in ReminderRelativeAlarms.storedMinutesBefore(reminder) },
                             listShowsAlarmTime: ReminderRelativeAlarms.listShowsAlarmTime(saved: reminder))
    }

    private static func removeLocationAlarms(from reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] where alarm.structuredLocation != nil {
            reminder.removeAlarm(alarm)
        }
    }
}
