import Foundation

/// #270 (verify MEDIUM 1, round 2): how `delete_event` and `move_events_batch` read an
/// `occurrence_date`. A value without an explicit offset (a bare date, a date-time without
/// offset, a time) is read in the event's own zone, the zone `findOccurrence` takes the day
/// boundary in. This function decides whether that zone is needed and uses what `zoneLookup`
/// returns, so a caller only passes its span and the lookup, and cannot drop the result:
/// - span `all` does not use the date (the whole series is deleted, and a move refuses a date
///   with span all), so the zone is not looked up; the value is still checked as a date;
/// - a value with an explicit offset needs no zone, so the lookup is not called;
/// - otherwise the lookup is called; an error from it (calendar access) is thrown before anything
///   is parsed, so the date is never read in the host zone instead. A nil zone keeps the host
///   zone: for an event not found, the write then reports not found (unless the event appeared
///   in between); for an event with no zone set (all-day or floating), the search side also uses
///   the host zone (`findOccurrence` with a nil zone), so both sides agree.
/// A call without occurrence_date runs no access check, refresh or stand-in scan for it.
enum OccurrenceDateInput {
    static func resolve(_ string: String?, iso: ISO8601DateFormatter, span: String,
                        zoneLookup: () async throws -> TimeZone?) async throws -> Date? {
        guard let string else { return nil }
        if let explicit = iso.date(from: string) { return explicit }
        let eventZone = span == "all" ? nil : try await zoneLookup()
        return try FlexibleDate.parse(string, defaultTimezone: eventZone, iso: iso)
    }
}
