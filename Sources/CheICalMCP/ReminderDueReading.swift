import Foundation

/// #297: how the read tools judge a reminder's due date. `is_overdue` (`list_reminders`),
/// `filter: "overdue"` and `sort: "due_date"` (`ReminderPageQuery`) all go through here, so they
/// cannot disagree again.
///
/// - A timed due (it has an hour) is an instant: overdue once `now` is past it.
/// - A date-only due is a day, not a midnight: overdue only once that day has ended, read in
///   `zone` (the host zone) in the Gregorian calendar (#299). A zone the components carry is
///   ignored, as `ReminderDueValue.chronologicalDate` ignores it: EventKit drops one given to
///   date-only components (#267), so the host zone is the only zone there is, the zone
///   `due_date_local` uses too. A reminder due today is not overdue at any time today.
enum ReminderDueReading {
    /// Nil without a due date (or with components that name no instant or day).
    static func isOverdue(_ due: DateComponents?, now: Date, zone: TimeZone) -> Bool? {
        guard let due else { return nil }
        guard let day = dateOnlyDay(due) else {
            return safeDateFromComponents(due).map { $0 < now }
        }
        let today = Calendar.gregorian(in: zone).dateComponents([.year, .month, .day], from: now)
        guard let ty = today.year, let tm = today.month, let td = today.day else { return nil }
        return (day.y, day.m, day.d) < (ty, tm, td)
    }

    /// The `due_date` sort: a date-only due sits at the start of its day (host zone, Gregorian),
    /// before every timed due of that day, and before a timed due at that very instant (00:00),
    /// so the order of that tie does not depend on the sort. A due sorts before no due.
    static func sortsBefore(_ a: DateComponents?, _ b: DateComponents?, zone: TimeZone) -> Bool {
        guard let first = sortKey(a, zone: zone) else { return false }
        guard let second = sortKey(b, zone: zone) else { return true }
        if first.instant != second.instant { return first.instant < second.instant }
        return first.dateOnly && !second.dateOnly
    }

    private static func sortKey(_ due: DateComponents?, zone: TimeZone) -> (instant: Date, dateOnly: Bool)? {
        guard let due else { return nil }
        if let day = dateOnlyDay(due) {
            let start = Calendar.gregorian(in: zone).date(from: DateComponents(year: day.y, month: day.m, day: day.d))
            return start.map { ($0, true) }
        }
        return safeDateFromComponents(due).map { ($0, false) }
    }

    /// The Gregorian year/month/day of a date-only due, or nil for a timed one.
    private static func dateOnlyDay(_ due: DateComponents) -> (y: Int, m: Int, d: Int)? {
        guard due.hour == nil, let day = ReminderDueInput.gregorianDay(of: due),
              let y = day.year, let m = day.month, let d = day.day else { return nil }
        return (y, m, d)
    }

    /// The start as the `start` object reports it. Under a date-only due, a start the store hands
    /// back as 00:00 floating (hour 0, minute and second 0 or absent, no nanosecond, no zone) is
    /// the date-only start #267 writes (on device, iCloud, 2026-10-09: the store returns a
    /// date-only start that way), so it is read as a day, like the due. Any other start, and every
    /// start under a timed due, is reported as stored: under a timed due a date-only start and a
    /// start set to midnight read back the same, and EventKit has no all-day property to tell
    /// them apart.
    static func startAsRead(_ start: DateComponents?, due: DateComponents?) -> DateComponents? {
        guard let start, let due, due.hour == nil, start.hour == 0,
              (start.minute ?? 0) == 0, (start.second ?? 0) == 0,
              start.nanosecond == nil, start.timeZone == nil else { return start }
        var day = start
        day.hour = nil
        day.minute = nil
        day.second = nil
        return day
    }
}
