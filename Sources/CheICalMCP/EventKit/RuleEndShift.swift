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
/// the listing does not reach (the margin #285 and #442 list with). Refused as not checked (PR #510
/// round 2): an all-day series with an end, whose rule end was not compared with its days on a device.
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

    /// One end to check: `rule`, the end the moved starts are compared with, and `listAround`, where
    /// the series' occurrences are listed (PR #510 round 2, LOW 3: a passed end years after the stored
    /// one listed nothing and refused; the occurrences only reach the stored end).
    struct End: Equatable {
        let rule: Date
        let listAround: Date
    }

    /// Why a write cannot be checked (PR #510 round 2). Each refuses, and none has a route through
    /// this tool: a retry with a passed rule meets the same cause.
    enum Unchecked: Equatable { case unreadable, unlisted, unplaced, tooFar, allDay }

    /// What the refusal offers (PR #510 round 2, LOW 6): the passed rule only for a rule this tool can
    /// write and a call that can carry it; through an occurrence's own id (#416, #428) a call that
    /// moves the start cannot also pass the rule.
    enum Route: Equatable { case passRule, unwritableRule, ownOccurrence }

    static func route(ruleWritable: Bool, addressesOwnOccurrence: Bool) -> Route {
        addressesOwnOccurrence ? .ownOccurrence : (ruleWritable ? .passRule : .unwritableRule)
    }

    /// The series' rules as read, or nil when none could be read (PR #510 round 2, HIGH 1). The check
    /// runs only on a series known to repeat, so no series object, or one with no rules, is a failure
    /// to read, not a rule with no end.
    static func readRules<Rule>(_ rules: [Rule]?) -> [Rule]? {
        guard let rules, !rules.isEmpty else { return nil }
        return rules
    }

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
    /// (PR #510 round 1, MEDIUM 6: the store expands a passed rule up to its end just the same),
    /// listed around the earlier of it and the latest stored end. A count or no end is not checked
    /// (not measured to drop at the end; #455 measured clear_timezone dropping a count series' last
    /// occurrence, which this check does not cover); clear_recurrence leaves one event.
    static func ends(stored: [Date], passedRule: PassedRule?) -> [End] {
        switch passedRule {
        case nil: return stored.map { End(rule: $0, listAround: $0) }
        case .end(let end)?: return [End(rule: end, listAround: min(end, stored.max() ?? end))]
        case .count?, .open?, .clear?: return []
        }
    }

    /// The new start is already after the end: nothing the write reaches would remain.
    static func startsPastEnd(plannedStart: Date, ruleEnd: Date) -> Bool {
        plannedStart > ruleEnd
    }

    private static func shift(_ plan: Plan) -> TimeInterval {
        plan.storedStarts.map { max(0, plan.plannedStart.timeIntervalSince($0)) }.max() ?? 0
    }

    /// A move later than `maxShift` (PR #510 round 1, MEDIUM 3; round 2, MEDIUM 2: refused with its
    /// own reason, since a passed rule does not change the move).
    static func exceedsMaxShift(_ plan: Plan) -> Bool {
        shift(plan) > maxShift
    }

    /// What to list around one rule end: the slots the move can push past it, and a year on each
    /// side, so an occurrence edited on its own and moved up to a year is listed too. nil when the
    /// move is wider than `maxShift`.
    static func listingRange(ruleEnd: Date, plan: Plan) -> DateInterval? {
        guard !exceedsMaxShift(plan) else { return nil }
        return DateInterval(start: ruleEnd.addingTimeInterval(-(shift(plan) + slack + margin)), end: ruleEnd.addingTimeInterval(margin + 1))
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
        reached(slots: slots, ruleEnd: ruleEnd, from: from).first { slot in
            movedStarts(slot: slot, plan: plan).contains { $0 > ruleEnd }
        }
    }

    /// The slots a write reaches before `ruleEnd`, in order.
    private static func reached(slots: [Date], ruleEnd: Date, from: Date?) -> [Date] {
        slots.filter { slot in slot <= ruleEnd && (from.map { slot.timeIntervalSince($0) > -1 } ?? true) }.sorted()
    }

    /// The latest start a reading gives the occurrence at `slot`: the one the refusal names.
    static func latestMove(slot: Date, plan: Plan) -> Date {
        movedStarts(slot: slot, plan: plan).max() ?? slot
    }

    /// The end_date the refusal offers (PR #510 round 2, LOW 4): the latest start any reached
    /// occurrence may get, not only the first lost one's; taken again until it holds, since a later
    /// end reaches the occurrences between a passed end and the stored one.
    static func keepEnd(slots: [Date], ruleEnd: Date, plan: Plan, from: Date? = nil) -> Date {
        var end = ruleEnd
        for _ in 0...slots.count {
            let next = max(end, reached(slots: slots, ruleEnd: end, from: from).map { latestMove(slot: $0, plan: plan) }.max() ?? end)
            if next == end { break }
            end = next
        }
        return end
    }

    /// The decision, read only (PR #510 round 2): nil when the write keeps every occurrence it reaches
    /// before each end. `storedEnds`: the ends of the rules read (`readRules`); `list`: the series' own
    /// occurrences in a range, nil when they cannot be listed.
    static func refusal(storedEnds: [Date], passedRule: PassedRule?, plan: Plan, from: Date?, allDay: Bool, route: Route,
                        list: (DateInterval) -> [Listed]?) -> String? {
        let ends = ends(stored: storedEnds, passedRule: passedRule)
        guard !ends.isEmpty else { return nil }
        if allDay { return uncheckedReason(.allDay) }
        for end in ends {
            // PR #510 round 1 (MEDIUM 3): refused before any read when nothing would remain.
            if startsPastEnd(plannedStart: plan.plannedStart, ruleEnd: end.rule) {
                return pastEndReason(ruleEnd: end.rule, zone: plan.newZone)
            }
            if exceedsMaxShift(plan) { return uncheckedReason(.tooFar) }
            guard let range = listingRange(ruleEnd: end.listAround, plan: plan) else { return uncheckedReason(.tooFar) }
            guard let listed = list(range) else { return uncheckedReason(.unlisted) }
            guard let slots = place(listed) else { return uncheckedReason(.unplaced) }
            if let slot = firstLost(slots: slots, ruleEnd: end.rule, plan: plan, from: from) {
                return lostReason(slot: slot, ruleEnd: end.rule, movedTo: latestMove(slot: slot, plan: plan),
                                  keepEnd: keepEnd(slots: slots, ruleEnd: end.rule, plan: plan, from: from), zone: plan.newZone, route: route)
            }
        }
        return nil
    }

    private static func iso(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    /// PR #510 round 1 (LOW 9), round 2 (LOW 6): the recurrence route only where it can be taken; it
    /// was measured on a plain weekly rule.
    private static func routeText(_ route: Route, after: String) -> String {
        switch route {
        case .passRule:
            return "To keep it, pass the series' rule in the same call as recurrence, with an end_date at or after \(after) (measured to keep every occurrence on a weekly rule)."
        case .unwritableRule:
            return "This series' rule has parts this tool cannot write, so to move it, change the series in Calendar."
        case .ownOccurrence:
            return "This write goes through an occurrence edited on its own, and such a call cannot also pass the series' rule (#416), so to move it, change the series in Calendar."
        }
    }

    /// PR #510 round 1 (LOW 10): "may", since only some readings were measured; round 2 (LOW 5): the
    /// measured shapes, as the CHANGELOG lists them.
    static func lostReason(slot: Date, ruleEnd: Date, movedTo: Date, keepEnd: Date, zone: TimeZone, route: Route) -> String {
        "Cannot move the start or zone of this recurring event: the series' rule ends at \(iso(ruleEnd, zone)), and the occurrence at "
            + "\(iso(slot, zone)) may start as late as \(iso(movedTo, zone)) after this write, after that end, so the store may drop it and "
            + "undo cannot bring it back (#509; measured on iCloud to drop an occurrence: a later time or day on a weekly series, a zone "
            + "change across a daylight-saving change, a plain monthly series moved to the next month, and the series' rule passed again "
            + "with the same end; the other cases are read from the rule). Nothing was written. " + routeText(route, after: iso(keepEnd, zone))
    }

    static func pastEndReason(ruleEnd: Date, zone: TimeZone) -> String {
        "Cannot move the start of this recurring event after the end of the series' rule (\(iso(ruleEnd, zone))): no occurrence it "
            + "moves would remain, and undo cannot bring them back (#509). Nothing was written."
    }

    /// PR #510 round 2 (MEDIUM 2, LOW 3, LOW 7): each cause in its own words, and Calendar as the
    /// route, since a retry through this tool meets the same cause.
    static func uncheckedReason(_ cause: Unchecked) -> String {
        let why: String
        switch cause {
        case .unreadable: why = "the series or its rule could not be read"
        case .unlisted: why = "the series' occurrences near that end could not be listed"
        case .unplaced: why = "an occurrence edited on its own near that end has no original slot in its identifier"
        case .tooFar: why = "the start moves later by more than a year, more than the check lists"
        case .allDay: why = "it is an all-day series before or after the write, and how an all-day rule's end compares with its days was not measured"
        }
        return "Cannot move the start or zone of this recurring event: the series' rule ends at a fixed time, and whether the move would "
            + "push an occurrence past it cannot be checked (#509): \(why). Nothing was written. To move it, change the series in Calendar."
    }
}
