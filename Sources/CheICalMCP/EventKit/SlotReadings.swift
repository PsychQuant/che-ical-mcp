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
/// process places a floating event in).
///
/// PR #558 fix round 4: one reader takes both, the #321 check whether a restored series holds a deleted
/// occurrence's slot (`OccurrenceSlotGuard.answer`, through `OccurrenceOrigin.of`), and only for an
/// occurrence of a series that has no time zone when it is read (ruling J). It answers held by the instant
/// reading, as before #539, and refuses, writing nothing, where only the wall-clock reading is held (ruling
/// F). Every other reader of a `/RID=` reads the instant only (`UndoPostState.ruleSlot`), the capture and
/// the restore of a whole-series delete included: they are `main`'s (rounds 0 to 3 read both there, and
/// each round found a shape worse than `main`).
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
    /// `zone` a time that does not exist, or exists twice, is placed by Foundation's rule. Measured on
    /// iCloud (2026-11-17, a process at America/Los_Angeles, one 30-minute weekly occurrence each): 02:30
    /// on 2027-03-14 was listed at 03:30 PDT and 01:30 on 2027-11-07 at 01:30 PDT, both Foundation's
    /// instants.
    static func wallClock(of rid: Date, in zone: TimeZone) -> Date? {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: rid)
        return local.date(from: parts)
    }
}
