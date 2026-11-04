import Foundation

/// #372: an all-day date written with an offset whose day differs from its day in this Mac's zone.
///
/// All-day dates are whole days read in the host zone (#364 D2, #190): a full ISO 8601 value with
/// another offset is converted to the host zone first, which can move it to another day. The event
/// is still written that way; this compares the days the call meant (the all-day rule of
/// `AllDayRange.normalize` applied in the offset the caller wrote) with the days it got (the same
/// rule in the host zone), so the response can say so. The comparison is on normalized days, not
/// on offsets: an offset that differs from the host's but lands on the same day does not warn, and
/// an end at an exact midnight in the written zone (an exclusive end) that is 01:00 in the host
/// zone (an inclusive day) does. A value without an offset is read in the host zone by definition
/// and never warns.
enum AllDayOffsetWarning {
    struct Warning: Equatable {
        /// `start_time` or `end_time`.
        let field: String
        /// The first day (`start_time`) or last day (`end_time`) in the offset the caller wrote.
        let writtenDay: String
        /// The same day in the host zone: the one the event is saved with.
        let hostDay: String

        func dictionary(hostZone: TimeZone) -> [String: Any] {
            let which = field == "start_time" ? "first" : "last"
            return [
                "field": field,
                "written_day": writtenDay,
                "host_day": hostDay,
                "message": "\(field) carries an offset that puts the \(which) day on \(writtenDay), but all-day dates "
                    + "are read in this Mac's time zone (\(hostZone.identifier)), where it is \(hostDay); the event "
                    + "uses \(hostDay). Send the date without an offset to mean \(writtenDay).",
            ]
        }
    }

    /// The offset written at the end of a full ISO 8601 value (`Z`, `±hh:mm`, `±hhmm`), or nil when
    /// the value has none (a date, a local date-time, a time).
    static func writtenOffset(_ text: String) -> TimeZone? {
        guard let timeStart = text.firstIndex(of: "T") else { return nil }
        let time = text[text.index(after: timeStart)...]
        if time.hasSuffix("Z") || time.hasSuffix("z") { return TimeZone(secondsFromGMT: 0) }
        guard let match = time.range(of: #"[+-][0-9]{2}:?[0-9]{2}$"#, options: .regularExpression) else { return nil }
        let suffix = time[match]
        let sign = suffix.first == "-" ? -1 : 1
        let digits = suffix.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    /// - Parameters:
    ///   - start, end: the dates of the all-day range the call produced (for `update_event`, the
    ///     saved event's date for a field the call did not give).
    ///   - startText, endText: the values the call gave, or nil for a field it did not give; only
    ///     given fields are checked.
    ///   - host: the calendar the write uses (`Calendar.gregorian(in: .current)`).
    static func warnings(start: Date, startText: String?, end: Date, endText: String?,
                         host: Calendar) -> [Warning] {
        let hostFirst = day(start, host)
        var writtenFirst = hostFirst
        var result: [Warning] = []
        if let startText, let zone = writtenOffset(startText) {
            writtenFirst = day(start, Calendar.gregorian(in: zone))
            if writtenFirst != hostFirst {
                result.append(Warning(field: "start_time", writtenDay: writtenFirst, hostDay: hostFirst))
            }
        }
        if let endText, let zone = writtenOffset(endText) {
            let writtenLast = lastDay(end, Calendar.gregorian(in: zone), firstDay: writtenFirst)
            let hostLast = lastDay(end, host, firstDay: hostFirst)
            if writtenLast != hostLast {
                result.append(Warning(field: "end_time", writtenDay: writtenLast, hostDay: hostLast))
            }
        }
        return result
    }

    /// `["warnings": [...]]`, or empty when there is nothing to report, so a response without a
    /// warning keeps its shape.
    static func responseFields(_ warnings: [Warning], hostZone: TimeZone) -> [String: Any] {
        warnings.isEmpty ? [:] : ["warnings": warnings.map { $0.dictionary(hostZone: hostZone) }]
    }

    /// The last day under `AllDayRange.normalize`'s rule: an end exactly at a midnight of a day
    /// later than the first day excludes that day.
    private static func lastDay(_ end: Date, _ calendar: Calendar, firstDay: String) -> String {
        let midnight = calendar.startOfDay(for: end)
        let endDay = day(midnight, calendar)
        guard end == midnight, endDay > firstDay,
              let dayBefore = calendar.date(byAdding: .day, value: -1, to: midnight) else { return endDay }
        return day(dayBefore, calendar)
    }

    /// `yyyy-MM-dd` of `date` in `calendar` (Gregorian, so the strings sort as dates).
    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
