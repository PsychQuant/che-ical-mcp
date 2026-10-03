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

    /// - Parameters:
    ///   - oldDue: the due instant before the update, or `nil` if the reminder had none.
    ///   - newDue: the due instant after the update, or `nil` when the due date is cleared.
    static func sync(_ reminder: EKReminder, from oldDue: Date?, to newDue: Date?) -> Report {
        guard let newDue else { return clear(reminder) }
        guard let oldDue, newDue != oldDue else {
            return Report(startDate: reminder.startDateComponents == nil ? .absent : .unchanged,
                          absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0)
        }
        let delta = newDue.timeIntervalSince(oldDue)

        var startChange = StartChange.absent
        if let start = reminder.startDateComponents {
            if let shifted = shift(start, by: delta) {
                reminder.startDateComponents = shifted
                startChange = .shifted
            } else {
                startChange = .unchanged
            }
        }

        let absolute = (reminder.alarms ?? []).filter { $0.absoluteDate != nil }
        for alarm in absolute {
            reminder.removeAlarm(alarm)
            reminder.addAlarm(EKAlarm(absoluteDate: alarm.absoluteDate!.addingTimeInterval(delta)))
        }
        return Report(startDate: startChange, absoluteAlarmsShifted: absolute.count, absoluteAlarmsRemoved: 0)
    }

    private static func clear(_ reminder: EKReminder) -> Report {
        let hadStart = reminder.startDateComponents != nil
        reminder.startDateComponents = nil
        let absolute = (reminder.alarms ?? []).filter { $0.absoluteDate != nil }
        absolute.forEach(reminder.removeAlarm)
        return Report(startDate: hadStart ? .cleared : .absent, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: absolute.count)
    }

    /// Moves `components` by `delta` seconds, keeping its time zone (floating stays floating)
    /// and its granularity (a date-only start stays date-only).
    private static func shift(_ components: DateComponents, by delta: TimeInterval) -> DateComponents? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        var source = components
        source.calendar = nil
        source.timeZone = nil
        guard let date = calendar.date(from: source) else { return nil }
        let units: Set<Calendar.Component> = components.hour == nil
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute]
        var shifted = calendar.dateComponents(units, from: date.addingTimeInterval(delta))
        shifted.timeZone = components.timeZone
        return shifted
    }
}
