import Foundation

/// #267: a reminder due date as the caller gave it, to `create_reminder`,
/// `create_reminders_batch` and `update_reminder`.
///
/// - `timed`: an instant; written with its time and the host zone (#134).
/// - `day`: a bare `YYYY-MM-DD`, a date-only reminder (a day, no time). Year, month and day only:
///   on device (2026-10-09, iCloud) EventKit dropped a zone given to date-only components as
///   soon as they were written, and the Reminders store then marked the reminder all-day.
enum ReminderDueInput: Sendable, Equatable {
    case timed(Date)
    case day(DateComponents)

    /// Exactly `YYYY-MM-DD` is a day; every other string is handed to `timed`, the server's
    /// timed date parser, as before. A bare date is handed to `timed` too and must be accepted
    /// there first, so a day that does not exist (`2026-02-30`) fails as it always has.
    static func parse(_ text: String, timed: (String) throws -> Date) throws -> ReminderDueInput {
        let date = try timed(text)
        guard let day = bareDay(text) else { return .timed(date) }
        return .day(day)
    }

    /// The duplicate check of `create_reminder`, unchanged by #267 (verify round 1, PR #298): two
    /// dues match when their instants are less than a minute apart, and a day counts as 00:00 of
    /// that day in the host zone, as a bare date was stored before #267. A retry after upgrading
    /// therefore still finds a reminder an earlier version stored at 00:00 from the same bare date,
    /// instead of making a second, date-only copy. A stored date-only due is read the same way,
    /// whatever zone EventKit attaches to it. No due matches no due.
    static func matches(_ request: ReminderDueInput?, existing: DateComponents?) -> Bool {
        switch (request, existing) {
        case (nil, nil):
            return true
        case (let request?, let stored?):
            guard let requested = instant(of: request), let storedDate = instant(of: stored) else { return false }
            return abs(storedDate.timeIntervalSince(requested)) < 60
        default:
            return false
        }
    }

    private static func instant(of input: ReminderDueInput) -> Date? {
        switch input {
        case .timed(let date): return date
        case .day(let day): return hostMidnight(day)
        }
    }

    private static func instant(of stored: DateComponents) -> Date? {
        stored.hour == nil ? hostMidnight(stored) : safeDateFromComponents(stored)
    }

    private static func hostMidnight(_ day: DateComponents) -> Date? {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    private static func bareDay(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
