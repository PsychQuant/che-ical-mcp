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

    /// Exactly `YYYY-MM-DD` naming a day of the Gregorian calendar is a day; every other string is
    /// handed to `timed`, the server's timed date parser, as before. A day needs no instant
    /// (verify round 1, PR #298), so a valid one does not depend on the host zone having a
    /// midnight that day. A bare date that names no day (`2026-02-30`) goes to `timed` and fails
    /// there as it always has.
    static func parse(_ text: String, timed: (String) throws -> Date) throws -> ReminderDueInput {
        if let day = bareDay(text), isCalendarDay(day) { return .day(day) }
        return .timed(try timed(text))
    }

    /// The duplicate check of `create_reminder`, unchanged by #267 (verify round 1, PR #298) for
    /// times: two dues match when their instants are less than a minute apart, and a day counts as
    /// 00:00 of that day in the host zone, as a bare date was stored before #267. A retry after
    /// upgrading therefore still finds a reminder an earlier version stored at 00:00 from the same
    /// bare date, instead of making a second, date-only copy. No due matches no due.
    ///
    /// #299, days compare as days:
    /// - a day and a stored date-only due match when they are the same year/month/day (a stored
    ///   due carrying another calendar is counted in Gregorian first), whatever zone EventKit
    ///   attaches to it;
    /// - a day and a timed value compare through the day's host-zone midnight only when that
    ///   midnight converts back to the same day. A day the host zone skipped (Pacific/Apia,
    ///   2011-12-30) has none, and Foundation would hand back the next day's, so it matches no
    ///   timed value.
    ///
    /// Instants are built in the Gregorian calendar EventKit's components are in, or in the
    /// calendar attached to the stored components, never in the calendar chosen in region settings
    /// (verify round 2: a Buddhist or ROC host calendar would read the same year/month/day as
    /// another day). `hostZone` is the zone of a day and of a due stored without a zone.
    static func matches(_ request: ReminderDueInput?, existing: DateComponents?, hostZone: TimeZone = .current) -> Bool {
        switch (request, existing) {
        case (nil, nil):
            return true
        case (.day(let day)?, let stored?) where stored.hour == nil:
            guard let storedDay = gregorianDay(of: stored) else { return false }
            return day.year == storedDay.year && day.month == storedDay.month && day.day == storedDay.day
        case (let request?, let stored?):
            guard let requested = instant(of: request, hostZone: hostZone),
                  let storedDate = instant(of: stored, hostZone: hostZone) else { return false }
            return abs(storedDate.timeIntervalSince(requested)) < 60
        default:
            return false
        }
    }

    private static func instant(of input: ReminderDueInput, hostZone: TimeZone) -> Date? {
        switch input {
        case .timed(let date): return date
        case .day(let day): return instant(of: day, hostZone: hostZone)
        }
    }

    /// A date-only value is 00:00 of its day in the host zone, or nil when the zone has no such
    /// midnight (#299); a timed one is read in its own zone.
    private static func instant(of stored: DateComponents, hostZone: TimeZone) -> Date? {
        var calendar = stored.calendar ?? Calendar(identifier: .gregorian)
        let dateOnly = stored.hour == nil
        calendar.timeZone = dateOnly ? hostZone : (stored.timeZone ?? hostZone)
        var fields = DateComponents(era: stored.era, year: stored.year, month: stored.month, day: stored.day)
        if !dateOnly {
            fields.hour = stored.hour
            fields.minute = stored.minute
            fields.second = stored.second
        }
        guard let date = calendar.date(from: fields) else { return nil }
        if dateOnly {
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == stored.year, back.month == stored.month, back.day == stored.day else { return nil }
        }
        return date
    }

    /// The Gregorian year/month/day of a stored date-only due. A due carrying another calendar is
    /// converted at noon UTC, where every calendar Foundation offers is on the same day.
    private static func gregorianDay(of stored: DateComponents) -> DateComponents? {
        guard let other = stored.calendar, other.identifier != .gregorian else {
            return DateComponents(year: stored.year, month: stored.month, day: stored.day)
        }
        let utc = TimeZone(identifier: "UTC")!
        var calendar = other
        calendar.timeZone = utc
        guard let noon = calendar.date(from: DateComponents(era: stored.era, year: stored.year, month: stored.month,
                                                            day: stored.day, hour: 12)) else { return nil }
        return Calendar.gregorian(in: utc).dateComponents([.year, .month, .day], from: noon)
    }

    private static func isCalendarDay(_ day: DateComponents) -> Bool {
        let calendar = Calendar.gregorian(in: TimeZone(identifier: "UTC")!)
        guard let date = calendar.date(from: day) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == day.year && back.month == day.month && back.day == day.day
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
