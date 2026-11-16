import Foundation

/// #539: the instants an edited occurrence's slot can be, read from its identifier.
///
/// An occurrence edited on its own reads back as `<series id>/RID=<seconds since 2001-01-01>`
/// (#311). What the digits mean depends on the series when that occurrence was first edited, not on
/// the series now (measured on iCloud, 2026-11-13, #539 cell R2: one series held both kinds):
/// - edited while the series had a time zone, the digits are the slot's instant;
/// - edited while a timed series had no time zone (floating, after `clear_timezone`), the digits are
///   the slot's wall-clock time written as if it were UTC. Read as an instant it is off by the host's
///   UTC offset (8 hours at `+08:00`), and only a host at UTC reads it right.
/// The identifier does not say which, so a timed `/RID=` has two readings: `instant`, and `wallClock`,
/// the same digits taken as year, month, day, hour, minute and second in `zone` (the zone this
/// process places a floating event in). A reading counts only once it is placed on a slot the
/// series' rule gives (`place(among:)`); a reader with no rule slots at hand keeps `instant`, which is
/// what `UndoPostState.ruleSlot` gave before #539.
///
/// An all-day occurrence keeps its one reading (`UndoPostState.ruleSlot`'s local day), and so does an
/// occurrence without a `/RID=` (its `occurrenceDate`). On a host at offset 0 when the slot falls
/// (UTC, or a zone such as Europe/London in winter) the two readings are the same instant, and there
/// is one.
struct SlotReadings: Equatable {
    /// The reading `UndoPostState.ruleSlot` gives: the `/RID=` as an instant (an all-day one as its
    /// local day), or the `occurrenceDate` without one.
    let instant: Date
    /// The `/RID=` digits as wall-clock time in the reader's zone; nil for an all-day occurrence, one
    /// without a `/RID=`, or when it is the same instant as `instant`.
    let wallClock: Date?

    init(instant: Date, wallClock: Date? = nil) {
        self.instant = instant
        self.wallClock = wallClock.flatMap { UndoPostState.sameInstant($0, instant) ? nil : $0 }
    }

    /// Every reading, `instant` first.
    var all: [Date] { [instant] + (wallClock.map { [$0] } ?? []) }

    /// The largest UTC offset a zone has (Pacific/Kiritimati, `+14:00`); the two readings are never
    /// further apart. The restore lists the recreated series this much past each window, so a record
    /// whose true slot lies just outside can be placed there and dropped (`SeriesExceptionsPlanner`).
    static let largestOffset: TimeInterval = 14 * 3600

    /// The readings of an occurrence, from its identifiers (the event identifier first, as
    /// `UndoPostState.originalSlot` reads them). Nil with neither a `/RID=` nor an `occurrenceDate`.
    static func of(eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?,
                   isAllDay: Bool, zone: TimeZone = .current) -> SlotReadings? {
        guard let instant = UndoPostState.ruleSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                                   occurrenceDate: occurrenceDate, isAllDay: isAllDay, zone: zone) else { return nil }
        guard !isAllDay, let rid = UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                                               occurrenceDate: nil) else {
            return SlotReadings(instant: instant)
        }
        return SlotReadings(instant: instant, wallClock: wallClock(of: rid, in: zone))
    }

    /// The digits of `rid` (an instant as `originalSlot` reads them) taken as wall-clock time in UTC,
    /// and that wall-clock time placed in `zone` by `Calendar.date(from:)`. On a daylight-saving day in
    /// `zone` a time that does not exist, or exists twice, is placed by Foundation's rule, which may not
    /// be the instant the store gave that occurrence; then it is no slot of the rule and is not placed
    /// (`place(among:)`): fail closed. Not measured on a device.
    static func wallClock(of rid: Date, in zone: TimeZone) -> Date? {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: rid)
        return local.date(from: parts)
    }

    /// The reading that is one of `slots` (to the second, `UndoPostState.sameInstant`): the one reading
    /// that is, or nil when none is, or when both are. Both can be slots of one rule only if two of its
    /// slots lie the host's offset apart (14 hours at most), and EventKit's frequencies give no two
    /// slots of one rule closer than 23 hours (daily, weekly or monthly on adjacent days across a
    /// spring change); so "both" is a guard for a shape not seen.
    func place(among slots: InstantSet) -> Date? {
        let hits = all.filter { slots.contains($0) }
        return hits.count == 1 ? hits[0] : nil
    }

    func place(among slots: [Date]) -> Date? { place(among: InstantSet(slots)) }

    /// The placed reading when `slots` are at hand and exactly one reading is among them, otherwise
    /// `instant`: what a reader that changes with #539 but must stay as it was where nothing can be
    /// placed takes (`differsFromSeries`, `originalDay`, the #509 rule-end check).
    func slot(placedAmong slots: [Date]?) -> Date {
        guard let slots else { return instant }
        return place(among: slots) ?? instant
    }
}
