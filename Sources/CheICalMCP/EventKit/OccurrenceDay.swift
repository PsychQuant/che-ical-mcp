import Foundation

/// #270 round 4: the day `findOccurrence` searches, `[start, end)`: the calendar day containing
/// `date` in `zone` (nil: the host zone, as before). Pure, so the zone is value-tested; a
/// `findOccurrence` that ignored its zone kept every test green before this.
enum OccurrenceDay {
    static func window(containing date: Date, in zone: TimeZone?) -> (start: Date, end: Date)? {
        var calendar = Calendar.current
        if let zone { calendar.timeZone = zone }
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// #391: whether an occurrence is on the requested day, the test `findOccurrence` applies to
    /// what the day's predicate enumerates. EventKit's predicate is an overlap query: it also
    /// returns an occurrence that ends at the window's start, and an overnight one (22:00-02:00)
    /// from the day before, which enumerate first and were picked (device, 2026-11-04). An
    /// occurrence belongs to the day it starts on:
    /// - timed: its start lies in `[window.start, window.end)` of `date`'s day in `zone`;
    /// - all-day: its start's day in this Mac's zone (all-day dates are floating whole days stored
    ///   from host midnight, #364) equals `date`'s day in `zone`. By start instant alone, a zone
    ///   behind the host would match the next day's all-day occurrence.
    /// Every occurrence starting in the window overlaps it, so the predicate loses none of them.
    static func startsOnRequestedDay(occurrenceStart: Date?, isAllDay: Bool, requested date: Date, in zone: TimeZone?) -> Bool {
        guard let start = occurrenceStart else { return false }
        if isAllDay {
            var requestedCalendar = Calendar.current
            if let zone { requestedCalendar.timeZone = zone }
            let units: Set<Calendar.Component> = [.era, .year, .month, .day]
            return Calendar.current.dateComponents(units, from: start) == requestedCalendar.dateComponents(units, from: date)
        }
        guard let window = window(containing: date, in: zone) else { return false }
        return window.start <= start && start < window.end
    }
}
