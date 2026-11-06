import EventKit
import Foundation

/// #333: relative alarms on reminders (`alarms_minutes_offsets` on `create_reminder`,
/// `create_reminders_batch` and `update_reminder`; positive = minutes before the due date, the
/// sense of the event tools and of the read side's `minutes_before`).
///
/// Only the relative alarms are written: a replace removes the reminder's relative alarms and adds
/// the requested ones, `[]` removes them. Absolute-date alarms stay (#227: they follow the due date
/// through `ReminderDateSync`), and so does the location alarm (#229). This differs from the event tools,
/// whose list replaces every alarm.
///
/// A relative alarm is anchored to the due date, so it is refused (nothing is written) when the
/// reminder will have no due date (it would never fire) or a date-only one: on a date-only
/// reminder EventKit stores it and reads it back, but when Reminders fires it, and from which
/// instant, was not measured (#333 step 0, 2026-11-05). `[]` is always allowed.
///
/// #433: alarms change what the Reminders.app list shows. In the 14 rows measured (2026-11-05) the
/// row showed the earliest time-based alarm of either kind, so 15:30 with `[15]` read 15:15 and with
/// `[-15]` read 15:45, while the stored due date stayed 15:30. That is a fit to those rows, not a
/// documented rule. The rows that showed the due time have no alarm before it; firing was not
/// checked on any of them. #333's one notification check (due 09:54, `[2]`, 2026-11-05) came early
/// and its banner read 09:52; no second banner was seen at the due time, with the first one still on
/// screen. The one Early Reminder made by hand read back with one absolute alarm at the due time, so
/// EventKit did not show it. The offsets stay; `alarmDisplayNote` says this.
enum ReminderRelativeAlarms {
    /// In `alarms_note` and in each tool's `alarms_minutes_offsets` description.
    static let alarmDisplayNote = "The alarm does not change the due date, but in the rows measured the Reminders.app list showed the earliest alarm time instead of the due time, so it can read earlier or later than the due time. In the one notification check, with a future due date and [2], the notification came early and its banner showed that same alarm time; no second banner was seen at the due time, though the first was still on screen, so one behind it cannot be excluded. An Early Reminder set in Reminders.app is different: the one made by hand read back with no alarm before the due time, so this server cannot write it."

    /// When `alarmDisplayNote` appears, as the tool descriptions state it.
    static let alarmNoteCondition = "When the earliest time-based alarm, relative or absolute, is not at the timed due time, alarms_note speaks up. Measured list rows: [15], [60], [2], [15, 0], [0], [-15], absolute alarms at or before the due time, and [15] with an absolute alarm at the due time. Every other shape is inferred from them, and they cannot decide [0, -15], which gets no note for now. The note says:"

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

    /// #433: whether the earliest time-based alarm, of either kind, is off `due`, so the list shows
    /// that alarm's time and not the due time (PR #438 verify: absolute alarms stay on the reminder
    /// and count too). `[0, -15]` is false: the measured rows cannot tell whether its list shows the
    /// due time or the later alarm, so there is no note until release gate step 8 decides. If it
    /// shows the later alarm, the rule is "the earliest alarm off the due time" and this changes for
    /// every shape with an alarm at the due time and a later one.
    static func listShowsAlarmTime(due: Date?, alarms: [ReminderReadSnapshot.Alarm]) -> Bool {
        guard let due else { return false }
        let instants = alarms.compactMap { alarm -> Date? in
            switch alarm {
            case .absolute(let date): return date
            case .relative(let seconds): return seconds.isFinite ? due.addingTimeInterval(seconds) : nil
            }
        }
        guard let earliest = instants.min() else { return false }
        return abs(earliest.timeIntervalSince(due)) >= 1
    }

    /// On a saved reminder. Only with a timed due: a date-only or undated reminder has no due time
    /// to compare with. On a date-only reminder #267 measured that the app goes on showing an
    /// absolute alarm's time; that gets no note here (documented), and neither does a relative
    /// alarm there, whose display was not measured (the leftover note speaks when the due changes).
    static func listShowsAlarmTime(saved reminder: EKReminder) -> Bool {
        guard dueState(of: reminder.dueDateComponents) == .timed else { return false }
        // `safeDateFromComponents`, as `date_sync` compares them: a due without a zone is in the host zone.
        return listShowsAlarmTime(due: safeDateFromComponents(reminder.dueDateComponents),
                                  alarms: AlarmReadOutput.timeBased(reminder.alarms))
    }

    /// PR #438 verify: an update reports the list time when it touches the alarms or the due date.
    /// A title change says nothing, and `clear_due_date` leaves no due time.
    static func reportsListTime(_ request: ReminderUpdateRequest) -> Bool {
        request.alarmOffsets != nil || request.due != nil || request.realignToDue
    }

    static func differs(requested: [Int], stored: [Double]) -> Bool {
        requested.map(Double.init).sorted() != stored.sorted()
    }

    /// PR #415 verify round 1: an update that makes the reminder undated or date-only (a bare
    /// `due_date` or `clear_due_date`) without `alarms_minutes_offsets` keeps its relative alarms
    /// (#267), which then cannot fire as before. Nothing is written differently; the response
    /// says so, with the way to remove them.
    static func leftoverNote(requested: [Int]?, dueTouched: Bool, dueAfter: DueState, relativeCount: Int) -> String? {
        guard requested == nil, dueTouched, relativeCount > 0 else { return nil }
        switch dueAfter {
        case .timed: return nil
        case .none: return leftoverNoDueNote(relativeCount)
        case .dateOnly: return leftoverDateOnlyNote(relativeCount)
        }
    }

    static func leftoverNoDueNote(_ count: Int) -> String {
        "The reminder keeps \(count) relative alarm\(count == 1 ? "" : "s"), measured from the due date; without a due date they never fire. To remove them, call update_reminder with alarms_minutes_offsets: []."
    }

    static func leftoverDateOnlyNote(_ count: Int) -> String {
        "The reminder keeps \(count) relative alarm\(count == 1 ? "" : "s"), measured from the due date; on a date-only reminder when they fire has not been measured (#333). To remove them, call update_reminder with alarms_minutes_offsets: []."
    }

    /// The note for a saved reminder, as `updateReminder` reports it (PR #415 verify round 2): the
    /// due state and relative alarms are read off the saved reminder, and the due counts as touched
    /// when the request gave a due date or `clear_due_date`. So a timed `due_date` that the store
    /// kept only as a day (the #237 fallback that did not take) gets the date-only note too (round
    /// 3). After `clear_due_date` the reminder is not re-read (`ReminderDateSync.confirmSaved`
    /// returns early when no due was written), so that count is the in-memory one after the save.
    /// PR #438 verify: after a reload that failed nothing is counted; `date_sync.aligned` is false.
    static func leftoverNote(saved reminder: EKReminder, request: ReminderUpdateRequest,
                             dateSync: ReminderDateSync.Report? = nil) -> String? {
        guard dateSync?.reread != false else { return nil }
        return leftoverNote(requested: request.alarmOffsets, dueTouched: request.due != nil || request.clearDueDate,
                     dueAfter: dueState(of: reminder.dueDateComponents),
                     relativeCount: storedMinutesBefore(reminder).count)
    }
}
