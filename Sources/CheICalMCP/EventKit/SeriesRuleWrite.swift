import EventKit
import Foundation

/// #451: the `update_event` shapes that answered `updated` while occurrences went, refused before
/// anything is written. Measured on iCloud; the tables are on the issue. Undo refuses every update
/// of a recurring event, so nothing restores what went.
enum SeriesRuleWrite {
    /// The stored rule as these checks read it. Days of the week by their weekday number (Sunday 1,
    /// as `days_of_week` takes them); `hasOtherParts` holds what the input cannot write: a numbered
    /// weekday (the 2nd Tuesday), set positions, and months, weeks or days of the year.
    struct StoredRule: Equatable {
        let frequency: RecurrenceRuleInput.Frequency?
        let interval: Int
        let daysOfWeek: Set<Int>
        let daysOfMonth: Set<Int>
        let hasOtherParts: Bool
        let occurrenceCount: Int?
        let endDate: Date?

        init(frequency: RecurrenceRuleInput.Frequency?, interval: Int = 1, daysOfWeek: Set<Int> = [], daysOfMonth: Set<Int> = [],
             hasOtherParts: Bool = false, occurrenceCount: Int? = nil, endDate: Date? = nil) {
            self.frequency = frequency
            self.interval = interval
            self.daysOfWeek = daysOfWeek
            self.daysOfMonth = daysOfMonth
            self.hasOtherParts = hasOtherParts
            self.occurrenceCount = occurrenceCount
            self.endDate = endDate
        }

        init(_ rule: EKRecurrenceRule) {
            switch rule.frequency {
            case .daily: frequency = .daily
            case .weekly: frequency = .weekly
            case .monthly: frequency = .monthly
            case .yearly: frequency = .yearly
            @unknown default: frequency = nil
            }
            interval = rule.interval
            let days = rule.daysOfTheWeek ?? []
            daysOfWeek = Set(days.map { $0.dayOfTheWeek.rawValue })
            daysOfMonth = Set((rule.daysOfTheMonth ?? []).map(\.intValue))
            hasOtherParts = days.contains { $0.weekNumber != 0 } || rule.setPositions != nil || rule.monthsOfTheYear != nil
                || rule.weeksOfTheYear != nil || rule.daysOfTheYear != nil
            let count = rule.recurrenceEnd?.occurrenceCount ?? 0
            occurrenceCount = count > 0 ? count : nil
            endDate = rule.recurrenceEnd?.endDate
        }
    }

    /// What part of the series a write covers, and the slot it starts from.
    enum Reach: Equatable {
        /// Span `this`, or an event that does not repeat: none of these checks apply.
        case oneOccurrence
        /// Span `all`, or span `future` from the first occurrence: `anchor` is the first one's start.
        case wholeSeries(anchor: Date)
        /// Span `future` from an occurrence after the first: `anchor` is its original slot.
        case fromLaterOccurrence(anchor: Date)

        var isFromLaterOccurrence: Bool {
            if case .fromLaterOccurrence = self { return true }
            return false
        }

        var anchor: Date? {
            switch self {
            case .oneOccurrence: return nil
            case .wholeSeries(let anchor), .fromLaterOccurrence(let anchor): return anchor
            }
        }
    }

    /// `ownIdLater` is set when the call names an occurrence by its own identifier (`/RID=`, or
    /// detached): whether an earlier slot of the series remains or the first slot was deleted, as
    /// `DetachedOccurrenceSpan.Neighbours` reads it. That path resolves to the occurrence itself, so
    /// comparing it with the object found cannot tell (PR #471 verify). Otherwise `occurrenceSlot`
    /// is the original slot of the occurrence the write starts from (the series' start for span
    /// `all`), compared with `seriesStart`.
    static func reach(applyToAll: Bool, futureSpan: Bool, repeats: Bool, ownIdLater: Bool?,
                      seriesStart: Date, occurrenceSlot: Date) -> Reach {
        guard applyToAll || futureSpan else { return .oneOccurrence }
        if let later = ownIdLater {
            return later ? .fromLaterOccurrence(anchor: occurrenceSlot) : .wholeSeries(anchor: occurrenceSlot)
        }
        guard repeats else { return .oneOccurrence }
        if applyToAll || occurrenceSlot <= seriesStart { return .wholeSeries(anchor: seriesStart) }
        return .fromLaterOccurrence(anchor: occurrenceSlot)
    }

    /// Whether the occurrence a write starts from has happened: by its slot, or by the time it
    /// shows when it was moved earlier than that.
    static func hasHappened(slot: Date, shownStart: Date, now: Date) -> Bool {
        min(slot, shownStart) < now
    }

    // MARK: moving the start

    /// A move later from an occurrence that has happened. A series that has not started loses
    /// nothing that happened. A move earlier was measured on a series with no edited occurrence:
    /// every occurrence moved, and on a series with a count the count stayed, so it ends earlier.
    static func needsPassedOccurrenceCheck(repeats: Bool, anchorStart: Date, plannedStart: Date, happened: Bool) -> Bool {
        repeats && plannedStart > anchorStart && happened
    }

    /// The earliest the rule's next slot after `anchor` can be, from the rule alone, so a deleted
    /// occurrence there does not let a move past its slot through. Exact for a rule with one slot
    /// a period that `anchor` lies on; for any other rule (several slots a period, a filter the
    /// input cannot write, several rules) the start of the next day, as each slot is on its own day.
    static func nextSlotLowerBound(after anchor: Date, rules: [StoredRule], calendar: Calendar) -> Date {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: anchor)) ?? anchor
        guard rules.count == 1, let rule = rules.first, !rule.hasOtherParts, let frequency = rule.frequency, rule.interval >= 1 else {
            return nextDay
        }
        let weekday = calendar.component(.weekday, from: anchor), day = calendar.component(.day, from: anchor)
        let onlyWeekday = rule.daysOfWeek.isEmpty || rule.daysOfWeek == [weekday]
        let onlyDay = rule.daysOfMonth.isEmpty || rule.daysOfMonth == [day]
        let step: (Calendar.Component, Int)?
        switch frequency {
        case .daily: step = rule.daysOfWeek.isEmpty && rule.daysOfMonth.isEmpty ? (.day, rule.interval) : nil
        case .weekly: step = onlyWeekday && rule.daysOfMonth.isEmpty ? (.day, 7 * rule.interval) : nil
        case .monthly: step = rule.daysOfWeek.isEmpty && onlyDay ? (.month, rule.interval) : nil
        case .yearly: step = rule.daysOfWeek.isEmpty && rule.daysOfMonth.isEmpty ? (.year, rule.interval) : nil
        }
        // Adding months clamps to a short month's last day, which is no later than the real slot.
        guard let step, let next = calendar.date(byAdding: step.0, value: step.1, to: anchor) else { return nextDay }
        return next
    }

    /// Whether the new start reaches the next slot. A move of a week took the first occurrence; two
    /// days later, before the second, moved every occurrence and lost none. `dayCalendar`: compare
    /// by day, for an all-day result or series, whose start is the day's midnight.
    static func passesNextSlot(plannedStart: Date, nextSlot: Date, dayCalendar: Calendar?) -> Bool {
        guard let dayCalendar else { return plannedStart >= nextSlot }
        return dayCalendar.startOfDay(for: plannedStart) >= dayCalendar.startOfDay(for: nextSlot)
    }

    /// The refusal of a start that reaches the next slot, by what the call covers.
    static func startReason(reach: Reach, clearingRecurrence: Bool) -> String {
        if clearingRecurrence { return clearStartReason }
        return reach.isFromLaterOccurrence ? laterStartReason : startPassesOccurrencesReason
    }

    // MARK: a rule from an occurrence that has happened

    /// PR #471 verify item 4, measured on a started weekly series of 10: span `all` with
    /// `interval: 2`, `monthly`, `occurrence_count: 3` or an `end_date` before today removed
    /// occurrences that happened, and `days_of_week` [Tue, Thu] added ones in the past that never
    /// did; the same pattern with an `end_date` after today, a count above the stored one, or no
    /// bound kept every one. A closed list: only the stored pattern, with one of those bounds.
    static func keepsStoredPattern(_ new: RecurrenceRuleInput, stored: [StoredRule]) -> Bool {
        guard stored.count == 1, let rule = stored.first, !rule.hasOtherParts, let frequency = rule.frequency else { return false }
        return new.frequency == frequency && new.interval == rule.interval
            && Set(new.daysOfWeek ?? []) == rule.daysOfWeek && Set(new.daysOfMonth ?? []) == rule.daysOfMonth
    }

    /// No bound, an end at or after now, or a count at least the stored one (the stored rule has a count).
    static func boundKeepsHappened(_ new: RecurrenceRuleInput, stored: StoredRule, now: Date) -> Bool {
        if let end = new.endDate { return end >= now }
        if let count = new.occurrenceCount { return stored.occurrenceCount.map { count >= $0 } ?? false }
        return true
    }

    /// The refusal of `recurrence` from an occurrence that has happened, or nil. `happened` false
    /// (a series that has not started, or from an occurrence still to come) checks nothing:
    /// measured clean from a later occurrence.
    static func startedRuleRefusal(_ new: RecurrenceRuleInput?, stored: [StoredRule], happened: Bool, now: Date) -> String? {
        guard let new, happened else { return nil }
        guard keepsStoredPattern(new, stored: stored), let rule = stored.first, boundKeepsHappened(new, stored: rule, now: now) else {
            return startedRuleReason
        }
        return nil
    }

    // MARK: span future from a later occurrence

    /// Span future from an occurrence after the first. A rule with `end_date` or no bound stayed
    /// within the later occurrences, also with `start_time`, and a rule with no bound with
    /// `calendar_name`.
    static func laterOccurrenceRefusal(fromLaterOccurrence: Bool, changesAllDay: Bool, changesCalendar: Bool,
                                       hasRecurrence: Bool, occurrenceCount: Int?) -> String? {
        guard fromLaterOccurrence else { return nil }
        if changesAllDay { return allDayReason }
        if occurrenceCount != nil { return countReason }
        if changesCalendar, !hasRecurrence { return calendarReason }
        return nil
    }

    // MARK: messages (fixed strings; they name only routes that were measured)

    static let startPassesOccurrencesReason = "This would move the series' start past occurrences that have already happened, and every occurrence before the new start would be gone. To change other fields of the series, leave start_time out. To move the whole series to another time of day, give start_time on the first occurrence's own date. To move the occurrences from one that has not happened yet, pass span 'future' with that occurrence's occurrence_date and start_time; give a new rule end_date, not occurrence_count. Nothing was written."
    static let laterStartReason = "This occurrence has already happened, and moving its start past the series' next occurrence would take the occurrences between them with it. To change other fields from this occurrence on, leave start_time out. To move the occurrences from one that has not happened yet, pass span 'future' with that occurrence's occurrence_date and start_time. Nothing was written."
    static let clearStartReason = "clear_recurrence with a start_time past the series' next occurrence, on a series that has started, would leave its one event after occurrences that happened. Leave start_time out: clear_recurrence with span 'all' leaves one event on the series' first day and deletes the other occurrences. Nothing was written."
    static let startedRuleReason = "On a series that has started, a rule from an occurrence that has already happened may only keep the series' pattern (frequency, interval, days_of_week and days_of_month as list_events shows them) with no bound, an end_date that is not in the past, or an occurrence_count no smaller than the series' own: other rules removed occurrences that happened, or added ones in the past that never did. To end the series, give that rule an end_date after now. To change the pattern, pass span 'future' with the occurrence_date of an occurrence that has not happened yet, and end_date or no bound. Nothing was written."
    static let allDayReason = "all_day cannot change from a later occurrence: with span 'future' it left a timed and an all-day occurrence on that day, and lost the series' last occurrences. Pass span 'all' for the whole series. Nothing was written."
    static let countReason = "occurrence_count cannot be used with span 'future' from a later occurrence: the store counts from the start of the original series, so 4 from the seventh occurrence gave 1, and the occurrences after it were gone. Use end_date. Nothing was written."
    static let calendarReason = "calendar_name with span 'future' from a later occurrence moves every occurrence, the earlier ones too. Pass span 'all' to move the whole series, or recurrence with span 'future' to move the occurrences from that one on. Nothing was written."
}
