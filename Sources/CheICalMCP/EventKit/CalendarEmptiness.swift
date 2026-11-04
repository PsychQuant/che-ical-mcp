import Foundation

/// #328: whether a calendar is empty before `delete_calendar` removes it, when the caller asks
/// (`require_empty`). EventKit has no query for "every event of a calendar": events are searched
/// over a stated window, in `EventRangeQuery`'s spans, and the search stops at the first span that
/// holds any, so the count it reports is a lower bound. A reminder list is counted whole (its
/// predicate takes no dates). EventKit is behind closures, so the sequence is tested without it.
/// Nothing here is async: the caller (`EventKitManager.deleteCalendar`) runs it on its actor.
enum CalendarEmptiness {
    /// Half the span ceiling on each side of now (about 200 years each way): the widest window
    /// `EventRangeQuery.spans` searches in one call. An event outside it is not found; the answer
    /// and the refusal both state the window.
    static let windowDaysEachSide = EventRangeQuery.maxSpans * EventRangeQuery.maxSpanDays / 2

    /// What a passed check searched, for the response.
    struct Checked: Equatable, Sendable {
        /// The event window searched in full and found empty; nil when the calendar holds no events.
        let searched: EventRangeQuery.Span?
        /// The reminders counted (0 when it passed); nil when the calendar holds no reminders.
        let reminders: Int?
    }

    static func window(now: Date) -> EventRangeQuery.Span {
        let reach = TimeInterval(windowDaysEachSide) * 86_400
        return EventRangeQuery.Span(start: now.addingTimeInterval(-reach), end: now.addingTimeInterval(reach))
    }

    /// The first span of `window` that holds events, and how many it holds; nil when none does.
    /// Each span after the first is queried from one second before its start, as
    /// `EventRangeQuery.collect` does, so a zero-length event on a boundary is not missed.
    static func firstEvents(in window: EventRangeQuery.Span,
                            count: (Date, Date) throws -> Int) throws -> (atLeast: Int, span: EventRangeQuery.Span)? {
        for span in try EventRangeQuery.spans(from: window.start, to: window.end) {
            let from = span.start > window.start ? max(window.start, span.start.addingTimeInterval(-1)) : span.start
            let found = try count(from, span.end)
            if found > 0 { return (found, span) }
        }
        return nil
    }

    /// Throws `EventKitError.calendarNotEmpty` when `window` holds events. Synchronous, so it runs
    /// on its caller's actor with no suspension (PR #413 verify r1). A `count` that throws stops the
    /// check: a read that cannot answer refuses, it is never taken as empty.
    static func checkEvents(window: EventRangeQuery.Span, count: (Date, Date) throws -> Int) throws {
        if let found = try firstEvents(in: window, count: count) {
            throw EventKitError.calendarNotEmpty(reason: eventsMessage(atLeast: found.atLeast, span: found.span, window: window))
        }
    }

    /// The reminders check after the fetch: `counted` is nil when the fetch returned nothing (it
    /// failed), which refuses instead of reading as an empty list; a write this server committed
    /// during the fetch (`generationBefore` != `generationAfter`, the manager's write generation)
    /// refuses too, even when the count was 0; any reminder refuses (PR #413 verify r1).
    static func checkReminders(counted: Int?, generationBefore: Int, generationAfter: Int) throws {
        guard let counted else {
            throw EventKitError.calendarNotEmpty(reason: "Refusing to delete the list: require_empty is set and its reminders could not be counted. Nothing was deleted.")
        }
        guard generationBefore == generationAfter else {
            throw EventKitError.calendarNotEmpty(reason: "Refusing to delete the list: require_empty is set and the calendar data changed while the list was being checked. Nothing was deleted; try again.")
        }
        if counted > 0 { throw EventKitError.calendarNotEmpty(reason: remindersMessage(counted)) }
    }

    /// Numbers and dates formatted by this server only: no calendar or event title (#37).
    static func eventsMessage(atLeast: Int, span: EventRangeQuery.Span, window: EventRangeQuery.Span) -> String {
        "Refusing to delete the calendar: require_empty is set and it holds at least \(atLeast) event(s) between \(EventRangeQuery.localText(span.start)) and \(EventRangeQuery.localText(span.end)). Nothing was deleted. The search covers \(EventRangeQuery.localText(window.start)) to \(EventRangeQuery.localText(window.end)) only and stops at the first part of it that holds events, so the count is a lower bound. List them with list_events and this calendar_name, or delete the calendar without require_empty."
    }

    static func remindersMessage(_ count: Int) -> String {
        "Refusing to delete the list: require_empty is set and it holds \(count) reminder(s), completed ones included. Nothing was deleted. List them with list_reminders, or delete the list without require_empty."
    }
}
