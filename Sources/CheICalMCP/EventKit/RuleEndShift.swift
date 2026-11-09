import Foundation

/// #509: EventKit keeps a series' rule end (`recurrenceEnd.endDate`) as a fixed instant, and the end
/// is inclusive. A start change over the rest of a series (span `all`, or span `future`, which splits
/// the series) re-expands the rule from the new start up to that same instant, so every occurrence
/// whose moved start falls after the end is dropped, and `update_event` answered `updated` (device,
/// iCloud, 2026-11-09; the table is in #509's Diagnosis). Undo refuses recurring updates, so nothing
/// brought the occurrence back.
///
/// Measured (weekly series in Asia/Taipei): a plain rule shifts whole by the start's change (a day
/// earlier and an hour later kept all five); a zone change alone between zones without daylight
/// saving (Asia/Bangkok, Asia/Tokyo) kept the instants; passing the rule again in the same call with
/// an `end_date` at or after the moved start kept every occurrence, with span `all` and `future`.
/// Read from the rule's semantics, not measured, and checked as well (PR #510 round 1, fail closed):
/// the store re-expands by the wall clock in the zone the event then has, so a zone change across a
/// daylight-saving change can move occurrences; a plain monthly or yearly rule repeats on the new
/// start's day of the month; a rule with days of its own keeps its days at the new time of day.
///
/// Not covered: an earlier move that brings in an occurrence after the end (nothing is lost, and it
/// is visible), and an occurrence edited on its own and moved more than a year from its slot, which
/// the listing does not reach (the margin #285 and #442 list with).
enum RuleEndShift {
    /// How a plain rule repeats: by days (daily, weekly), months or years.
    enum Unit: Equatable { case day, month, year }

    /// What the write does to the series' start, read before any field is assigned.
    /// `storedStarts`: the start the store re-expands from, read as the shown start and, through an
    /// occurrence's own id, also as its original slot (PR #510 round 1, HIGH 2).
    struct Plan: Equatable {
        let storedStarts: [Date]
        let plannedStart: Date
        let storedZone: TimeZone
        let newZone: TimeZone
        let unit: Unit
        let keepsDays: Bool
    }

    /// A listed occurrence of the series, as `place` reads it.
    struct Listed: Equatable {
        let isDetached: Bool
        let ridSlot: Date?
        let occurrenceDate: Date?
        let start: Date
    }

    /// The rule a call passes, as far as its end goes.
    enum PassedRule: Equatable { case end(Date), count, open, clear }

    /// The widest start change checked: past it the listing would be long, so it is refused.
    static let maxShift: TimeInterval = 366 * 86_400
    /// Room for a change of the time of day, the zones' offsets and month lengths.
    static let slack: TimeInterval = 5 * 86_400
    /// How far from its slot an occurrence edited on its own is still listed (as #285 and #442 list).
    static let margin: TimeInterval = 366 * 86_400

    /// The routes through an occurrence's own id (#416, #428) read an object with no rules of its own.
    static func repeats(masterHasRules: Bool, addressesOwnOccurrence: Bool) -> Bool {
        masterHasRules || addressesOwnOccurrence
    }

    /// Whether the check runs: a start or zone change over the rest of a series.
    static func applies(repeats: Bool, reachesEnd: Bool, movesStart: Bool, changesZone: Bool) -> Bool {
        repeats && reachesEnd && (movesStart || changesZone)
    }

    /// The ends to check: the stored rule's, or, when the call passes a rule, that rule's own end
    /// (PR #510 round 1, MEDIUM 6: the store expands a passed rule up to its end just the same). A
    /// count or no end drops nothing at the end; clear_recurrence leaves one event.
    static func ends(stored: [Date], passedRule: PassedRule?) -> [Date] {
        switch passedRule {
        case nil: return stored
        case .end(let end)?: return [end]
        case .count?, .open?, .clear?: return []
        }
    }

    /// The new start is already after the end: nothing the write reaches would remain.
    static func startsPastEnd(plannedStart: Date, ruleEnd: Date) -> Bool {
        plannedStart > ruleEnd
    }

    /// What to list around one rule end: the slots the move can push past it, and a year on each
    /// side, so an occurrence edited on its own and moved up to a year is listed too. nil when the
    /// move is wider than `maxShift` (PR #510 round 1, MEDIUM 3: refused as not checkable).
    static func listingRange(ruleEnd: Date, plan: Plan) -> DateInterval? {
        let shift = plan.storedStarts.map { max(0, plan.plannedStart.timeIntervalSince($0)) }.max() ?? 0
        guard shift <= maxShift else { return nil }
        return DateInterval(start: ruleEnd.addingTimeInterval(-(shift + slack + margin)), end: ruleEnd.addingTimeInterval(margin + 1))
    }

    /// The original slots of the listed occurrences: an occurrence edited on its own counts by its
    /// `/RID=` slot, wherever it shows. nil when one cannot be placed (edited, without that slot) or
    /// nothing is listed: an empty listing is never safe (PR #510 round 1, HIGH 1).
    static func place(_ listed: [Listed]) -> [Date]? {
        guard !listed.isEmpty else { return nil }
        var slots: [Date] = []
        for occurrence in listed {
            if let rid = occurrence.ridSlot {
                slots.append(rid)
            } else if occurrence.isDetached {
                return nil
            } else {
                slots.append(occurrence.occurrenceDate ?? occurrence.start)
            }
        }
        return slots
    }

    /// Where the occurrence at `slot` can start after the write, every reading of it (fail closed):
    /// the start's change as elapsed time and by the wall clock in either zone; the rule re-expanded
    /// from the new start in the new zone by its unit (days, months, years); and, for a rule with days
    /// of its own, the slot's day at the new time of day.
    static func movedStarts(slot: Date, plan: Plan) -> [Date] {
        let newCalendar = Calendar.gregorian(in: plan.newZone)
        var moved: [Date] = []
        for stored in plan.storedStarts {
            moved.append(slot.addingTimeInterval(plan.plannedStart.timeIntervalSince(stored)))
            for zone in [plan.storedZone, plan.newZone] {
                let calendar = Calendar.gregorian(in: zone)
                let change = calendar.dateComponents([.day, .hour, .minute, .second], from: stored, to: plan.plannedStart)
                if let date = calendar.date(byAdding: change, to: slot) { moved.append(date) }
            }
            let units: Set<Calendar.Component> = {
                switch plan.unit {
                case .day: return [.day, .hour, .minute, .second]
                case .month: return [.month, .day, .hour, .minute, .second]
                case .year: return [.year, .day, .hour, .minute, .second]
                }
            }()
            let periods = Calendar.gregorian(in: plan.storedZone).dateComponents(units, from: stored, to: slot)
            if let date = newCalendar.date(byAdding: periods, to: plan.plannedStart) { moved.append(date) }
        }
        guard plan.keepsDays else { return moved }
        let time = newCalendar.dateComponents([.hour, .minute, .second], from: plan.plannedStart)
        for zone in [plan.storedZone, plan.newZone] {
            var parts = Calendar.gregorian(in: zone).dateComponents([.year, .month, .day], from: slot)
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
            if let date = newCalendar.date(from: parts) { moved.append(date) }
        }
        return moved
    }

    /// The first slot at or before `ruleEnd` (and, for span future, at or after `from`, the slot the
    /// write starts at: PR #510 round 1, LOW 8) that some reading moves past the end, or nil.
    static func firstLost(slots: [Date], ruleEnd: Date, plan: Plan, from: Date? = nil) -> Date? {
        slots.filter { slot in slot <= ruleEnd && (from.map { slot.timeIntervalSince($0) > -1 } ?? true) }.sorted().first { slot in
            movedStarts(slot: slot, plan: plan).contains { $0 > ruleEnd }
        }
    }

    /// The latest start a reading gives the occurrence at `slot`: the one the refusal names.
    static func latestMove(slot: Date, plan: Plan) -> Date {
        movedStarts(slot: slot, plan: plan).max() ?? slot
    }

    private static func iso(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    /// PR #510 round 1 (LOW 9): the recurrence route only for a rule this tool can write; it was
    /// measured on a plain weekly rule.
    private static func route(_ ruleWritable: Bool, after: String) -> String {
        ruleWritable
            ? "To keep it, pass the series' rule in the same call as recurrence, with an end_date at or after \(after) (measured to keep every occurrence on a weekly rule)."
            : "This series' rule has parts this tool cannot write, so to move it, change the series in Calendar."
    }

    /// PR #510 round 1 (LOW 10): "may", since only some readings were measured.
    static func lostReason(slot: Date, ruleEnd: Date, movedTo: Date, zone: TimeZone, ruleWritable: Bool) -> String {
        "Cannot move the start or zone of this recurring event: the series' rule ends at \(iso(ruleEnd, zone)), and the occurrence at "
            + "\(iso(slot, zone)) may start as late as \(iso(movedTo, zone)) after this write, after that end, so the store may drop it and "
            + "undo cannot bring it back (#509; measured for a later time and a later day on a plain weekly rule, read from the rule "
            + "for the other cases). Nothing was written. " + route(ruleWritable, after: iso(movedTo, zone))
    }

    static func pastEndReason(ruleEnd: Date, zone: TimeZone) -> String {
        "Cannot move the start of this recurring event after the end of the series' rule (\(iso(ruleEnd, zone))): no occurrence it "
            + "moves would remain, and undo cannot bring them back (#509). Nothing was written."
    }

    static func unknownReason(ruleWritable: Bool) -> String {
        "Cannot move the start or zone of this recurring event: the series' rule ends at a fixed time, and whether the move would push "
            + "an occurrence past it cannot be checked (#509): the series could not be listed near that end, an occurrence edited on its "
            + "own there has no original slot in its identifier, or the move is more than a year. Nothing was written. "
            + (ruleWritable
               ? "To move it, pass the series' rule in the same call as recurrence, with an end_date at or after the last occurrence's new start."
               : "This series' rule has parts this tool cannot write, so to move it, change the series in Calendar.")
    }
}
