import Foundation

/// #509: EventKit keeps a series' rule end (`recurrenceEnd.endDate`) as a fixed instant, and the end
/// is inclusive. A start change over the rest of a series (span `all`, or span `future`, which splits
/// the series) re-expands the rule from the new start up to that same instant, so every occurrence
/// whose moved start falls after the end is dropped, and `update_event` answered `updated` (device,
/// iCloud, 2026-11-09; the table is in #509's Diagnosis). Undo refuses recurring updates, so nothing
/// brought the occurrence back.
///
/// Measured: a plain rule shifts whole by the start's change (a day earlier and an hour later kept
/// all five); a time zone change alone keeps the instants; passing the rule again in the same call
/// with an `end_date` at or after the moved start kept every occurrence, with span `all` and with
/// span `future`. A rule with days of its own keeps its days and takes the new time of day; that is
/// read from the rule's semantics, not measured, so both readings are checked (fail closed).
///
/// Not covered: an earlier move that brings in an occurrence after the end. Nothing is lost there,
/// the added occurrence is visible, and finding it would mean computing the rule's next slot.
enum RuleEndShift {
    /// How far before a rule end an occurrence can sit and still be moved past it by a change of the
    /// time of day: under a day, plus the widest zone difference and the day either side.
    static let timeOfDayReach: TimeInterval = 2 * 86_400 + 2 * 3_600

    /// Whether the check runs: a start change over the rest of a series that keeps its stored rule.
    /// A call that writes a rule (or clears it) sets the end itself.
    static func applies(repeats: Bool, reachesEnd: Bool, writesRule: Bool, storedStart: Date, plannedStart: Date?) -> Bool {
        guard repeats, reachesEnd, !writesRule, let plannedStart else { return false }
        return plannedStart != storedStart
    }

    /// The slots to list before one rule end: back past the start's change and the time-of-day
    /// reach, up to just after the end (which is inclusive).
    static func listingWindow(ruleEnd: Date, storedStart: Date, plannedStart: Date) -> DateInterval {
        let shift = max(0, plannedStart.timeIntervalSince(storedStart))
        return DateInterval(start: ruleEnd.addingTimeInterval(-(shift + timeOfDayReach)), end: ruleEnd.addingTimeInterval(1))
    }

    /// Where the occurrence at `slot` can start after the write. A plain rule shifts it by the
    /// start's change, read both as elapsed time and by the wall clock (the store expands by the wall
    /// clock, so across a DST change a one-day move is 23 or 25 hours); a rule with days of its own
    /// keeps the slot's day at the new time of day, read with the day in either zone.
    static func movedStarts(slot: Date, storedStart: Date, plannedStart: Date,
                            storedZone: TimeZone, newZone: TimeZone, keepsDays: Bool) -> [Date] {
        var moved = [slot.addingTimeInterval(plannedStart.timeIntervalSince(storedStart))]
        for zone in [storedZone, newZone] {
            let calendar = Calendar.gregorian(in: zone)
            let change = calendar.dateComponents([.day, .hour, .minute, .second], from: storedStart, to: plannedStart)
            if let date = calendar.date(byAdding: change, to: slot) { moved.append(date) }
        }
        guard keepsDays else { return moved }
        let newCalendar = Calendar.gregorian(in: newZone)
        let time = newCalendar.dateComponents([.hour, .minute, .second], from: plannedStart)
        for zone in [storedZone, newZone] {
            var parts = Calendar.gregorian(in: zone).dateComponents([.year, .month, .day], from: slot)
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
            if let date = newCalendar.date(from: parts) { moved.append(date) }
        }
        return moved
    }

    /// The first slot, at or before `ruleEnd`, that the write would move past it, or nil.
    static func firstLost(slots: [Date], ruleEnd: Date, storedStart: Date, plannedStart: Date,
                          storedZone: TimeZone, newZone: TimeZone, keepsDays: Bool) -> Date? {
        slots.filter { $0 <= ruleEnd }.sorted().first { slot in
            movedStarts(slot: slot, storedStart: storedStart, plannedStart: plannedStart,
                        storedZone: storedZone, newZone: newZone, keepsDays: keepsDays).contains { $0 > ruleEnd }
        }
    }

    /// The latest start the write can give the occurrence at `slot`: the one the refusal names.
    static func latestMove(slot: Date, storedStart: Date, plannedStart: Date,
                           storedZone: TimeZone, newZone: TimeZone, keepsDays: Bool) -> Date {
        movedStarts(slot: slot, storedStart: storedStart, plannedStart: plannedStart,
                    storedZone: storedZone, newZone: newZone, keepsDays: keepsDays).max() ?? slot
    }

    static func lostReason(slot: Date, ruleEnd: Date, movedTo: Date, zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return "Cannot move the start of this recurring event: the series' rule ends at \(formatter.string(from: ruleEnd)), "
            + "and the occurrence at \(formatter.string(from: slot)) would start at \(formatter.string(from: movedTo)), after that end, "
            + "so the store would drop it and undo cannot bring it back (#509). Nothing was written. To keep it, pass the series' rule "
            + "in the same call as recurrence, with an end_date at or after \(formatter.string(from: movedTo))."
    }

    static let unknownReason = "Cannot move the start of this recurring event: the series' rule ends at a fixed time, and its "
        + "occurrences near that end could not be listed, so whether the move would drop one is not known (#509). Nothing was "
        + "written. To move it, pass the series' rule in the same call as recurrence, with an end_date at or after the last "
        + "occurrence's new start."
}
