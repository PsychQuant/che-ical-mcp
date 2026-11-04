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
    ///   behind the host would match the next day's all-day occurrence. An all-day occurrence whose
    ///   start is exactly `date` matches too (PR #394 verify round 1): `delete_events_batch` passes
    ///   an item's own start with the series zone, and host midnight can be the day before there.
    /// `findOccurrence` enumerates over `candidateWindow`, which holds every occurrence this accepts.
    static func startsOnRequestedDay(occurrenceStart: Date?, isAllDay: Bool, requested date: Date, in zone: TimeZone?,
                                     host: TimeZone = .current) -> Bool {
        guard let start = occurrenceStart else { return false }
        if isAllDay {
            if start == date { return true }
            var hostCalendar = Calendar.current
            hostCalendar.timeZone = host
            var requestedCalendar = Calendar.current
            requestedCalendar.timeZone = zone ?? host
            let units: Set<Calendar.Component> = [.era, .year, .month, .day]
            return hostCalendar.dateComponents(units, from: start) == requestedCalendar.dateComponents(units, from: date)
        }
        // A nil zone is the host's day; `host` (not the process zone) so the rule is testable on any host.
        guard let window = window(containing: date, in: zone ?? host) else { return false }
        return window.start <= start && start < window.end
    }

    /// PR #394 verify round 1 (codex): the window `findOccurrence` asks EventKit for. A timed
    /// occurrence the rule accepts starts inside `window(containing: date, in: zone)`, so it overlaps
    /// it; an all-day one lies on `date`'s day taken in the host zone, which is more than a day away
    /// from the search zone's day when the two zones are over 24 hours apart (host +14, search -11),
    /// so it did not overlap and was never enumerated. The candidate window spans both days (the
    /// earlier start to the later end); the rule above still decides. With `zone` nil it is the
    /// host's day.
    static func candidateWindow(containing date: Date, in zone: TimeZone?, host: TimeZone = .current) -> (start: Date, end: Date)? {
        // PR #394 CI (UTC host): a nil zone read the process zone here and `host` below.
        guard let search = window(containing: date, in: zone ?? host) else { return nil }
        var requestedCalendar = Calendar.current
        requestedCalendar.timeZone = zone ?? host
        var hostCalendar = Calendar.current
        hostCalendar.timeZone = host
        let day = requestedCalendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let hostStart = hostCalendar.date(from: day),
              let hostEnd = hostCalendar.date(byAdding: .day, value: 1, to: hostStart) else { return nil }
        return (min(search.start, hostStart), max(search.end, hostEnd))
    }
}
