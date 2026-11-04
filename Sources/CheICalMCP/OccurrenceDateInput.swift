import Foundation

/// #270 (verify MEDIUM 1): how `delete_event` and `move_events_batch` read an `occurrence_date`.
/// A value without an explicit offset (a bare date, a date-time without offset, a time) is read
/// in the event's own zone, the zone `findOccurrence` takes the day boundary in; `zone` supplies
/// it and is called only for such a value, so a call without occurrence_date, or with an offset,
/// runs no access check, refresh or stand-in scan for it. An error from `zone` (calendar access)
/// is thrown before anything is parsed, so the date is never read in the host zone instead; a nil
/// zone (event not found, no zone set) keeps the host zone, and the write then reports not found.
enum OccurrenceDateInput {
    static func resolve(_ string: String?, iso: ISO8601DateFormatter,
                        zone: () async throws -> TimeZone?) async throws -> Date? {
        guard let string else { return nil }
        if let explicit = iso.date(from: string) { return explicit }
        let eventZone = try await zone()
        return try FlexibleDate.parse(string, defaultTimezone: eventZone, iso: iso)
    }
}
