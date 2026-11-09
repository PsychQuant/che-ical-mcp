import EventKit
import Foundation

/// #503 — measured on iCloud (2026-11-09): an `update_event` that changes the start, end or all-day
/// flag of more than one occurrence of a series (span `all`, span `future` from the first occurrence
/// or a later one, a time of day, a new date, `end_time` alone, `all_day`) brought back every
/// occurrence deleted on its own among the occurrences it reached, and answered `updated`.
/// Title, notes and location kept them, so did the stored start and end written again, and so did
/// `timezone` alone on a series that had not started. Undo refuses every recurring update, so
/// nothing restores the deletion. EventKit exposes no exception dates, so a deletion is found as a
/// slot the rule gives that no listed occurrence holds: this file expands the rule (narrowly) and
/// compares. Pure; the listing is `EventKitManager.deletedOccurrenceVerdict`.
enum DeletedOccurrenceCheck {
    /// A recurrence rule as the expander reads it. `daysOfWeek` are `EKWeekday` raw values (1 is
    /// Sunday), un-numbered; `hasOtherParts`: numbered weekdays, set positions, months, weeks or
    /// days of the year, which the expander does not follow.
    struct Rule: Equatable {
        let frequency: EKRecurrenceFrequency
        let interval: Int
        let daysOfWeek: [Int]
        let daysOfMonth: [Int]
        let endDate: Date?
        let occurrenceCount: Int
        let hasOtherParts: Bool
    }

    /// PR #505 round 3: why the span-future route is not offered, one text each (`deletedReason`).
    enum RouteBlock: Equatable {
        /// The listing does not cover the series, so a write from a later occurrence is unknown too.
        case notCovered
        /// An all_day change, which #451 refuses from a later occurrence.
        case allDay
        /// The series' first slot is not held, so the series' id resolves to a stand-in (unknown).
        case firstSlotMissing
        /// No occurrence that was not edited on its own follows the last deleted one; span future
        /// with a time field through an edited occurrence is refused (#416).
        case nothingAfter
    }

    enum Verdict: Equatable {
        /// Every slot the write reaches is listed, and the listing covers the series.
        case none
        /// A slot the write reaches has no occurrence: one was deleted on its own (or moved where the
        /// listing does not reach). `blocked`: why span future from an occurrence after the last
        /// deletion cannot pass this same check, nil when it can (PR #505 rounds 1-3).
        case deleted(blocked: RouteBlock?)
        /// The check cannot tell: the rule cannot be followed, or the listing does not cover it.
        case unknown
    }

    /// Whether the write is the measured shape: it reaches more than one occurrence, keeps the rule,
    /// and changes the start, the end or the all-day flag (the stored values written again kept them).
    /// PR #505 round 2 (LOW 6, measured on iCloud 2026-11-09): a time-zone change brought a deletion
    /// back across a daylight-saving divergence (span all on a series not started; span future from an
    /// occurrence still to come on a started one), so `changesZone` counts too. A `recurrence` with only
    /// its end changed and a `calendar_name` in the same account kept them (measured).
    static func applies(reachesSeveral: Bool, clearingRecurrence: Bool, plannedDates: (Date, Date)?,
                        storedStart: Date, storedEnd: Date, resultAllDay: Bool, storedAllDay: Bool,
                        changesZone: Bool, changesAccount: Bool) -> Bool {
        guard reachesSeveral, !clearingRecurrence else { return false }
        if resultAllDay != storedAllDay || changesZone || changesAccount { return true }
        guard let (start, end) = plannedDates else { return false }
        return !UndoPostState.sameInstant(start, storedStart) || !UndoPostState.sameInstant(end, storedEnd)
    }

    /// One rule only, followed by `expectedSlots`. A slot the write reaches (`reachedFrom` on) and
    /// the listing reaches (up to `scannedTo`) with no listed occurrence is a deletion; otherwise
    /// the answer is `none` only when the listing covers the whole series.
    /// PR #505 round 1: `firstStart` is the series' first slot as `firstSlot` proves it, nil when it
    /// cannot (then unknown: never counted again from another start, HIGH). `slotsTrusted` is false
    /// when an occurrence edited on its own was listed without its `/RID=` slot, whose slot may then
    /// be the moved time (LOW 9). `reachedFrom` nil means every slot (a whole-series write).
    /// Round 2 (LOW 3): the span-future route can pass only when the listing covers the series, the
    /// write is not an all-day change (#451 refuses that from a later occurrence), the first slot is
    /// held (else the series' id resolves to a stand-in, which this check answers unknown), and an
    /// occurrence is held after the last missing slot (there must be one to start from).
    static func verdict(rules: [Rule], firstStart: Date?, observedSlots: [Date], uneditedSlots: [Date], slotsTrusted: Bool,
                        changesAllDay: Bool, reachedFrom: Date?, scannedTo: Date, coversWholeSeries: Bool,
                        calendar: Calendar, isAllDay: Bool = false) -> Verdict {
        guard rules.count == 1, let firstStart, slotsTrusted,
              let expected = expectedSlots(of: rules[0], firstStart: firstStart, until: scannedTo, calendar: calendar) else {
            return .unknown
        }
        // Round 4 (LOW 4, 7): an all-day series stores its end as the end of its last day in UTC
        // (measured), so east of UTC the next local midnight still falls before it. Whether EventKit
        // lists that day was not measured, so an end less than a day after a slot is unknown.
        if isAllDay, let end = rules[0].endDate,
           expected.contains(where: { end.timeIntervalSince($0) >= 0 && end.timeIntervalSince($0) < 86_400 }) {
            return .unknown
        }
        func isExpected(_ slot: Date) -> Bool { expected.contains { UndoPostState.sameInstant($0, slot) } }
        // Round 3 (MEDIUM): the expander and the store must agree both ways. A listed slot the rule
        // does not give (inside what was expanded) means the expander is wrong here, so a slot it
        // missed could hide a deletion: unknown.
        if observedSlots.contains(where: { $0.timeIntervalSince(firstStart) > -1 && $0 < scannedTo && !isExpected($0) }) {
            return .unknown
        }
        // The rule's end is a point in time, inclusive: a slot at or before it is an occurrence, one
        // after it is not (`expectedSlots`). Measured on iCloud (2026-11-09, PR #505 round 3): a date-only
        // end (00:00) and 00:00 dropped a 10:00 occurrence on the end's day, an end at the slot or at 23:59
        // kept it, a New York series read from a Taipei host and an all-day series followed the same rule,
        // so no end shape is refused for its own sake.
        func held(_ slot: Date) -> Bool { observedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        func heldUnedited(_ slot: Date) -> Bool { uneditedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        let reached = reachedFrom.map { from in expected.filter { $0.timeIntervalSince(from) > -1 } } ?? expected
        let missing = reached.filter { !held($0) }
        if let lastMissing = missing.max() {
            let blocked: RouteBlock? = !coversWholeSeries ? .notCovered
                : changesAllDay ? .allDay
                : !held(firstStart) ? .firstSlotMissing
                : !expected.contains(where: { $0 > lastMissing && heldUnedited($0) }) ? .nothingAfter
                : nil
            return .deleted(blocked: blocked)
        }
        return coversWholeSeries ? .none : .unknown
    }

    /// PR #505 round 1 (MEDIUM, LOW 4): a whole-series write (span all, or span future from the first
    /// occurrence) reaches every occurrence, so it filters no slot; only a write from a later
    /// occurrence starts at its anchor. The anchor of a whole-series reach is the first occurrence's
    /// shown start, which an edit can move past later slots.
    static func reachedFrom(isWholeSeries: Bool, anchor: Date?) -> Date? {
        isWholeSeries ? nil : anchor
    }

    /// PR #505 rounds 1-2 (HIGH, MEDIUM, LOW 8): the series' original first slot, or nil when it cannot
    /// be shown. Never from a stand-in (the first remaining occurrence after the first was deleted, #326)
    /// or a detached object. The occurrence listed at the object's own start is the first occurrence
    /// (`startListed`); when it was edited on its own, its `/RID=` slot (`startRIDSlot`) is the first
    /// slot, and the object's `occurrenceDate` must agree with it or with the shown start (a moved
    /// occurrence's `occurrenceDate` can report the moved time in a long-lived store, 2026-10-10).
    /// When it was not edited, `occurrenceDate` must equal the shown start. The earlier of two values is
    /// never taken: a first occurrence moved earlier would then look like the first slot. An edited
    /// occurrence whose slot is before the first slot (`earliestRIDSlot`) also gives nil.
    /// Round 3 (MEDIUM): exactly one occurrence may be listed at the object's start (an occurrence
    /// moved onto it would otherwise be taken for the first), and no listed slot, edited or not, may
    /// lie before the chosen first slot.
    static func firstSlot(occurrenceDate: Date?, startDate: Date, startMatches: Int, startRIDSlot: Date?,
                          earliestListedSlot: Date?, viaStandIn: Bool, isDetached: Bool) -> Date? {
        guard !viaStandIn, !isDetached, startMatches == 1 else { return nil }
        let recorded = occurrenceDate ?? startDate
        let first: Date
        if let rid = startRIDSlot {
            guard UndoPostState.sameInstant(recorded, rid) || UndoPostState.sameInstant(recorded, startDate) else { return nil }
            // Round 4 (LOW 5): a `/RID=` slot after the shown start, with the recorded first at the
            // shown start, is a later occurrence moved onto it (the first deleted, on a store where
            // the series object still refreshes), or the first moved earlier: either way not shown.
            if rid.timeIntervalSince(startDate) >= 1, UndoPostState.sameInstant(recorded, startDate),
               !UndoPostState.sameInstant(recorded, rid) { return nil }
            first = rid
        } else {
            guard UndoPostState.sameInstant(recorded, startDate) else { return nil }
            first = recorded
        }
        if let earliest = earliestListedSlot, earliest.timeIntervalSince(first) <= -1 { return nil }
        return first
    }

    /// The rule's slots from `firstStart` (counted as the first) up to `until`, its end date or its
    /// count, in `calendar`'s zone, so a wall-clock time keeps across a daylight-saving change. nil
    /// for what is not followed: other parts, days of the week on a daily, monthly or yearly rule,
    /// days of the month on a daily or weekly one, several days every two weeks or more (they depend
    /// on the week start), a first start off the rule's days, days of the month outside 1...31, and
    /// a yearly rule from February 29 (RFC 5545 skips the years without one; date arithmetic does
    /// not). A month without the day is skipped, as RFC 5545 does.
    static func expectedSlots(of rule: Rule, firstStart: Date, until: Date, calendar: Calendar) -> [Date]? {
        guard !rule.hasOtherParts, rule.interval >= 1 else { return nil }   // an interval below 1 is not followed
        var slots: [Date] = []
        /// false once the rule ends here; a slot at or past `until` (round 4, LOW 3: an EventKit range
        /// does not return an event that starts exactly at its end) or past the end date is not taken.
        func take(_ slot: Date) -> Bool {
            if slot >= until { return false }
            if let end = rule.endDate, slot > end { return false }
            slots.append(slot)
            if rule.occurrenceCount > 0, slots.count >= rule.occurrenceCount { return false }
            return slots.count < maxSlots
        }
        func past(_ date: Date) -> Bool { date >= until || (rule.endDate.map { date > $0 } ?? false) }
        let firstWeekday = calendar.component(.weekday, from: firstStart)
        let firstDay = calendar.component(.day, from: firstStart)
        switch rule.frequency {
        case .daily:
            guard rule.daysOfWeek.isEmpty, rule.daysOfMonth.isEmpty else { return nil }
            var step = 0
            while let slot = calendar.date(byAdding: .day, value: step * rule.interval, to: firstStart), take(slot) { step += 1 }
        case .weekly:
            guard rule.daysOfMonth.isEmpty else { return nil }
            let days = Set(rule.daysOfWeek.isEmpty ? [firstWeekday] : rule.daysOfWeek)
            guard days.allSatisfy((1...7).contains), days.contains(firstWeekday) else { return nil }
            if days.count == 1 {
                var step = 0
                while let slot = calendar.date(byAdding: .day, value: 7 * step * rule.interval, to: firstStart), take(slot) { step += 1 }
            } else {
                guard rule.interval == 1 else { return nil }
                var offset = 0
                while let date = calendar.date(byAdding: .day, value: offset, to: firstStart), !past(date) {
                    if days.contains(calendar.component(.weekday, from: date)), !take(date) { break }
                    offset += 1
                }
            }
        case .monthly:
            guard rule.daysOfWeek.isEmpty else { return nil }
            let days = (rule.daysOfMonth.isEmpty ? [firstDay] : rule.daysOfMonth).sorted()
            // PR #505 round 1 (INFO 10): how EventKit places a day after the 28th in a shorter month was
            // not measured; a wrong guess there would miss a deletion, so it is not followed.
            guard days.allSatisfy((1...28).contains), days.contains(firstDay) else { return nil }
            let time = calendar.dateComponents([.hour, .minute, .second], from: firstStart)
            let firstMonth = calendar.dateComponents([.year, .month], from: firstStart)
            var step = 0
            months: while true {
                guard let monthStart = calendar.date(from: DateComponents(year: firstMonth.year, month: firstMonth.month, day: 1)),
                      let month = calendar.date(byAdding: .month, value: step * rule.interval, to: monthStart) else { return nil }
                if past(month) { break }
                let parts = calendar.dateComponents([.year, .month], from: month)
                for day in days {
                    guard let slot = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: day,
                                                                        hour: time.hour, minute: time.minute, second: time.second)),
                          calendar.component(.month, from: slot) == parts.month, calendar.component(.day, from: slot) == day,
                          slot >= firstStart else { continue }
                    if !take(slot) { break months }
                }
                step += 1
            }
        case .yearly:
            guard rule.daysOfWeek.isEmpty, rule.daysOfMonth.isEmpty else { return nil }
            let parts = calendar.dateComponents([.month, .day], from: firstStart)
            guard !(parts.month == 2 && parts.day == 29) else { return nil }
            var step = 0
            while let slot = calendar.date(byAdding: .year, value: step * rule.interval, to: firstStart), take(slot) { step += 1 }
        @unknown default:
            return nil
        }
        return slots
    }

    /// A bound on the work; the listing it is compared with is at most about six years.
    private static let maxSlots = 20_000

    /// PR #505 round 1 (LOW 6): the partial route is offered only where it can pass this check, on a
    /// series the listing covers whole.
    static func deletedReason(blocked: RouteBlock?) -> String {
        let route: String
        switch blocked {
        case nil:
            route = "To change the time, start from an occurrence after the last one deleted: span 'future' with the occurrence_date of an occurrence after it, not edited on its own, changes the occurrences from there on, and the ones deleted before it stay deleted (measured). Otherwise change the series in Calendar (not measured)."
        case .notCovered?:
            route = "No update route keeps the deletions here: the series goes on past what this check can list, so a write from a later occurrence is refused the same way. Change the series in Calendar (not measured)."
        case .allDay?:
            route = "No update route keeps the deletions for an all_day change: from a later occurrence it is refused (#451). Change the series in Calendar (not measured)."
        case .firstSlotMissing?:
            route = "No update route keeps the deletions here: the series' first occurrence was deleted, so a write from a later occurrence reads the series through its first remaining occurrence and is refused the same way. Change the series in Calendar (not measured)."
        case .nothingAfter?:
            route = "No update route keeps the deletions here: no occurrence that was not edited on its own follows the last deleted one, so there is nowhere to start span 'future' from. Change the series in Calendar (not measured)."
        }
        return "Among the occurrences this write reaches, at least one was deleted on its own (or moved where the listing does not reach), and changing the start, end, all_day or time zone of more than one occurrence of a series brought every such occurrence back, while the call answered updated (#503, measured on iCloud); undo does not restore it. A title, notes or location change keeps them. \(route) Nothing was written."
    }

    /// PR #505 round 4 (MEDIUM): a calendar of another account is a create plus a delete; whether the
    /// new series keeps the occurrences deleted on its own was not measured (no second account), so it
    /// is refused while one is found or cannot be ruled out.
    static func accountMoveReason(_ verdict: Verdict) -> String {
        let found = verdict == .unknown
            ? "and this check cannot rule one out (the reasons are those of a time change: the series could not be listed, its first slot cannot be shown, its rule is one the check does not follow, or the listing cannot be shown to reach its end)"
            : "and at least one occurrence of it was deleted on its own (or moved where the listing does not reach)"
        return "Moving this series to a calendar of another account is a create plus a delete, and whether the new series keeps the occurrences deleted on its own was not measured (#503), \(found); undo does not restore them. Moving it to a calendar of the same account kept them (measured). Nothing was written."
    }

    static let unknownReason = "This write changes the start, end, all_day or time zone of more than one occurrence of a series, which brought back every occurrence deleted on its own among them (#503, measured on iCloud), and this check cannot rule one out: the series could not be listed; its first slot cannot be shown (it is read through its first remaining occurrence because its first occurrence was deleted, or through an occurrence edited on its own; no occurrence, or more than one, is listed where the series shows its first; its recorded first slot disagrees with that occurrence's original slot and with its shown start; or a listed occurrence's slot lies before it); a listed occurrence falls where the rule gives none; an occurrence edited on its own without its original slot in its identifier was listed, so its slot may be its moved time; its rule is one the check does not follow (more than one rule, a numbered weekday, set positions, months, weeks or days of the year, days of the week on a daily, monthly or yearly rule, days of the month on a daily, weekly or yearly rule, an interval below 1, several days every two weeks or more, a first start off the rule's days, a day of the month after the 28th, or February 29 every year); or the listing cannot be shown to reach the series' end (no end, an end about five years or more after its start, or a count whose last occurrence the check cannot place close enough: a count with days of the month, a monthly or yearly count from the 29th to the 31st, or a long weekly count on several days). A title, notes or location change is not affected. Nothing was written."
}

extension DeletedOccurrenceCheck.Rule {
    init(_ rule: EKRecurrenceRule) {
        frequency = rule.frequency
        interval = rule.interval
        let weekdays = rule.daysOfTheWeek ?? []
        daysOfWeek = weekdays.map { $0.dayOfTheWeek.rawValue }
        daysOfMonth = (rule.daysOfTheMonth ?? []).map(\.intValue)
        endDate = rule.recurrenceEnd?.endDate
        occurrenceCount = rule.recurrenceEnd?.occurrenceCount ?? 0
        hasOtherParts = weekdays.contains { $0.weekNumber != 0 }
            || [rule.setPositions, rule.monthsOfTheYear, rule.weeksOfTheYear, rule.daysOfTheYear].contains { $0?.isEmpty == false }
    }
}
