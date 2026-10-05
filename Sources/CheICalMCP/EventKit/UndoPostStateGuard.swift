import EventKit
import Foundation

/// #236 — the post-state guard. An undo record used to keep only the state *before* the write
/// (or just an identifier), so undo wrote over whatever was there, including a change made
/// elsewhere after the write. Each record now also keeps the state the write *left*, and before
/// an undo or redo writes, the item is compared with it: the fields the undo would write must
/// still hold the recorded values (diagnosis D1). A field projection rather than
/// `lastModifiedDate`, because undoing a later write restores exactly the state an earlier one
/// left, which a modification stamp never matches again.
///
/// Pure apart from reading EventKit objects, and free of `CheMCPKit`, so a standalone probe can
/// compile this file as is. The manager side (resolve, `refresh()`, throw) is in
/// `EventKitManager+UndoGuard.swift`; the refusal error is `UndoTargetChangedError`.
enum UndoHistoryVerb: String, Sendable {
    case undo, redo
}

/// What an undo or redo must find before it writes.
enum UndoPostState {
    enum Kind: String, Sendable { case event, reminder }

    /// The event as the write left it. `restoring` is the snapshot an update-undo writes back;
    /// `nil` when the undo deletes the event, so every recorded field counts.
    case event(id: String, title: String, state: EventSnapshot, restoring: EventSnapshot?)
    /// The calendar an in-place move left the event in; a move-undo writes only the calendar.
    case eventCalendar(id: String, title: String, calendarIdentifier: String)
    /// The reminder as the write left it; reminder undo writes every recorded field.
    case reminder(id: String, title: String, state: ReminderSnapshot)
    /// A completion write: the flag, and the instant when it was recorded.
    case reminderCompletion(id: String, title: String, isCompleted: Bool, completionDate: Date?)

    var kind: Kind {
        switch self {
        case .event, .eventCalendar: return .event
        case .reminder, .reminderCompletion: return .reminder
        }
    }

    var itemID: String {
        switch self {
        case .event(let id, _, _, _), .eventCalendar(let id, _, _),
             .reminder(let id, _, _), .reminderCompletion(let id, _, _, _):
            return id
        }
    }

    var title: String {
        switch self {
        case .event(_, let title, _, _), .eventCalendar(_, let title, _),
             .reminder(_, let title, _), .reminderCompletion(_, let title, _, _):
            return title
        }
    }

    /// Names of the fields in which `item` no longer holds the recorded state; empty when the
    /// undo may write. Field names are the tool parameter names, author-controlled.
    func changedFields(in item: EKCalendarItem) -> [String] {
        switch self {
        case .event(_, _, let state, let restoring):
            guard let event = item as? EKEvent else { return ["item_type"] }
            return state.changedFields(in: EventSnapshot(from: event), restoring: restoring)
        case .eventCalendar(_, _, let calendarIdentifier):
            return item.calendar?.calendarIdentifier == calendarIdentifier ? [] : ["calendar"]
        case .reminder(_, _, let state):
            guard let reminder = item as? EKReminder else { return ["item_type"] }
            return state.changedFields(in: ReminderSnapshot(from: reminder))
        case .reminderCompletion(_, _, let isCompleted, let completionDate):
            guard let reminder = item as? EKReminder else { return ["item_type"] }
            if reminder.isCompleted != isCompleted { return ["completed"] }
            // An instant the record never observed (a write that stamped "now") cannot be compared.
            if isCompleted, let completionDate, !Self.sameInstant(completionDate, reminder.completionDate) {
                return ["completion_date"]
            }
            return []
        }
    }

    /// Instants are compared to the second: a completion instant comes from `now` and carries
    /// sub-second digits a synced store need not keep, and the tools write whole seconds.
    static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1
        default: return false
        }
    }

    /// Alarms come back from EventKit in no fixed order, so they are compared as a multiset,
    /// with the equality `AlarmSnapshot.restore` uses.
    static func sameAlarms(_ a: [AlarmSnapshot], _ b: [AlarmSnapshot]) -> Bool {
        func counts(_ alarms: [AlarmSnapshot]) -> [AlarmSnapshot: Int] {
            alarms.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        return counts(a) == counts(b)
    }
}

extension EventSnapshot {
    /// The fields of this recorded state that differ in `current`, limited to what the undo
    /// writes (D1). `target` is the snapshot an update-undo restores; `nil` means the undo
    /// deletes the event, so every recorded field counts.
    ///
    /// The structured location is always compared: `apply` writes `location` unconditionally,
    /// and EventKit couples the two (a new location string replaces the place, `nil` clears it;
    /// checked in memory), so the place round-trips. Recurrence is compared only when this state
    /// recorded rules and, for an update-undo, the restored snapshot did too: `apply` leaves the
    /// rules alone otherwise.
    func changedFields(in current: EventSnapshot, restoring target: EventSnapshot?) -> [String] {
        var changed: [String] = []
        func check(_ field: String, _ same: Bool) {
            if !same { changed.append(field) }
        }
        check("title", title == current.title)
        check("start_time", UndoPostState.sameInstant(startDate, current.startDate))
        check("end_time", UndoPostState.sameInstant(endDate, current.endDate))
        check("all_day", isAllDay == current.isAllDay)
        check("calendar", calendarIdentifier == current.calendarIdentifier)
        check("notes", notes == current.notes)
        check("location", location == current.location)
        check("url", url?.absoluteString == current.url?.absoluteString)
        check("timezone", timeZone?.identifier == current.timeZone?.identifier)
        check("alarms", UndoPostState.sameAlarms(alarms, current.alarms))
        check("structured_location", structuredLocationTitle == current.structuredLocationTitle
              && structuredLocationLat == current.structuredLocationLat
              && structuredLocationLon == current.structuredLocationLon
              && structuredLocationRadius == current.structuredLocationRadius)
        if let rules = recurrenceRules, target == nil || target?.recurrenceRules != nil {
            check("recurrence", rules == (current.recurrenceRules ?? []))
        }
        return changed
    }
}

extension ReminderSnapshot {
    /// The fields of this recorded state that differ in `current`. Reminder undo writes every
    /// recorded field (`apply(to:now:)` plus the list), so all of them count. A changed
    /// completion flag is reported alone; the instant is compared only when the flag matches.
    func changedFields(in current: ReminderSnapshot) -> [String] {
        var changed: [String] = []
        func check(_ field: String, _ same: Bool) {
            if !same { changed.append(field) }
        }
        check("title", title == current.title)
        check("list", calendarIdentifier == current.calendarIdentifier)
        check("notes", notes == current.notes)
        if isCompleted != current.isCompleted {
            changed.append("completed")
        } else {
            check("completion_date", UndoPostState.sameInstant(completionDate, current.completionDate))
        }
        check("priority", priority == current.priority)
        check("due_date", Self.sameDateComponents(dueDateComponents, current.dueDateComponents))
        check("start_date", Self.sameDateComponents(startDateComponents, current.startDateComponents))
        check("alarms", UndoPostState.sameAlarms(alarms, current.alarms))
        check("recurrence", recurrenceRules == current.recurrenceRules)
        check("url", url?.absoluteString == current.url?.absoluteString)
        return changed
    }

    /// Through `ReminderDueValue`, which drops the week / weekday fields EventKit can attach
    /// after a save without changing the date. Components it cannot normalise (no year, month
    /// or day) are compared as they are.
    static func sameDateComponents(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            if let left = ReminderDueValue(components: a), let right = ReminderDueValue(components: b) {
                return left == right
            }
            return a == b
        default:
            return false
        }
    }
}
