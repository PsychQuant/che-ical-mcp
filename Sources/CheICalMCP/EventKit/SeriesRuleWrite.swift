import Foundation

/// #451: the `update_event` shapes that answered `updated` while occurrences went, refused before
/// anything is written. Measured on iCloud; the tables are on the issue. Undo refuses every update
/// of a recurring event, so nothing restores what went.
enum SeriesRuleWrite {
    /// A write that sets the first occurrence's start: span all, or span future from that occurrence.
    /// Only a move later on a series that has started can take occurrences that happened: a series
    /// that has not started loses nothing that happened, and a move earlier was measured clean.
    static func needsPassedOccurrenceCheck(coversSeries: Bool, repeats: Bool, firstStart: Date, plannedStart: Date, now: Date) -> Bool {
        coversSeries && repeats && plannedStart > firstStart && firstStart < now
    }

    /// Whether the new start reaches an occurrence after the first. A move of a week took the first
    /// occurrence; two days later, before the second, moved every occurrence and lost none.
    static func passesAnOccurrence(starts: [Date], firstStart: Date, plannedStart: Date) -> Bool {
        starts.contains { $0 > firstStart && $0 <= plannedStart }
    }

    /// Span future from an occurrence after the first. A rule with `end_date` or no bound stayed
    /// within the later occurrences, also with `start_time`, and with `calendar_name`.
    static func laterOccurrenceRefusal(fromLaterOccurrence: Bool, changesAllDay: Bool, changesCalendar: Bool,
                                       hasRecurrence: Bool, occurrenceCount: Int?) -> String? {
        guard fromLaterOccurrence else { return nil }
        if changesAllDay { return allDayReason }
        if occurrenceCount != nil { return countReason }
        if changesCalendar, !hasRecurrence { return calendarReason }
        return nil
    }

    static let startPassesOccurrencesReason = "This would move the series' start past occurrences that have already happened, and every occurrence before the new start would be gone. To keep them, pass span 'future' with the occurrence_date of the first occurrence to change, and start_time; give a new rule end_date, not occurrence_count. Nothing was written."
    static let allDayReason = "all_day cannot change from a later occurrence: with span 'future' it left a timed and an all-day occurrence on that day, and lost the series' last occurrences. Pass span 'all' for the whole series. Nothing was written."
    static let countReason = "occurrence_count cannot be used with span 'future' from a later occurrence: the store counts from the start of the original series, so 4 from the seventh occurrence gave 1, and the occurrences after it were gone. Use end_date. Nothing was written."
    static let calendarReason = "calendar_name with span 'future' from a later occurrence moves every occurrence, the earlier ones too. Pass span 'all' to move the whole series, or recurrence with span 'future' to move the occurrences from that one on. Nothing was written."
}
