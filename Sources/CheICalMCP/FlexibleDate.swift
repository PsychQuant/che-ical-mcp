import Foundation

/// The server's flexible date parser (`parseFlexibleDate`), shared by the event and reminder
/// tools. It accepts:
/// 1. full ISO8601: "2026-02-06T14:00:00+08:00" (the offset is explicit);
/// 2. ISO8601 without an offset: "2026-02-06T14:00:00", read in `defaultTimezone`;
/// 3. a date: "2026-02-06", 00:00:00 of that day in `defaultTimezone`;
/// 4. a time: "14:00" or "14:00:00", that time today in `defaultTimezone`.
/// `defaultTimezone` nil means the host zone.
///
/// #299: the year a caller types is a Gregorian year. Every formatter here is POSIX and
/// Gregorian, and the time path uses the Gregorian calendar, so the host's region calendar
/// (Buddhist, ROC, Japanese, …) never reads it as another year.
enum FlexibleDate {
    static func parse(_ string: String, defaultTimezone: TimeZone? = nil, now: Date = Date(),
                      iso: ISO8601DateFormatter) throws -> Date {
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

        throw ToolError.invalidParameter("'\(string)' is not a valid date. Supported formats: ISO8601 (2026-02-06T14:00:00+08:00), datetime (2026-02-06T14:00:00), date (2026-02-06), time (14:00)")
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
