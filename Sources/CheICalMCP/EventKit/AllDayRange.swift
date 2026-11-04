import Foundation

/// #364 / #348: one meaning for the dates of an all-day event, whichever way it is written.
///
/// EventKit reads an all-day `endDate` differently depending on whether the event is already
/// all-day when the date is assigned (device, iCloud): on a new or still-timed event a midnight end
/// excludes that day; on an event that is already all-day it includes it. Every all-day write is
/// therefore normalized first to (start of the start day, last day at 23:59:59), the one value that
/// reads the same in both states and the one the tools return when they read the event back.
///
/// The rule (the exclusive boundary, the iCal `DTEND` reading): an end exactly at a midnight of a
/// day later than the start day excludes that day; any other end includes its day; start = end is
/// one day. Days are taken in `calendar`'s zone (the host zone for EventKit writes, #190: all-day
/// events are floating days), so an end written with another offset is converted first.
enum AllDayRange {
    /// - Returns: the start of the first day, and the last second of the last day.
    /// - Throws: `EventKitError.invalidTimeRange` when the last day falls before the first day.
    static func normalize(start: Date, end: Date, calendar: Calendar) throws -> (start: Date, end: Date) {
        let firstDay = calendar.startOfDay(for: start)
        var lastDay = calendar.startOfDay(for: end)
        if end == lastDay, lastDay > firstDay {
            // An exact midnight after the first day is a boundary: the day before it is the last one.
            lastDay = calendar.date(byAdding: .day, value: -1, to: lastDay) ?? lastDay
        }
        guard lastDay >= firstDay else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = calendar.timeZone
            throw EventKitError.invalidTimeRange(message:
                "The all-day event would end on \(formatter.string(from: lastDay)), before its first day \(formatter.string(from: firstDay)). "
                + "Pass the day after the last day as end_time (an exclusive end), or the first day itself for a one-day event.")
        }
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        return (firstDay, dayAfter.addingTimeInterval(-1))
    }
}
