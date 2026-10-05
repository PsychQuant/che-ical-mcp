import EventKit
import Foundation

/// #236 — which fields the post-state guard compares, and how. A field blocks an undo when it
/// changed since the write and is not already at the value the undo writes (`restoring`); a
/// delete (`restoring == nil`) has no value to write, so every compared field that changed counts.
///
/// - An update-undo compares the fields its restore writes (diagnosis D1); it restores only
///   one-off events, so recurrence is not among them (round 5).
/// - A create-undo deletes the item, so it compares every recorded field, the calendar or list
///   and the alarms included (PR #259 round 2, finding 1).
/// - Changes a calendar app or server makes on its own are not edits: an alarm sound, and
///   coordinates added to a place recorded without them. Neither blocks an undo, and an
///   update-undo then overwrites them with the recorded values. Dates compare to the second, due
///   and start components by the moment (or day) they name, recurrence rules as sets.
extension EventSnapshot {
    func changedFields(in current: EventSnapshot, restoring target: EventSnapshot?) -> [String] {
        var changed: [String] = []
        func check(_ name: String, _ same: (EventSnapshot, EventSnapshot) -> Bool) {
            guard !same(self, current) else { return }
            if let target, same(target, current) { return }
            changed.append(name)
        }
        check("title") { $0.title == $1.title }
        check("start_time") { UndoPostState.sameInstant($0.startDate, $1.startDate) }
        check("end_time") { UndoPostState.sameInstant($0.endDate, $1.endDate) }
        check("all_day") { $0.isAllDay == $1.isAllDay }
        check("calendar") { $0.calendarIdentifier == $1.calendarIdentifier }
        check("notes") { $0.notes == $1.notes }
        check("location") { $0.location == $1.location }
        check("url") { $0.url?.absoluteString == $1.url?.absoluteString }
        check("timezone") { $0.timeZone?.identifier == $1.timeZone?.identifier }
        check("alarms") { UndoPostState.sameAlarms($0.alarms, $1.alarms) }
        // `apply` writes `location` unconditionally, and EventKit couples it with the place (a new
        // string replaces the place, `nil` clears it; checked in memory), so the place round-trips.
        check("structured_location") { Self.samePlace(recorded: $0, current: $1) }
        // A delete removes the rules with the item, so create-undo compares them; no rules and nil
        // are the same (verify #2 / #6). Update-undo restores only one-off events (PR #259 round 5:
        // an update that touched a recurring event is a marker, and the update arm refuses an
        // event that repeats at undo time before this comparison), so it never compares them.
        if target == nil {
            check("recurrence") { RecurrenceRuleSnapshot.sameRules($0.recurrenceRules, $1.recurrenceRules, allDay: $0.isAllDay) }
        }
        return changed
    }

    /// A place recorded without coordinates that later has them under the same name was geocoded
    /// by the calendar app or server, not edited.
    static func samePlace(recorded: EventSnapshot, current: EventSnapshot) -> Bool {
        guard recorded.structuredLocationTitle == current.structuredLocationTitle else { return false }
        guard recorded.structuredLocationLat != nil, recorded.structuredLocationLon != nil else { return true }
        return recorded.structuredLocationLat == current.structuredLocationLat
            && recorded.structuredLocationLon == current.structuredLocationLon
            && recorded.structuredLocationRadius == current.structuredLocationRadius
    }
}

extension ReminderSnapshot {
    func changedFields(in current: ReminderSnapshot, restoring target: ReminderSnapshot?) -> [String] {
        var changed: [String] = []
        func check(_ name: String, _ same: (ReminderSnapshot, ReminderSnapshot) -> Bool) {
            guard !same(self, current) else { return }
            if let target, same(target, current) { return }
            changed.append(name)
        }
        check("title") { $0.title == $1.title }
        check("list") { $0.calendarIdentifier == $1.calendarIdentifier }
        check("notes") { $0.notes == $1.notes }
        // The flag and the instant are one value, so a reminder completed again at another time
        // is not mistaken for "already restored"; the name says which part moved.
        check(isCompleted == current.isCompleted ? "completion_date" : "completed") { $0.completion.matches($1.completion) }
        check("priority") { $0.priority == $1.priority }
        check("due_date") { Self.sameDateComponents($0.dueDateComponents, $1.dueDateComponents) }
        check("start_date") { Self.sameDateComponents($0.startDateComponents, $1.startDateComponents) }
        check("alarms") { UndoPostState.sameAlarms($0.alarms, $1.alarms) }
        check("recurrence") { RecurrenceRuleSnapshot.sameRules($0.recurrenceRules, $1.recurrenceRules, allDay: false) }
        check("url") { $0.url?.absoluteString == $1.url?.absoluteString }
        return changed
    }

    var completion: UndoPostState.CompletionState {
        UndoPostState.CompletionState(isCompleted: isCompleted, completionDate: completionDate)
    }

    /// Compared by what the components name, not how they are written: EventKit can attach
    /// derived week / weekday fields after a save, and a store can write the same moment with
    /// another time-zone representation (verify #7). A date-only value compares by its day; a
    /// timed one by its moment, to the second. Date-only never equals timed.
    static func sameDateComponents(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            guard (a.hour == nil) == (b.hour == nil) else { return false }
            if a.hour == nil { return a.year == b.year && a.month == b.month && a.day == b.day }
            guard let left = moment(a), let right = moment(b) else { return a == b }
            return UndoPostState.sameInstant(left, right)
        default:
            return false
        }
    }

    /// A floating value (no time zone) is read in the current zone, as EventKit shows it.
    private static func moment(_ components: DateComponents) -> Date? {
        var calendar = Calendar(identifier: components.calendar?.identifier ?? .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        var wall = DateComponents()
        wall.era = components.era
        wall.year = components.year
        wall.month = components.month
        wall.day = components.day
        wall.hour = components.hour
        wall.minute = components.minute
        wall.second = components.second
        return calendar.date(from: wall)
    }
}

extension RecurrenceRuleSnapshot {
    /// Rule lists compare as a multiset, with no rules and nil the same (verify #2, #11).
    static func sameRules(_ a: [RecurrenceRuleSnapshot]?, _ b: [RecurrenceRuleSnapshot]?, allDay: Bool) -> Bool {
        var unmatched = b ?? []
        for rule in a ?? [] {
            guard let index = unmatched.firstIndex(where: { rule.isSameRule(as: $0, allDay: allDay) }) else { return false }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }

    /// The day lists compare as sets (EventKit and CalDAV keep no fixed order), the end to the
    /// second, or to the day for an all-day event (CalDAV can store its end as a date).
    func isSameRule(as other: RecurrenceRuleSnapshot, allDay: Bool) -> Bool {
        func set<T: Hashable>(_ values: [T]?) -> Set<T> { Set(values ?? []) }
        return frequency == other.frequency
            && interval == other.interval
            && firstDayOfTheWeek == other.firstDayOfTheWeek
            && occurrenceCount == other.occurrenceCount
            && set(daysOfTheWeek?.map { "\($0.day):\($0.weekNumber)" }) == set(other.daysOfTheWeek?.map { "\($0.day):\($0.weekNumber)" })
            && set(daysOfTheMonth) == set(other.daysOfTheMonth)
            && set(monthsOfTheYear) == set(other.monthsOfTheYear)
            && set(weeksOfTheYear) == set(other.weeksOfTheYear)
            && set(daysOfTheYear) == set(other.daysOfTheYear)
            && set(setPositions) == set(other.setPositions)
            && Self.sameEnd(endDate, other.endDate, allDay: allDay)
    }

    private static func sameEnd(_ a: Date?, _ b: Date?, allDay: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return allDay ? Calendar.current.isDate(a, inSameDayAs: b) : UndoPostState.sameInstant(a, b)
        default: return false
        }
    }
}

extension UndoPostState {
    /// An alarm as the guard compares it: the sound is left out (a server may set a default one),
    /// and an absolute date compares to the second, like every other date the guard compares.
    struct AlarmKey {
        let absoluteDate: Date?
        let relativeOffset: TimeInterval
        let location: AlarmSnapshot.Location?
        let proximity: EKAlarmProximity
        let emailAddress: String?

        func matches(_ other: AlarmKey) -> Bool {
            UndoPostState.sameInstant(absoluteDate, other.absoluteDate) && relativeOffset == other.relativeOffset
                && location == other.location && proximity == other.proximity && emailAddress == other.emailAddress
        }
    }

    /// Alarms come back from EventKit in no fixed order, so they compare as a multiset.
    static func sameAlarms(_ a: [AlarmSnapshot], _ b: [AlarmSnapshot]) -> Bool {
        func keys(_ alarms: [AlarmSnapshot]) -> [AlarmKey] {
            alarms.map { AlarmKey(absoluteDate: $0.absoluteDate, relativeOffset: $0.relativeOffset, location: $0.location,
                                  proximity: $0.proximity, emailAddress: $0.emailAddress) }
        }
        return sameAlarmKeys(keys(a), keys(b))
    }

    static func sameAlarmKeys(_ a: [AlarmKey], _ b: [AlarmKey]) -> Bool {
        var unmatched = b
        for key in a {
            guard let index = unmatched.firstIndex(where: { $0.matches(key) }) else { return false }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }
}
