import EventKit
import Foundation

/// #333: relative alarms on reminders (`alarms_minutes_offsets` on `create_reminder`,
/// `create_reminders_batch` and `update_reminder`; positive = minutes before the due date, the
/// sense of the event tools and of the read side's `minutes_before`).
///
/// Only the relative alarms are written: a replace removes the reminder's relative alarms and adds
/// the requested ones, `[]` removes them. Absolute-date alarms stay (Reminders.app shows the
/// earliest one as the reminder's date, #227, and they follow the due date through
/// `ReminderDateSync`), and so does the location alarm (#229). This differs from the event tools,
/// whose list replaces every alarm.
///
/// A relative alarm is anchored to the due date, so it is refused (nothing is written) when the
/// reminder will have no due date (it would never fire) or a date-only one: on a date-only
/// reminder EventKit stores it and reads it back, but when Reminders fires it, and from which
/// instant, was not measured (#333 step 0, 2026-11-05). `[]` is always allowed.
enum ReminderRelativeAlarms {
    enum DueState: Equatable { case none, dateOnly, timed }

    static let noDueMessage = "alarms_minutes_offsets needs a due date with a time: the reminder will have no due date, and a relative alarm without one never fires. Pass due_date with a time. Nothing was written."
    static let dateOnlyMessage = "alarms_minutes_offsets is not supported on a date-only reminder: when Reminders fires a relative alarm on a day without a time has not been measured (#333). Give due_date a time, or add the early reminder in Reminders.app. Nothing was written."

    /// A due with an hour is timed (`ReminderDateSync.timedDueComponents` always writes one); a
    /// due without one is a day (#267).
    static func dueState(of components: DateComponents?) -> DueState {
        guard let components else { return .none }
        return components.hour == nil ? .dateOnly : .timed
    }

    /// The due the reminder has after the call: the request's, none for `clear_due_date`, else
    /// the stored one.
    static func dueState(requested: ReminderDueInput?, clearDue: Bool, existing: DateComponents?) -> DueState {
        if clearDue { return .none }
        switch requested {
        case .timed?: return .timed
        case .day?: return .dateOnly
        case nil: return dueState(of: existing)
        }
    }

    static func check(_ offsets: [Int]?, due: DueState) throws {
        guard let offsets, !offsets.isEmpty else { return }
        switch due {
        case .timed: return
        case .none: throw ToolError.invalidParameter(noDueMessage)
        case .dateOnly: throw ToolError.invalidParameter(dateOnlyMessage)
        }
    }

    /// Whether an alarm is relative: not a location alarm (which reads back with `absoluteDate`
    /// nil and `relativeOffset` 0, #231) and without an absolute date.
    static func isRelative(_ alarm: EKAlarm) -> Bool {
        alarm.structuredLocation == nil && alarm.absoluteDate == nil
    }

    static func replace(on item: EKCalendarItem, with offsets: [Int]) {
        for alarm in item.alarms ?? [] where isRelative(alarm) {
            item.removeAlarm(alarm)
        }
        for offset in offsets {
            // In Double, so a huge value cannot trap the Int multiply.
            item.addAlarm(EKAlarm(relativeOffset: -Double(offset) * 60))
        }
    }

    /// The stored relative alarms as minutes before the due date, earliest first (the read side's
    /// order); a non-finite offset is left out, as there.
    static func storedMinutesBefore(_ item: EKCalendarItem) -> [Double] {
        (item.alarms ?? []).filter(isRelative).map(\.relativeOffset).filter(\.isFinite)
            .sorted().map { -$0 / 60 + 0 }
    }

    static func differs(requested: [Int], stored: [Double]) -> Bool {
        requested.map(Double.init).sorted() != stored.sorted()
    }
}
