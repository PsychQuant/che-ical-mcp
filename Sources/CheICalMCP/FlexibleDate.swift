import Foundation

/// The server's flexible date parser (`parseFlexibleDate`), shared by the event and reminder
/// tools. It accepts:
/// 1. full ISO8601: "2026-02-06T14:00:00+08:00" (the offset is explicit);
/// 2. ISO8601 without an offset: "2026-02-06T14:00:00", read in `defaultTimezone`;
/// 3. a date: "2026-02-06", 00:00:00 of that day in `defaultTimezone` (the first instant of the
///    day when the zone skips that midnight and the caller opts in, #546);
/// 4. a time: "14:00" or "14:00:00", that time today in `defaultTimezone`.
/// `defaultTimezone` nil means the host zone.
///
/// #299: the year a caller types is a Gregorian year. Every formatter here is POSIX and
/// Gregorian, and the time path uses the Gregorian calendar, so the host's region calendar
/// (Buddhist, ROC, Japanese, …) never reads it as another year.
enum FlexibleDate {
    static func parse(_ string: String, defaultTimezone: TimeZone? = nil, now: Date = Date(),
                      iso: ISO8601DateFormatter, allowSkippedMidnight: Bool = false) throws -> Date {
        // 1. Full ISO8601 (with timezone) — offset is explicit, no ambiguity
        if let date = iso.date(from: string) {
            return date
        }

        let tz = defaultTimezone ?? TimeZone.current

        // 2. ISO8601 without timezone (e.g., "2026-02-06T14:00:00")
        if string.contains("T") && !string.contains("+") && !string.contains("Z") {
            if let date = formatter("yyyy-MM-dd'T'HH:mm:ss", zone: tz).date(from: string) {
                return date
            }
        }

        // 3. Date only (e.g., "2026-02-06")
        if string.count == 10 && string.contains("-") && !string.contains("T") {
            if let date = formatter("yyyy-MM-dd", zone: tz).date(from: string) {
                return date
            }
            if allowSkippedMidnight, let date = firstInstant(ofDay: string, in: tz) {
                return date
            }
        }

        // 4. Time only (e.g., "14:00" or "14:00:00")
        if !string.contains("-") && string.contains(":") {
            let components = string.split(separator: ":")
            if components.count >= 2,
               let hour = Int(components[0]),
               let minute = Int(components[1]) {
                let second = components.count >= 3 ? Int(components[2]) ?? 0 : 0
                let cal = Calendar.gregorian(in: tz)
                var dc = cal.dateComponents([.year, .month, .day], from: now)
                dc.hour = hour
                dc.minute = minute
                dc.second = second
                if let date = cal.date(from: dc) {
                    return date
                }
            }
        }

        throw invalidDate(string)
    }

    /// #584: the last instant of the day a plain `YYYY-MM-DD` names in `zone`: the first instant
    /// of the next day minus one second, so a day whose next midnight is skipped still ends at its own
    /// 23:59:59. nil for any other form, or for a date that does not exist (the spelling is checked as
    /// `firstInstant(ofDay:in:)` checks it). A date-only `recurrence.end_date` is stored as this, so
    /// the occurrence on that day is in the series at any time of day.
    static func endOfDay(ofDateOnly string: String, in zone: TimeZone) -> Date? {
        guard let start = firstInstant(ofDay: string, in: zone) else { return nil }
        let calendar = Calendar.gregorian(in: zone)
        guard let laterNoon = calendar.date(byAdding: .hour, value: 36, to: start) else { return nil }
        return calendar.startOfDay(for: laterNoon).addingTimeInterval(-1)
    }

    static func invalidDate(_ string: String) -> ToolError {
        return ToolError.invalidParameter("'\(string)' is not a valid date. Supported formats: ISO8601 (2026-02-06T14:00:00+08:00), datetime (2026-02-06T14:00:00), date (2026-02-06), time (14:00)")
    }

    /// #546: the first instant of the day `string` names, for a day the formatter above cannot read
    /// in `zone` because its 00:00 does not exist there (the zone moves its clock from 23:59:59 to
    /// 01:00, as `America/Havana` does on 2028-03-12). The value is read by the same formatter in
    /// UTC, which skips no time, so only a calendar date in that exact form gets this far (#299:
    /// `2026-02-30` stays refused). Noon anchors the day in `zone`; a civil date skipped in full
    /// fails the day check below.
    static func firstInstant(ofDay string: String, in zone: TimeZone) -> Date? {
        let bytes = string.utf8
        guard bytes.count == 10,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 ? byte == 0x2D : (0x30...0x39).contains(byte)
              }) else { return nil }
        let utc = TimeZone(identifier: "UTC")!
        let dateOnly = formatter("yyyy-MM-dd", zone: utc)
        guard let utcMidnight = dateOnly.date(from: string),
              dateOnly.string(from: utcMidnight) == string else { return nil }
        var parts = Calendar.gregorian(in: utc).dateComponents([.year, .month, .day], from: utcMidnight)
        parts.hour = 12
        let calendar = Calendar.gregorian(in: zone)
        guard let noon = calendar.date(from: parts) else { return nil }
        let start = calendar.startOfDay(for: noon)
        let day = calendar.dateComponents([.year, .month, .day], from: start)
        guard day.year == parts.year, day.month == parts.month, day.day == parts.day else { return nil }
        return start
    }

    /// A fixed-format formatter for input, in `zone`. Its calendar comes from its locale, and
    /// `en_US_POSIX` is Gregorian whatever the host's region settings say. The calendar is
    /// deliberately not assigned on top: a formatter given an explicit `Calendar` rolls a date
    /// that does not exist over (`2026-02-30` parsed as March 2), where the locale's own calendar
    /// refuses it, as the parser always has (#299, checked with Foundation 2026-10-10).
    static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }
}
