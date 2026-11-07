import EventKit
import Foundation

/// #461: the start of a monthly or yearly rule has to fall on its `days_of_month`, as on its
/// `days_of_week` (#454, `WeekdayCheck`). Measured on iCloud (2026-11-06): a monthly rule on
/// [15, 20] started on the 1st gave the 1st as a stray first occurrence, a yearly rule on [15] the
/// same, and moving a [1, 15] series to the 4th on span `all` made the 4th a day of the rule, with
/// no message. A daily or weekly rule stores a `days_of_month` but repeats as if it were not there,
/// and the parser refuses one there, so only monthly and yearly rules are checked.
enum MonthDayCheck {
    /// Whether `day` is one of `list`, where a negative entry counts from the end of the month
    /// (-1 is the last day), as a stored rule from Calendar can hold.
    static func contains(day: Int, daysInMonth: Int, list: [Int]) -> Bool {
        list.contains { $0 > 0 ? $0 == day : daysInMonth + $0 + 1 == day }
    }

    /// The day of the month of `start` in `zone` (the host zone when nil), and that month's length.
    static func day(of start: Date, zone: TimeZone?, host: Calendar) -> (day: Int, daysInMonth: Int) {
        var calendar = host
        if let zone { calendar.timeZone = zone }
        let day = calendar.component(.day, from: start)
        let length = calendar.range(of: .day, in: .month, for: start)?.count ?? 31
        return (day, length)
    }

    /// `create_event`: refused when a monthly or yearly rule's `days_of_month` do not hold the start.
    static func createRefusal(rule: RecurrenceRuleInput?, start: Date, timezone: TimeZone?, host: Calendar) -> EventKitError? {
        guard let rule, rule.frequency == .monthly || rule.frequency == .yearly,
              let days = rule.daysOfMonth, !days.isEmpty else { return nil }
        let start = day(of: start, zone: timezone, host: host)
        guard !contains(day: start.day, daysInMonth: start.daysInMonth, list: days) else { return nil }
        return .dayOfMonthMismatch(startDay: start.day, expectedDays: names(days))
    }

    /// Through an occurrence's own id the rule runs from the occurrence's original date (#416).
    static let occurrenceReason = "event_id names one occurrence of a recurring series, edited on its own, and days_of_month does not hold the day of the month of its original date, the day the series runs from. Add that day, or leave days_of_month out. Nothing was written."

    static func names(_ days: [Int]) -> String {
        days.map(String.init).joined(separator: ", ")
    }

    /// `update_event`: the days of the month the start has to fall on, nil when none apply, by the
    /// same rules as `WeekdayCheck.daysToCheck`. A rule in the call is checked unless it is the
    /// series' own pattern again (`ruleKeepsStoredPattern`) and the start's day stays. With no rule
    /// in the call, the series' own days count when the start's day moves on span `all` or `future`
    /// (moving one occurrence on span `this` was not measured and is not refused, as for a
    /// non-weekly rule in #454). `requested` is the call's `days_of_month`, which the parser takes on
    /// monthly and yearly rules only; `storedUsesMonthDays` is whether the stored rule is one of those.
    static func daysToCheck(requested: [Int]?, ruleInCall: Bool, stored: [Int]?, storedUsesMonthDays: Bool,
                            span: EKSpan, ruleKeepsStoredPattern: Bool, startDayMoves: Bool) -> [Int]? {
        if ruleInCall {
            guard let requested, !requested.isEmpty else { return nil }
            if !startDayMoves, ruleKeepsStoredPattern, let stored, Set(stored) == Set(requested) { return nil }
            return requested
        }
        guard startDayMoves, span != .thisEvent, storedUsesMonthDays, let stored, !stored.isEmpty else { return nil }
        return stored
    }
}
