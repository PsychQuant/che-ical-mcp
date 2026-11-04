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

        /// Values without an offset that give `writtenDay` back under the all-day rule. For the
        /// start, the bare date. For the end, the last second of that day or the bare date of the
        /// day after (an exclusive end): a bare `writtenDay` as end_time after the first day would
        /// exclude it (PR #387 verify round 1).
        var suggestedValues: [String] {
            guard field == "end_time" else { return [writtenDay] }
            return [writtenDay + "T23:59:59", AllDayOffsetWarning.dayAfter(writtenDay) ?? writtenDay + "T23:59:59"]
        }

        /// - Parameter skipped: the create was answered `skipped` (an existing duplicate): nothing
        ///   was written, so the message speaks of the request's dates, not the event's (PR #387
        ///   verify round 3: the existing event's own dates can differ).
        func dictionary(hostZone: TimeZone, skipped: Bool = false) -> [String: Any] {
            let isStart = field == "start_time"
            let outcome = skipped
                ? "the request's dates would be written \(isStart ? "starting" : "ending") on \(hostDay), and the existing event was not changed."
                : "the event \(isStart ? "starts" : "ends") on \(hostDay)."
            let hint: String
            if isStart {
                hint = outcome + " To start on \(writtenDay), send start_time \(writtenDay) without an offset."
            } else {
                let values = suggestedValues
                hint = outcome + " To end on \(writtenDay), send end_time \(values[0]) without an offset, "
                    + "or the bare date \(values[1]) (the day after, an exclusive end)."
            }
            let which = field == "start_time" ? "first" : "last"
            return [
                "field": field,
                "written_day": writtenDay,
                "host_day": hostDay,
                "message": "\(field) carries an offset that puts the \(which) day on \(writtenDay), but all-day dates "
                    + "are read in this Mac's time zone (\(hostZone.identifier)), where it is \(hostDay); " + hint,
            ]
        }
    }

    /// The offset a full ISO 8601 value was parsed with, or nil when the value has none (a date,
    /// a local date-time, a time). Read from the parsed instant (the wall clock of the value's
    /// first 19 characters, taken as UTC, minus the instant), so every suffix the server's parser
    /// accepts counts: `Z`, `z`, `±hh:mm`, `±hhmm`, `±hh`, `UTC`, `GMT+7` (PR #387 verify round 2).
    /// - Parameter parsed: the date the server parsed from `text`.
    static func writtenOffset(_ text: String, parsed: Date) -> TimeZone? {
        // A local date-time is exactly the 19-character wall clock; anything after it is an offset.
        guard text.count > wallClockLength, text.contains("T"),
              let wall = FlexibleDate.formatter("yyyy-MM-dd'T'HH:mm:ss", zone: TimeZone(secondsFromGMT: 0)!)
                .date(from: String(text.prefix(wallClockLength))) else { return nil }
        return TimeZone(secondsFromGMT: Int(wall.timeIntervalSince(parsed).rounded()))
    }

    private static let wallClockLength = 19

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
        if let startText, let zone = writtenOffset(startText, parsed: start) {
            writtenFirst = day(start, Calendar.gregorian(in: zone))
            if writtenFirst != hostFirst {
                result.append(Warning(field: "start_time", writtenDay: writtenFirst, hostDay: hostFirst))
            }
        }
        if let endText, let zone = writtenOffset(endText, parsed: end) {
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
    static func responseFields(_ warnings: [Warning], hostZone: TimeZone, skipped: Bool = false) -> [String: Any] {
        warnings.isEmpty ? [:] : ["warnings": warnings.map { $0.dictionary(hostZone: hostZone, skipped: skipped) }]
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

    /// The `yyyy-MM-dd` after `day` (a calendar date, so computed in UTC Gregorian).
    static func dayAfter(_ day: String) -> String? {
        let utc = Calendar.gregorian(in: TimeZone(secondsFromGMT: 0)!)
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = utc.date(byAdding: .day, value: 1, to: date) else { return nil }
        return Self.day(next, utc)
    }

    /// `yyyy-MM-dd` of `date` in `calendar` (Gregorian, so the strings sort as dates).
    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
