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
/// How things move (verify rounds 1 and 2):
/// - The number of calendar days the due date moved is counted from the stored
///   year/month/day of the old and new due components, so zones never shift it by one.
/// - A date-only start date moves by that many calendar days.
/// - With a timed old due, alarms and a timed start move by the difference between the two
///   stored due instants, so an alarm on the old due lands exactly on the new one, including
///   across a daylight-saving change.
/// - With a date-only old due (midnight), they move by whole calendar days and keep their time.
/// Relative-offset and location alarms are never touched.
///
/// The due date is written last. On a floating reminder the item is then given the due's
/// zone, so a timed due keeps the explicit zone #134 writes (#237; `writeZonedDue` records
/// the on-device findings behind this order).
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
        let hadDue = oldComponents != nil
        let oldIsDateOnly = hadDue && oldComponents?.hour == nil
        guard let newDue else {
            let report = sync(reminder, from: oldDue, to: nil, hadDueDate: hadDue)
            reminder.dueDateComponents = nil
            return report
        }
        // #134: always store an explicit time zone so iCloud Web / Today view don't
        // re-interpret floating components as UTC.
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: newDue)
        components.timeZone = TimeZone.current
        // Shift by what will be stored (minute precision), not the raw input (verify #3).
        let storedDue = safeDateFromComponents(components) ?? newDue
        // Start and alarms move FIRST, the due date is written LAST: EventKit couples start and
        // due (in memory, writing a date-only start turns the due date date-only), so writing
        // the start after the due date could drop the time the caller asked for.
        let report = sync(reminder, from: oldDue, to: storedDue, oldDueIsDateOnly: oldIsDateOnly,
                          dueDayShift: dayShift(from: oldComponents, to: components), hadDueDate: hadDue)
        writeZonedDue(reminder, components)
        return report
    }

    /// #237: writes a timed due date so that it keeps an explicit zone (#134).
    ///
    /// A reminder has one item-level zone (`EKCalendarItem.timeZone`) shared by its start and
    /// due dates. On a floating item (`timeZone == nil`) a due written with a zone is stored
    /// floating, keeping its wall clock, so the item is given the due's zone after the write.
    /// Found on device (2026-10-05, saved and re-fetched):
    /// - giving the start a zone before the due is written does not help: the due stays floating;
    /// - setting `reminder.timeZone` after the due is written keeps both wall clocks and zones both;
    /// - on an item that already has a zone, assigning another one moves its instants, while a
    ///   due written in another zone is converted and keeps its instant, so a zoned item is left
    ///   alone;
    /// - in memory, assigning the zone while the start has no hour turns the due date-only, so
    ///   such a start first gets `00:00` (the store already hands date-only starts back that way).
    private static func writeZonedDue(_ reminder: EKReminder, _ components: DateComponents) {
        let floating = reminder.timeZone == nil
        if floating, var start = reminder.startDateComponents, start.hour == nil {
            start.hour = 0
            start.minute = 0
            reminder.startDateComponents = start
        }
        reminder.dueDateComponents = components
        if floating {
            reminder.timeZone = components.timeZone
        }
        if dueLostTimeOrZone(reminder.dueDateComponents) {
            writeDueAroundStart(reminder, due: components)
        }
    }

    /// Whether a timed due date read back without its time or its zone.
    static func dueLostTimeOrZone(_ due: DateComponents?) -> Bool {
        due?.hour == nil || due?.timeZone == nil
    }

    /// The fallback when the zone did not stick: clear the start, write the due (EventKit then
    /// zones the item from it), and put the start back timed, in the due's zone, with its wall
    /// clock unchanged. This order kept both zoned on device; a date-only start written after
    /// the due would turn the due date-only, so the start is always written with a time.
    static func writeDueAroundStart(_ reminder: EKReminder, due components: DateComponents) {
        let start = reminder.startDateComponents
        reminder.startDateComponents = nil
        reminder.dueDateComponents = components
        guard var start else { return }
        start.calendar = nil
        if start.hour == nil {
            start.hour = 0
            start.minute = 0
        }
        if start.timeZone == nil {
            start.timeZone = components.timeZone
        }
        reminder.startDateComponents = start
    }

    /// - Parameters:
    ///   - oldDue: the due instant before the update, or `nil` if the reminder had none.
    ///   - newDue: the due instant after the update, or `nil` when the due date is cleared.
    ///   - oldDueIsDateOnly: the old due had no time of day; alarms and a timed start then move
    ///     by whole calendar days and keep their time.
    ///   - dueDayShift: calendar days the due date moved, from the stored components. When nil
    ///     it is counted from the two instants in the current zone.
    ///   - hadDueDate: whether a due date existed, which decides whether clearing is a no-op.
    ///     When nil it is taken from `oldDue`.
    static func sync(_ reminder: EKReminder, from oldDue: Date?, to newDue: Date?,
                     oldDueIsDateOnly: Bool = false, dueDayShift: Int? = nil,
                     hadDueDate: Bool? = nil) -> Report {
        guard let newDue else {
            // Clearing a due date that does not exist is a no-op (verify #4, round 2 #3).
            guard hadDueDate ?? (oldDue != nil) else { return unchanged(reminder) }
            return clear(reminder)
        }
        guard let oldDue else { return unchanged(reminder) }
        let days = dueDayShift ?? calendarDays(from: oldDue, to: newDue, in: .current)

        let moveAlarm: (Date) -> Date
        let moveTimedStart: (Date, TimeZone) -> Date
        if oldDueIsDateOnly {
            moveAlarm = { Self.add(days, to: $0, in: .current) }
            moveTimedStart = { Self.add(days, to: $0, in: $1) }
        } else {
            let delta = newDue.timeIntervalSince(oldDue)
            moveAlarm = { $0.addingTimeInterval(delta) }
            moveTimedStart = { date, _ in date.addingTimeInterval(delta) }
        }

        var startChange = StartChange.absent
        if let start = reminder.startDateComponents {
            let shifted = shift(start, days: days, moveTimed: moveTimedStart)
            if let shifted, !sameValue(shifted, start) {
                reminder.startDateComponents = shifted
                startChange = .shifted
            } else {
                startChange = .unchanged
            }
        }

        var moved = 0
        for alarm in (reminder.alarms ?? []) {
            guard let date = alarm.absoluteDate else { continue }
            let target = moveAlarm(date)
            guard target != date else { continue }
            // Copy, then change only the date, so the alarm's other settings survive (verify #6).
            // `EKAlarm.copy()` drops `soundName` (checked 2026-10-04), so sound and email are
            // carried over explicitly; if the copy fails a fresh alarm carries them instead.
            let replacement = (alarm.copy() as? EKAlarm) ?? EKAlarm(absoluteDate: target)
            replacement.soundName = alarm.soundName
            replacement.emailAddress = alarm.emailAddress
            replacement.absoluteDate = target
            reminder.removeAlarm(alarm)
            reminder.addAlarm(replacement)
            moved += 1
        }
        return Report(startDate: startChange, absoluteAlarmsShifted: moved, absoluteAlarmsRemoved: 0)
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

    /// Moves start components with the due date, keeping their time zone and granularity. A
    /// floating start stays floating here; when `setDue` then writes a timed due it zones the
    /// whole item (#237). A date-only start moves by `days` calendar days; a timed start moves
    /// like an alarm, in its own zone.
    private static func shift(_ components: DateComponents, days: Int,
                              moveTimed: (Date, TimeZone) -> Date) -> DateComponents? {
        let zone = components.timeZone ?? .current
        let cal = calendar(zone)
        var source = components
        source.calendar = nil
        source.timeZone = nil
        guard let date = cal.date(from: source) else { return nil }
        let isDateOnly = components.hour == nil
        let moved = isDateOnly ? add(days, to: date, in: zone) : moveTimed(date, zone)
        var shifted = cal.dateComponents(isDateOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: moved)
        shifted.timeZone = components.timeZone
        return shifted
    }

    /// Calendar days between the stored year/month/day of two due components (not instants).
    static func dayShift(from old: DateComponents?, to new: DateComponents?) -> Int? {
        guard let old, let new,
              let oy = old.year, let om = old.month, let od = old.day,
              let ny = new.year, let nm = new.month, let nd = new.day else { return nil }
        let utc = calendar(TimeZone(identifier: "UTC")!)
        guard let a = utc.date(from: DateComponents(year: oy, month: om, day: od, hour: 12)),
              let b = utc.date(from: DateComponents(year: ny, month: nm, day: nd, hour: 12)) else { return nil }
        return utc.dateComponents([.day], from: a, to: b).day
    }

    private static func sameValue(_ a: DateComponents, _ b: DateComponents) -> Bool {
        a.year == b.year && a.month == b.month && a.day == b.day && a.hour == b.hour
            && a.minute == b.minute && a.timeZone == b.timeZone
    }

    private static func add(_ days: Int, to date: Date, in zone: TimeZone) -> Date {
        calendar(zone).date(byAdding: .day, value: days, to: date) ?? date
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
