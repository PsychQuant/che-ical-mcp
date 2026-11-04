import Foundation

/// #5 / #373 verify round 2: the zone in which `update_event` reads the weekday of the planned
/// start when it checks a weekly recurrence's days.
enum WeekdayCheck {
    /// The zone the event will have after the update; nil means the host zone.
    ///
    /// An all-day result has no zone: EventKit clears `timeZone` when `isAllDay` becomes true, and
    /// the check used to run after that assignment, so an all-day result was read in the host
    /// zone, the zone `AllDayRange.planUpdate` takes its midnights from. (A requested zone with an
    /// all-day result is refused before this check, #190.) A timed result takes the requested
    /// zone, else none when it is cleared, else the stored one.
    static func zone(resultIsAllDay: Bool, requested: TimeZone?, clearTimezone: Bool, stored: TimeZone?) -> TimeZone? {
        if resultIsAllDay { return nil }
        return requested ?? (clearTimezone ? nil : stored)
    }

    /// The weekday (1 = Sunday … 7 = Saturday) of `start` in that zone, else in `host`'s zone.
    static func weekday(of start: Date, resultIsAllDay: Bool, requested: TimeZone?, clearTimezone: Bool,
                        stored: TimeZone?, host: Calendar) -> Int {
        var calendar = host
        if let tz = zone(resultIsAllDay: resultIsAllDay, requested: requested, clearTimezone: clearTimezone, stored: stored) {
            calendar.timeZone = tz
        }
        return calendar.component(.weekday, from: start)
    }
}
