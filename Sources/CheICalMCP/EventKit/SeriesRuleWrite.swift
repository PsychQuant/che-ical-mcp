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
                || SeriesRuleWrite.weekStartMatters(frequency: frequency, firstDayOfTheWeek: rule.firstDayOfTheWeek,
                                                    interval: rule.interval, dayCount: Set(days.map(\.dayOfTheWeek)).count)
            let count = rule.recurrenceEnd?.occurrenceCount ?? 0
            occurrenceCount = count > 0 ? count : nil
            endDate = rule.recurrenceEnd?.endDate
        }
    }

    /// PR #471 verify rounds 4-5: the week start (WKST, RFC 5545) decides which days share a period
    /// only on a weekly rule repeating every two weeks or more with more than one day (a yearly rule
    /// by week number is already a part `recurrence` cannot write). A rule `recurrence` writes gets
    /// EventKit's default, 2 (Monday; checked on this host, 2026-11-08), so on such a rule a stored
    /// week start other than that (or 0, unset) cannot be written back, and a rewrite could regroup
    /// the days and move happened occurrences. One day a week, interval 1, or another frequency is
    /// not regrouped, so Google's WKST=SU on a biweekly Tuesday series is no reason to refuse.
    static let writtenWeekStart = 2
    static func weekStartMatters(frequency: RecurrenceRuleInput.Frequency?, firstDayOfTheWeek: Int, interval: Int, dayCount: Int) -> Bool {
        frequency == .weekly && interval > 1 && dayCount > 1
            && firstDayOfTheWeek != 0 && firstDayOfTheWeek != writtenWeekStart
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

    /// The refusal of a new start, or nil. A closed rule (PR #471 verify round 2), decided before
    /// anything is written:
    /// - from an occurrence that has happened (`happened`), `start_time` may change only the time of
    ///   day, on that occurrence's own date (`anchor`, in `dayCalendar`): any other date, earlier or
    ///   later, by a week or by two days, moves the series' days, so occurrences that happened go or
    ///   land on days they never had (measured for a week later and two days later on #451; a week
    ///   earlier, the next slot's day an hour earlier and a monthly series on the 6th moved to the
    ///   26th are the same move of the series' days, read from the code in round 2);
    /// - from an occurrence still to come, the new start may not be before now, where occurrences
    ///   that never happened would appear.
    /// `dayCalendar` is the event's zone for a timed result, the host's for an all-day one.
    static func startRefusal(reach: Reach, plannedStart: Date?, happened: Bool, now: Date,
                             dayCalendar: Calendar, clearingRecurrence: Bool) -> String? {
        guard let anchor = reach.anchor, let planned = plannedStart else { return nil }
        if happened {
            if dayCalendar.isDate(planned, inSameDayAs: anchor) { return nil }
            if clearingRecurrence { return clearStartReason }
            return reach.isFromLaterOccurrence ? laterStartReason : startPassesOccurrencesReason
        }
        return planned < now ? pastStartReason : nil
    }

    // MARK: a rule from an occurrence that has happened

    /// PR #471 verify item 4, measured on a started weekly series of 10: span `all` with
    /// `interval: 2`, `monthly`, `occurrence_count: 3` or an `end_date` before today removed
    /// occurrences that happened, and `days_of_week` [Tue, Thu] added ones in the past that never
    /// did; the same pattern with an `end_date` after today, a count above the stored one, or no
    /// bound kept every one. A closed list: only the stored pattern, with one of those bounds.
    static func keepsStoredPattern(_ new: RecurrenceRuleInput, stored: [StoredRule]) -> Bool {
        guard let rule = writableRule(stored) else { return false }
        return new.frequency == rule.frequency && new.interval == rule.interval
            && Set(new.daysOfWeek ?? []) == rule.daysOfWeek && Set(new.daysOfMonth ?? []) == rule.daysOfMonth
    }

    /// The one stored rule, when `recurrence` can write its pattern; nil otherwise.
    static func writableRule(_ stored: [StoredRule]) -> StoredRule? {
        guard stored.count == 1, let rule = stored.first, !rule.hasOtherParts, rule.frequency != nil else { return nil }
        return rule
    }

    /// Whether the new bound keeps every occurrence that happened and adds none in the past. The
    /// caller has already passed the stored bound echoed unchanged (`sameBound`) and a series whose
    /// state `stillRuns` cannot tell. A series that has finished gains occurrences after its last
    /// one, which may be in the past, so it takes only its own bound; on a series still running,
    /// no bound, an end at or after now, or a count at least the stored one (measured). An end
    /// before now is refused even where it falls after the last occurrence that happened: the
    /// check does not list them, the side that refuses.
    static func boundKeepsHappened(_ new: RecurrenceRuleInput, stored: StoredRule, stillRuns: Bool, now: Date) -> Bool {
        guard stillRuns else { return false }
        if let end = new.endDate { return end >= now }
        if let count = new.occurrenceCount { return stored.occurrenceCount.map { count >= $0 } ?? false }
        return true
    }

    static func sameBound(_ new: RecurrenceRuleInput, _ stored: StoredRule) -> Bool {
        switch (new.endDate, new.occurrenceCount) {
        case (let end?, nil): return stored.endDate.map { abs($0.timeIntervalSince(end)) < 1 } ?? false
        case (nil, let count?): return stored.occurrenceCount == count
        case (nil, nil): return stored.endDate == nil && stored.occurrenceCount == nil
        default: return false
        }
    }

    /// The start a stored `occurrence_count` counts from, when the call holds it: the series' own
    /// first slot, on a call that covers the whole series from there. nil from a later occurrence,
    /// through the stand-in of a deleted first occurrence, or after the first slot was deleted: the
    /// store counts from the original first start (#443), which those calls do not hold
    /// (PR #471 verify round 3).
    static func countBase(reach: Reach, viaStandIn: Bool, firstSlotGone: Bool) -> Date? {
        guard case .wholeSeries(let anchor) = reach, !viaStandIn, !firstSlotGone else { return nil }
        return anchor
    }

    /// Whether the stored series may still have occurrences at or after now, so a bound moved later
    /// adds none in the past; nil when that cannot be told. An end at or after now; no bound; with a
    /// count, the slot after the last one at or after now, worked out from `countBase` only for a
    /// rule with one slot a period on that day (adding months clamps to a short month, which is no
    /// later than the real slot). A count with no `countBase`, or on any other rule, is nil.
    static func stillRuns(_ stored: StoredRule, countBase: Date?, now: Date, calendar: Calendar) -> Bool? {
        if let end = stored.endDate { return end >= now }
        guard let count = stored.occurrenceCount else { return true }
        guard let base = countBase, let step = periodStep(stored, firstStart: base, calendar: calendar),
              let afterLast = calendar.date(byAdding: step.component, value: step.value * count, to: base) else { return nil }
        return afterLast >= now
    }

    /// One period of a rule with one slot a period that `firstStart` lies on, or nil.
    static func periodStep(_ rule: StoredRule, firstStart: Date, calendar: Calendar) -> (component: Calendar.Component, value: Int)? {
        guard !rule.hasOtherParts, let frequency = rule.frequency, rule.interval >= 1 else { return nil }
        let onlyWeekday = rule.daysOfWeek.isEmpty || rule.daysOfWeek == [calendar.component(.weekday, from: firstStart)]
        let onlyDay = rule.daysOfMonth.isEmpty || rule.daysOfMonth == [calendar.component(.day, from: firstStart)]
        switch frequency {
        case .daily: return rule.daysOfWeek.isEmpty && rule.daysOfMonth.isEmpty ? (.day, rule.interval) : nil
        case .weekly: return onlyWeekday && rule.daysOfMonth.isEmpty ? (.day, 7 * rule.interval) : nil
        case .monthly: return rule.daysOfWeek.isEmpty && onlyDay ? (.month, rule.interval) : nil
        case .yearly: return rule.daysOfWeek.isEmpty && rule.daysOfMonth.isEmpty ? (.year, rule.interval) : nil
        }
    }

    /// The refusal of `recurrence` from an occurrence that has happened, or nil. `happened` false
    /// (a series that has not started, or from an occurrence still to come) checks nothing:
    /// measured clean from a later occurrence. `countBase`: `countBase(reach:viaStandIn:firstSlotGone:)`.
    static func startedRuleRefusal(_ new: RecurrenceRuleInput?, stored: [StoredRule], happened: Bool,
                                   countBase: Date?, now: Date, calendar: Calendar) -> String? {
        guard let new, happened else { return nil }
        guard let rule = writableRule(stored) else { return unwritableRuleReason }
        guard keepsStoredPattern(new, stored: stored) else { return startedRuleReason }
        if sameBound(new, rule) { return nil }
        guard let runs = stillRuns(rule, countBase: countBase, now: now, calendar: calendar) else { return countedSeriesReason }
        return boundKeepsHappened(new, stored: rule, stillRuns: runs, now: now) ? nil : startedRuleReason
    }

    /// Whether `new` is the stored rule itself, pattern and bound.
    static func isStoredRule(_ new: RecurrenceRuleInput, stored: [StoredRule]) -> Bool {
        // PR #471 verify round 5: over a rule recurrence cannot write, a rule in the call may write
        // nothing new, so it counts as possibly the stored one: the side that refuses.
        guard let rule = writableRule(stored) else { return !stored.isEmpty }
        return keepsStoredPattern(new, stored: stored) && sameBound(new, rule)
    }

    // MARK: span future from a later occurrence

    /// Span future from an occurrence after the first. A rule with `end_date` or no bound stayed
    /// within the later occurrences, also with `start_time`, and a rule with no bound with
    /// `calendar_name`.
    /// `wholeSeriesCall`: span `all`, which reaches here only through an occurrence's own id after
    /// a deleted first slot (PR #471 verify round 2); its count text does not name span `future`.
    static func laterOccurrenceRefusal(fromLaterOccurrence: Bool, changesAllDay: Bool, changesCalendar: Bool,
                                       hasRecurrence: Bool, occurrenceCount: Int?, wholeSeriesCall: Bool = false,
                                       recurrenceIsStored: Bool = false) -> String? {
        guard fromLaterOccurrence else { return nil }
        if changesAllDay { return allDayReason }
        if occurrenceCount != nil { return wholeSeriesCall ? countAfterDeletedFirstReason : countReason }
        // An echo of the stored rule may change nothing and leave the move to every occurrence; only
        // a rule with another bound was measured to split the series there (round 3).
        if changesCalendar, !hasRecurrence || recurrenceIsStored { return calendarReason }
        return nil
    }

    // MARK: messages (fixed strings; they name only routes that were measured)

    static let startPassesOccurrencesReason = "On a series that has started, start_time may change only the time of day of its first occurrence, on that occurrence's own date: another date, earlier or later, moves the series' days, so occurrences that have already happened would be gone or land on days they never had. To change other fields of the series, leave start_time out. To move the occurrences from one that has not happened yet, pass span 'future' with that occurrence's occurrence_date and a start_time that is not in the past; give a new rule end_date, not occurrence_count. Nothing was written."
    static let laterStartReason = "This occurrence has already happened, so start_time may change only its time of day, on its own date: another date would take occurrences that happened with it. To change other fields from this occurrence on, leave start_time out. To move the occurrences from one that has not happened yet, pass span 'future' with that occurrence's occurrence_date and a start_time that is not in the past. Nothing was written."
    static let pastStartReason = "This start_time is before now: the occurrences from it would start in the past, on days where none happened. Give a start_time that is not in the past, or leave start_time out. Nothing was written."
    static let clearStartReason = "clear_recurrence with a start_time on another date than the series' first occurrence, on a series that has started, would leave its one event on a day where it did not happen. Leave start_time out: clear_recurrence with span 'all' leaves one event on the series' first day and deletes the other occurrences. Nothing was written."
    static let startedRuleReason = "On a series that has started, a rule from an occurrence that has already happened may only keep the series' pattern (frequency, interval, days_of_week and days_of_month as list_events shows them) with its own bound, or, while the series still has occurrences to come, no bound, an end_date that is not in the past, or an occurrence_count no smaller than the series' own: other rules removed occurrences that happened, or added ones in the past that never did. An end_date before now is refused even when it falls after the last occurrence that happened. To keep the series' rule, leave recurrence out. To end the series, give that rule an end_date after now (on a series with an occurrence_count, only from its first occurrence over the whole series). To change the pattern, pass span 'future' with the occurrence_date of an occurrence that has not happened yet, and end_date or no bound. Nothing was written."
    static let countedSeriesReason = "This series ends after a number of occurrences (occurrence_count), counted from its first occurrence, and this call cannot tell whether any are still to come: it starts after the first occurrence, the first occurrence was deleted, or the rule is not one with a single slot on the first start's day each period. Here a recurrence passes only with the series' own bound, and from a later occurrence or after a deleted first one not even then, since occurrence_count is refused there; leaving recurrence out keeps the rule. To end it or change its bound, pass span 'future' with the occurrence_date of an occurrence that has not happened yet, and end_date. A series with no occurrence still to come has ended and keeps its bound. Nothing was written."
    static let unwritableRuleReason = "This series' rule has parts recurrence cannot write (a numbered weekday such as the second Tuesday, set positions, months, weeks or days of the year, a week start other than Monday on a weekly rule with more than one day repeating every two weeks or more, or more than one rule), so on a series that has started its rule cannot be changed from an occurrence that has already happened. Leave recurrence out to keep the rule. Nothing was written."
    static let countAfterDeletedFirstReason = "occurrence_count cannot be used here: the series' first occurrence was deleted, and the store counts from the start of the original series (from a later occurrence with span 'future', 4 from the seventh occurrence gave 1). This route was not measured. Use end_date. Nothing was written."
    static let allDayReason = "all_day cannot change from a later occurrence: with span 'future' it left a timed and an all-day occurrence on that day, and lost the series' last occurrences. Pass span 'all' for the whole series. Nothing was written."
    static let countReason = "occurrence_count cannot be used with span 'future' from a later occurrence: the store counts from the start of the original series, so 4 from the seventh occurrence gave 1, and the occurrences after it were gone. Use end_date. Nothing was written."
    static let calendarReason = "calendar_name with span 'future' from a later occurrence moves every occurrence, the earlier ones too, unless the call also changes the rule. Pass span 'all' to move the whole series. To move the occurrences from one that has not happened yet on, pass recurrence with span 'future' from it and a bound other than the series' own: on a series with an occurrence_count, an end_date or no bound moved only those (measured). Nothing was written."
}
