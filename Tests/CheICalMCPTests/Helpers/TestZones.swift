import Foundation

/// #270 round 4: an event zone for the zone-behaviour tests that differs from the host's at the
/// instant tested, so those tests discriminate on any host (with the host in America/New_York a
/// New York event zone made a host-zone mutation pass). America/New_York, unless the host has
/// New York's offset then; Asia/Tokyo in that case.
enum TestZones {
    static func eventZone(differingFromHostAt instant: Date) -> TimeZone {
        let newYork = TimeZone(identifier: "America/New_York")!
        if newYork.secondsFromGMT(for: instant) != TimeZone.current.secondsFromGMT(for: instant) { return newYork }
        return TimeZone(identifier: "Asia/Tokyo")!
    }

    /// Midnight of `yyyy-MM-dd` in `zone`.
    static func midnight(_ day: String, in zone: TimeZone) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    /// A probe instant on that day, for choosing the zone.
    static func noonUTC(_ day: String) -> Date {
        ISO8601DateFormatter().date(from: day + "T12:00:00Z")!
    }
}
