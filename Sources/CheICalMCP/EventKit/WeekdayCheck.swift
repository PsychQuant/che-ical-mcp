import EventKit
import Foundation

/// #5 / #373 verify round 2: the zone in which `update_event` reads the weekday of the planned
/// start when it checks a recurrence's days.
enum WeekdayCheck {
    /// #454: whether a series' stored `days_of_week` count when `update_event` moves its start with
    /// no `recurrence` in the call. A move of the series (span all or future) off the days left a
    /// stray occurrence, or on a monthly rule a rewritten weekday (measured on iCloud). Moving one
    /// occurrence of a non-weekly series is not refused, measured on a daily series; a weekly one
    /// is refused, as it was.
    static func storedDaysCount(isWeekly: Bool, span: EKSpan) -> Bool {
        isWeekly || span != .thisEvent
    }

    /// #454: the days the start has to fall on, nil when none apply. A series already off its days,
    /// which older releases wrote, is not refused an update that leaves the day where it is: a time
    /// on the same day, a zone, or its own days again with a bound. A rule with other days is
    /// checked either way, since it is the rule that would be off. Its own days again are exempt only
    /// when the rule keeps the stored pattern (`ruleKeepsStoredPattern`: same frequency and interval,
    /// and a stored rule on plain weekdays); otherwise the call replaces the pattern and is checked
    /// (PR #462 verify round 2).
    static func daysToCheck(requested: [Int]?, ruleInCall: Bool, stored: [Int]?, storedCount: Bool,
                            ruleKeepsStoredPattern: Bool, startDayMoves: Bool) -> [Int]? {
        if ruleInCall {
            guard let requested, !requested.isEmpty else { return nil }
            if !startDayMoves, ruleKeepsStoredPattern, let stored, Set(stored) == Set(requested) { return nil }
            return requested
        }
        return startDayMoves && storedCount ? stored : nil
    }

    /// Whether a `recurrence` in the call keeps the stored rule's pattern: the same frequency and
    /// interval, over a stored rule on plain weekdays (`isNumberedRule` false). Only then can the
    /// same days be the series' own rule with another bound.
    static func keepsStoredPattern(frequency: RecurrenceRuleInput.Frequency, interval: Int,
                                   stored: EKRecurrenceFrequency, storedInterval: Int, storedNumbered: Bool) -> Bool {
        guard !storedNumbered, interval == storedInterval else { return false }
        switch frequency {
        case .daily: return stored == .daily
        case .weekly: return stored == .weekly
        case .monthly: return stored == .monthly
        case .yearly: return stored == .yearly
        }
    }

    /// Whether the calendar day of the start differs before and after the update, each read in its
    /// own zone. `clear_timezone` or `all_day` alone can change it with no `start_time`.
    static func dayChanges(from before: Date, in beforeZone: TimeZone?, to after: Date, in afterZone: TimeZone?, host: Calendar) -> Bool {
        func day(_ date: Date, _ zone: TimeZone?) -> DateComponents {
            var calendar = host
            if let zone { calendar.timeZone = zone }
            return calendar.dateComponents([.year, .month, .day], from: date)
        }
        return day(before, beforeZone) != day(after, afterZone)
    }

    /// A rule on a numbered weekday, "the first Monday", or by position, "the last weekday". The
    /// `recurrence` parameter takes plain weekdays, so it cannot write these.
    static func isNumberedRule(weekNumbers: [Int], setPositions: [Int]?) -> Bool {
        weekNumbers.contains { $0 != 0 } || setPositions?.isEmpty == false
    }

    static func names(weekday: Int, days: [Int]) -> (start: String, expected: String) {
        let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return (dayNames[weekday], days.compactMap { ($0 >= 1 && $0 <= 7) ? dayNames[$0] : nil }.joined(separator: ", "))
    }

    /// `create_event`: the start of a new rule has to fall on its `days_of_week`, on every frequency.
    static func createRefusal(rule: RecurrenceRuleInput?, start: Date, timezone: TimeZone?, host: Calendar) -> EventKitError? {
        guard let days = rule?.daysOfWeek, !days.isEmpty else { return nil }
        var calendar = host
        if let timezone { calendar.timeZone = timezone }
        let weekday = calendar.component(.weekday, from: start) // 1=Sun, 7=Sat
        guard !days.contains(weekday) else { return nil }
        let names = names(weekday: weekday, days: days)
        return .weekdayMismatch(startDay: names.start, expectedDays: names.expected)
    }

    /// The zone the event will have after the update; nil means the host zone.
    ///
    /// An all-day result has no zone: EventKit clears `timeZone` when `isAllDay` becomes true, and
    /// the check used to run after that assignment, so an all-day result was read in the host
    /// zone, the zone `AllDayRange.planUpdate` takes its midnights from. (A requested zone with an
    /// all-day result is refused before this check, #190.) A timed result takes the requested
    /// zone, else none when it is cleared, else the stored one.
    static func zone(resultIsAllDay: Bool, requested: TimeZone?, clearTimezone: Bool, stored: TimeZone?) -> TimeZone? {
        if resultIsAllDay { return nil }
        return requested ?? (clearTimezone ? nil : stored)
    }

    /// The weekday (1 = Sunday … 7 = Saturday) of `start` in that zone, else in `host`'s zone.
    static func weekday(of start: Date, resultIsAllDay: Bool, requested: TimeZone?, clearTimezone: Bool,
                        stored: TimeZone?, host: Calendar) -> Int {
        var calendar = host
        if let tz = zone(resultIsAllDay: resultIsAllDay, requested: requested, clearTimezone: clearTimezone, stored: stored) {
            calendar.timeZone = tz
        }
        return calendar.component(.weekday, from: start)
    }
}
