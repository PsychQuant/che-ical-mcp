import CoreLocation
import EventKit
import Foundation

/// The writes `update_reminder` makes to one loaded reminder (PR #256 verify round 1), behind
/// closures (the closure-seam variant, #182), so the order of the writes, the save, the checks on
/// the saved reminder and the rollback can be tested with in-memory EventKit objects.
///
/// Everything that can refuse the call runs before the first write: `checkRealign` here, and the
/// `calendar_name` lookup in the caller, which passes the resolved list in. A refused call leaves
/// the reminder untouched; the reminder object lives on in the server's store, so a change left
/// on it would be written by whatever saves it next.
enum ReminderUpdateWrite {
    /// #235: `realign_to_due` needs a due date to align to, from the request or the reminder.
    static func checkRealign(_ request: ReminderUpdateRequest, existingDue: DateComponents?) throws {
        if request.realignToDue && request.dueDate == nil && existingDue == nil {
            throw ToolError.invalidParameter("realign_to_due needs a due date: the reminder has none, so pass due_date")
        }
    }

    /// Applies `request` to `reminder`, saves it, and returns the date sync judged on the saved
    /// reminder (`ReminderDateSync.confirmSaved`), or `nil` when the due date was not touched.
    /// `save` writes to the store, `reload` re-reads the reminder (`EKObject.refresh()`), and
    /// `rollback` discards unsaved changes (`EKObject.rollback()`); when `save` throws, the
    /// changes are rolled back and the error is rethrown.
    static func apply(_ request: ReminderUpdateRequest, to reminder: EKReminder, calendar: EKCalendar?,
                      save: () throws -> Void, reload: () -> Void,
                      rollback: () -> Void) throws -> ReminderDateSync.Report? {
        if let title = request.title { reminder.title = title }
        if let notes = request.notes { reminder.notes = notes }
        if let priority = request.priority { reminder.priority = priority }

        // #227: the start date and absolute-date alarms follow the due date; Reminders.app
        // displays the alarm's date, so leaving it behind keeps showing the old date.
        // #235: realignToDue puts them onto the due date instead, whatever it moved by.
        var dateSync: ReminderDateSync.Report?
        if request.clearDueDate {
            dateSync = ReminderDateSync.setDue(reminder, to: nil)
        } else if let due = request.dueDate {
            dateSync = ReminderDateSync.setDue(reminder, to: due, realignToDue: request.realignToDue)
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

        do {
            try save()
        } catch {
            rollback()
            throw error
        }
        guard let dateSync else { return nil }
        return ReminderDateSync.confirmSaved(reminder, report: dateSync, save: save, reload: reload, rollback: rollback)
    }

    private static func removeLocationAlarms(from reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] where alarm.structuredLocation != nil {
            reminder.removeAlarm(alarm)
        }
    }
}
