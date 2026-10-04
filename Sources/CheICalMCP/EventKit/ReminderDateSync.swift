import EventKit
import Foundation

/// #227: keeps a reminder's start date and absolute-date alarms in step with its due date.
///
/// Reminders.app displays the date of a reminder's absolute-date alarm, not its due date
/// (confirmed on device 2026-10-04: syncing the start date alone left the displayed date
/// unchanged; syncing the alarm moved it). Reminders created in the app carry a start date
/// and an alarm at the due time, so changing only `dueDateComponents` leaves the app
/// showing the old date.
///
/// The shift is the difference between the two due *instants*, so an alarm that sat on the
/// old due time lands exactly on the new one, including across a daylight-saving change.
/// Relative-offset and location alarms are never touched.
enum ReminderDateSync {
    enum StartChange: String, Sendable {
        case shifted, cleared, unchanged, absent
    }

    struct Report: Equatable, Sendable {
        let startDate: StartChange
        let absoluteAlarmsShifted: Int
        let absoluteAlarmsRemoved: Int

        var dictionary: [String: Any] {
            [
                "start_date": startDate.rawValue,
                "absolute_alarms_shifted": absoluteAlarmsShifted,
                "absolute_alarms_removed": absoluteAlarmsRemoved,
            ]
        }
    }

    /// The `update_reminder` entry point: writes the new due date (or clears it) and keeps the
    /// start date and absolute alarms in step. `newDue == nil` clears the due date.
    static func setDue(_ reminder: EKReminder, to newDue: Date?) -> Report {
        let oldComponents = reminder.dueDateComponents
        let oldDue = safeDateFromComponents(oldComponents)
        let oldIsDateOnly = oldComponents != nil && oldComponents?.hour == nil
        guard let newDue else {
            reminder.dueDateComponents = nil
            return sync(reminder, from: oldDue, to: nil)
        }
        // #134: always store an explicit time zone so iCloud Web / Today view don't
        // re-interpret floating components as UTC.
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: newDue)
        components.timeZone = TimeZone.current
        reminder.dueDateComponents = components
        // Shift by what was actually stored (minute precision), not the raw input (verify #3).
        let storedDue = safeDateFromComponents(components) ?? newDue
        return sync(reminder, from: oldDue, to: storedDue, oldDueIsDateOnly: oldIsDateOnly,
                    dayTimeZone: oldComponents?.timeZone ?? .current)
    }

    /// - Parameters:
    ///   - oldDue: the due instant before the update, or `nil` if the reminder had none.
    ///   - newDue: the due instant after the update, or `nil` when the due date is cleared.
    ///   - oldDueIsDateOnly: the old due had no time of day. Its instant is midnight, so the
    ///     shift is a whole number of calendar days and alarms keep their time (verify #1).
    ///   - dayTimeZone: the zone in which calendar days are counted for a date-only old due.
    static func sync(_ reminder: EKReminder, from oldDue: Date?, to newDue: Date?,
                     oldDueIsDateOnly: Bool = false, dayTimeZone: TimeZone = .current) -> Report {
        guard let newDue else {
            // Clearing a due date that does not exist is a no-op (verify #4).
            guard oldDue != nil else { return unchanged(reminder) }
            return clear(reminder)
        }
        guard let oldDue, newDue != oldDue else { return unchanged(reminder) }

        // Date-only components (start or old due) move by calendar days, never by seconds:
        // across a daylight-saving change a day is 23 or 25 hours (verify #2).
        let moveInstant: (Date) -> Date
        if oldDueIsDateOnly {
            let days = calendarDays(from: oldDue, to: newDue, in: dayTimeZone)
            guard days != 0 else { return unchanged(reminder) }
            moveInstant = { date in Self.calendar(dayTimeZone).date(byAdding: .day, value: days, to: date) ?? date }
        } else {
            let delta = newDue.timeIntervalSince(oldDue)
            moveInstant = { $0.addingTimeInterval(delta) }
        }

        var startChange = StartChange.absent
        if let start = reminder.startDateComponents {
            if let shifted = shift(start, from: oldDue, to: newDue, moveInstant: moveInstant) {
                reminder.startDateComponents = shifted
                startChange = .shifted
            } else {
                startChange = .unchanged
            }
        }

        let absolute = (reminder.alarms ?? []).filter { $0.absoluteDate != nil }
        for alarm in absolute {
            // Copy, then change only the date, so the alarm's other settings survive (verify #6).
            // `EKAlarm.copy()` drops `soundName` (checked 2026-10-04), so sound and email are
            // carried over explicitly.
            guard let moved = alarm.copy() as? EKAlarm else { continue }
            moved.soundName = alarm.soundName
            moved.emailAddress = alarm.emailAddress
            moved.absoluteDate = moveInstant(alarm.absoluteDate!)
            reminder.removeAlarm(alarm)
            reminder.addAlarm(moved)
        }
        return Report(startDate: startChange, absoluteAlarmsShifted: absolute.count, absoluteAlarmsRemoved: 0)
    }

    private static func unchanged(_ reminder: EKReminder) -> Report {
        Report(startDate: reminder.startDateComponents == nil ? .absent : .unchanged,
               absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0)
    }

    private static func clear(_ reminder: EKReminder) -> Report {
        let hadStart = reminder.startDateComponents != nil
        reminder.startDateComponents = nil
        let absolute = (reminder.alarms ?? []).filter { $0.absoluteDate != nil }
        absolute.forEach(reminder.removeAlarm)
        return Report(startDate: hadStart ? .cleared : .absent, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: absolute.count)
    }

    /// Moves start components with the due date, keeping their time zone (floating stays
    /// floating) and granularity. A date-only start moves by calendar days counted in its own
    /// zone; a timed start moves like an alarm.
    private static func shift(_ components: DateComponents, from oldDue: Date, to newDue: Date,
                              moveInstant: (Date) -> Date) -> DateComponents? {
        let zone = components.timeZone ?? .current
        let cal = calendar(zone)
        var source = components
        source.calendar = nil
        source.timeZone = nil
        guard let date = cal.date(from: source) else { return nil }
        let moved: Date
        let units: Set<Calendar.Component>
        if components.hour == nil {
            let days = calendarDays(from: oldDue, to: newDue, in: zone)
            guard let byDays = cal.date(byAdding: .day, value: days, to: date) else { return nil }
            moved = byDays
            units = [.year, .month, .day]
        } else {
            moved = moveInstant(date)
            units = [.year, .month, .day, .hour, .minute]
        }
        var shifted = cal.dateComponents(units, from: moved)
        shifted.timeZone = components.timeZone
        return shifted
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    private static func calendarDays(from a: Date, to b: Date, in zone: TimeZone) -> Int {
        let cal = calendar(zone)
        return cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
    }
}
