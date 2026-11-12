import EventKit
import Foundation

/// #503 — measured on iCloud (2026-11-09): an `update_event` that changes the start, end or all-day
/// flag of more than one occurrence of a series (span `all`, span `future` from the first occurrence
/// or a later one, a time of day, a new date, `end_time` alone, `all_day`) brought back every
/// occurrence deleted on its own among the occurrences it reached, and answered `updated`.
/// Title, notes and location kept them, so did the stored start and end written again, and so did
/// `timezone` alone on a series that had not started. PR #505 round 6 (measured on iCloud, 2026-11-09):
/// with span future from a later occurrence, a title, notes and location, url, alarms and
/// structured_location, a recurrence with only a new end date, and that rule with a calendar of the
/// same account kept deletions before and after the anchor too, through the series' id and (url,
/// alarms, structured_location on a count series) through an occurrence's own id. Undo refuses every recurring update, so
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
        /// Round 7 (MEDIUM 1, LOW 3): the write moves the series to another account, which checks
        /// every slot from any occurrence, so a span-future retry is refused the same way.
        case crossAccount
        /// Round 7 (LOW 5): through the first occurrence's own id; the series' id reads as edited
        /// before there (#428), so no identifier takes span future.
        case firstOccurrenceOwnID
    }

    /// Round 7: the route block a refusal gives. Another account takes precedence over every other
    /// cause; the first occurrence's own id replaces only an offered route.
    static func refusalRoute(_ blocked: RouteBlock?, crossesAccounts: Bool, throughFirstOwnID: Bool) -> RouteBlock? {
        if crossesAccounts { return .crossAccount }
        if blocked == nil, throughFirstOwnID { return .firstOccurrenceOwnID }
        return blocked
    }

    /// PR #505 round 5 (LOW): why the first slot cannot be shown, one cause each (`firstSlotResult`).
    enum FirstSlotCause: Equatable {
        /// Read through a stand-in: the series' first occurrence was deleted (#326).
        case standIn
        /// The object read is an occurrence edited on its own.
        case detached
        /// No occurrence, or more than one, is listed where the series shows its first.
        case notOneAtStart
        /// The recorded first slot agrees with neither the occurrence's original slot nor its shown start.
        case recordedDisagrees
        /// The `/RID=` slot is after the shown start while the recorded first is the shown start (round 4).
        case ridAfterStart
        /// A listed occurrence's slot lies before the chosen first slot.
        case slotBeforeFirst
        /// Not shown, for a reason the caller did not give.
        case notShown
    }

    /// PR #505 round 5 (LOW): why the check cannot tell, so a refusal names only the condition that fired.
    enum UnknownCause: Equatable {
        /// The series could not be listed, or the listing was empty.
        case notListed
        case firstSlot(FirstSlotCause)
        /// An occurrence edited on its own was listed without its original slot in its identifier.
        case editedWithoutSlot
        /// More than one rule, or a rule the expander does not follow.
        case ruleNotFollowed
        /// A listed occurrence falls where the rule gives none.
        case listedOffRule
        /// An all-day series whose rule end is less than a day after an occurrence's start (round 4).
        case allDayEnd
        /// The listing cannot be shown to reach the series' end (no horizon was given).
        case notCovered
        /// #506: with a horizon, the listing does not reach it without a gap from the first slot the
        /// write reaches (`DeletedOccurrenceHorizon`).
        case horizonNotReached
    }

    enum Verdict: Equatable {
        /// Every slot the write reaches is listed, and the listing covers the series.
        case none
        /// #506: the listing does not cover the series, but every slot the write reaches is held up to
        /// this date (exclusive), the end of the unbroken listing, at or after the horizon. Later slots
        /// were not checked.
        case noneThrough(Date)
        /// A slot the write reaches has no occurrence: one was deleted on its own (or moved where the
        /// listing does not reach). `blocked`: why span future from an occurrence after the last
        /// deletion cannot pass this same check, nil when it can (PR #505 rounds 1-3).
        case deleted(blocked: RouteBlock?)
        /// The check cannot tell, and why.
        case unknown(UnknownCause)
    }

    /// PR #505 round 5 (MEDIUM): what a whole-series write's planned dates are compared with. The
    /// stored start and end are the first occurrence's shown times; they are its slot only when the
    /// first occurrence was not edited on its own and its slot was shown (then `firstSlot` equals the
    /// stored start). Otherwise writing the shown time back is not known to keep the deletions.
    enum StoredBaseline: Equatable {
        /// Not a whole-series write, or the stored start is the proven first slot.
        case stored
        /// The first occurrence was edited on its own, or its slot cannot be shown: any date in the
        /// call is checked (fail closed).
        case unproven
    }

    /// Round 5 (LOW): a rule written over several occurrences whose pattern differs from the stored
    /// one (frequency, interval, days or count; only a new end date was measured, and kept them).
    /// A weekly rule without days runs on its start's weekday (`startWeekday`, an `EKWeekday` raw
    /// value), as the expander reads it, so a store that reads that day back, or none, is the same
    /// pattern. Without `startWeekday` the days are compared as given (a difference is checked).
    /// Round 6 (LOW 4, 11): `stored` is every rule of the series; anything but one is a pattern change
    /// (the write keeps one rule). A monthly rule without days runs on its start's day (`startDay`),
    /// as the expander reads it. Both are read from the series' original first slot by the caller.
    static func changesPattern(_ rule: Rule, stored: [Rule], startWeekday: Int? = nil, startDay: Int? = nil) -> Bool {
        guard stored.count == 1, let stored = stored.first else { return true }
        func days(_ rule: Rule) -> Set<Int> {
            if rule.frequency == .weekly, rule.daysOfWeek.isEmpty, let startWeekday { return [startWeekday] }
            return Set(rule.daysOfWeek)
        }
        func monthDays(_ rule: Rule) -> Set<Int> {
            if rule.frequency == .monthly, rule.daysOfMonth.isEmpty, let startDay { return [startDay] }
            return Set(rule.daysOfMonth)
        }
        return rule.frequency != stored.frequency || rule.interval != stored.interval
            || days(rule) != days(stored) || monthDays(rule) != monthDays(stored)
            || rule.occurrenceCount != stored.occurrenceCount || rule.hasOtherParts != stored.hasOtherParts
    }

    /// Round 5 (LOW): the kind of change, in this order: all_day, a new start, an end alone, a zone,
    /// a rule, an account. Round 6 (LOW 3, 5): a new start is `.start` only when nothing else of
    /// these changes with it (the end may move with it: a new time of day was measured), else
    /// `.combined`; `startChanges` nil (no proven slot to compare with) is `.unproven`.
    static func changeKind(allDayChanges: Bool, startChanges: Bool?, endChanges: Bool, changesZone: Bool, changesPattern: Bool,
                           changesAccount: Bool) -> ChangeKind {
        // Round 7 (LOW 3): another account with any other change is combined.
        if changesAccount, allDayChanges || startChanges != false || endChanges || changesZone || changesPattern { return .combined }
        if allDayChanges { return .allDay }
        guard let startChanges else { return .unproven }
        if startChanges { return changesZone || changesPattern || changesAccount ? .combined : .start }
        if endChanges { return .endOnly }
        if changesZone { return .zone }
        if changesPattern { return .pattern }
        return .account
    }

    /// Round 6 (LOW 5): whether the planned start differs from the proven slot; nil when no slot is
    /// proven, so neither can be shown.
    static func startChanges(planned: Date?, provenSlot: Date?) -> Bool? {
        guard let planned else { return false }
        guard let provenSlot else { return nil }
        return !UndoPostState.sameInstant(planned, provenSlot)
    }

    /// `.stored` only when the proven first slot is the shown start (`startDate`) and the first
    /// occurrence was not edited on its own: then comparing with the stored start compares with the slot.
    static func baseline(firstSlot: Date?, firstIsEdited: Bool, startDate: Date) -> StoredBaseline {
        guard let firstSlot, !firstIsEdited, UndoPostState.sameInstant(firstSlot, startDate) else { return .unproven }
        return .stored
    }

    /// PR #505 round 5 (LOW): which kind of change the write is, so the span-future route says
    /// "measured" only for the kinds measured (a new start: a time of day or a date).
    enum ChangeKind: Equatable { case start, combined, unproven, endOnly, zone, allDay, pattern, account }

    /// Whether the write is the measured shape: it reaches more than one occurrence, keeps the rule,
    /// and changes the start, the end or the all-day flag (the stored values written again kept them).
    /// PR #505 round 2 (LOW 6, measured on iCloud 2026-11-09): a time-zone change brought a deletion
    /// back across a daylight-saving divergence (span all on a series not started; span future from an
    /// occurrence still to come on a started one), so `changesZone` counts too. A `recurrence` with only
    /// its end changed and a `calendar_name` in the same account kept them (measured).
    /// Round 5 (MEDIUM): with `baseline` `.unproven` (a whole-series write whose first occurrence was
    /// edited on its own, or whose first slot cannot be shown), any planned date applies. Round 5 (LOW):
    /// a whole-series rule change other than its end (`changesPattern`) applies too; it was not measured.
    static func applies(reachesSeveral: Bool, clearingRecurrence: Bool, plannedDates: (Date, Date)?,
                        storedStart: Date, storedEnd: Date, resultAllDay: Bool, storedAllDay: Bool,
                        changesZone: Bool, changesAccount: Bool, changesPattern: Bool = false,
                        baseline: StoredBaseline = .stored) -> Bool {
        guard reachesSeveral, !clearingRecurrence else { return false }
        if resultAllDay != storedAllDay || changesZone || changesAccount || changesPattern { return true }
        guard let (start, end) = plannedDates else { return false }
        if baseline == .unproven { return true }
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
    /// #506: `listed` is the ranges the series was listed over (nil: one unbroken range up to
    /// `scannedTo`); a slot outside them is not compared. `horizon` (nil: the whole series must be
    /// covered, as before) lets a series the listing does not cover answer `noneThrough` when the
    /// listing reaches it without a gap from the first slot the write reaches.
    static func verdict(rules: [Rule], firstStart: Date?, observedSlots: [Date], uneditedSlots: [Date], slotsTrusted: Bool,
                        changesAllDay: Bool, reachedFrom: Date?, scannedTo: Date, coversWholeSeries: Bool,
                        calendar: Calendar, isAllDay: Bool = false, firstSlotCause: FirstSlotCause = .notShown,
                        listed: [DateInterval]? = nil, horizon: Date? = nil) -> Verdict {
        guard rules.count == 1 else { return .unknown(.ruleNotFollowed) }
        guard let firstStart else { return .unknown(.firstSlot(firstSlotCause)) }
        guard slotsTrusted else { return .unknown(.editedWithoutSlot) }
        guard let expected = expectedSlots(of: rules[0], firstStart: firstStart, until: scannedTo, calendar: calendar) else {
            return .unknown(.ruleNotFollowed)
        }
        // Round 4 (LOW 4, 7): an all-day series stores its end as the end of its last day in UTC
        // (measured), so east of UTC the next local midnight still falls before it. Whether EventKit
        // lists that day was not measured, so an end less than a day after a slot is unknown.
        if isAllDay, let end = rules[0].endDate,
           expected.contains(where: { end.timeIntervalSince($0) >= 0 && end.timeIntervalSince($0) < 86_400 }) {
            return .unknown(.allDayEnd)
        }
        func isExpected(_ slot: Date) -> Bool { expected.contains { UndoPostState.sameInstant($0, slot) } }
        // Round 3 (MEDIUM): the expander and the store must agree both ways. A listed slot the rule
        // does not give (inside what was expanded) means the expander is wrong here, so a slot it
        // missed could hide a deletion: unknown.
        if observedSlots.contains(where: { $0.timeIntervalSince(firstStart) > -1 && $0 < scannedTo && !isExpected($0) }) {
            return .unknown(.listedOffRule)
        }
        // The rule's end is a point in time, inclusive: a slot at or before it is an occurrence, one
        // after it is not (`expectedSlots`). Measured on iCloud (2026-11-09, PR #505 round 3): a date-only
        // end (00:00) and 00:00 dropped a 10:00 occurrence on the end's day, an end at the slot or at 23:59
        // kept it, a New York series read from a Taipei host and an all-day series followed the same rule,
        // so no end shape is refused for its own sake.
        func held(_ slot: Date) -> Bool { observedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        func heldUnedited(_ slot: Date) -> Bool { uneditedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        // #506: a slot in a gap of the listing (or past it) is not compared.
        let ranges = listed ?? [DateInterval(start: .distantPast, end: scannedTo)]
        func reachesHorizon(from start: Date) -> Bool {
            guard let horizon, let end = listedEnd(of: ranges, from: start) else { return false }
            return end >= horizon
        }
        let reached = reachedFrom.map { from in expected.filter { $0.timeIntervalSince(from) > -1 } } ?? expected
        let missing = reached.filter { isListed($0, in: ranges) && !held($0) }
        if let lastMissing = missing.max() {
            let routeStart = expected.first { $0 > lastMissing && heldUnedited($0) }
            let routeChecked = coversWholeSeries || routeStart.map(reachesHorizon(from:)) == true
            let blocked: RouteBlock? = !routeChecked ? .notCovered
                : changesAllDay ? .allDay
                : !held(firstStart) ? .firstSlotMissing
                : routeStart == nil ? .nothingAfter
                : nil
            return .deleted(blocked: blocked)
        }
        if coversWholeSeries { return .none }
        guard horizon != nil else { return .unknown(.notCovered) }
        let from = reachedFrom ?? firstStart
        guard reachesHorizon(from: from), let end = listedEnd(of: ranges, from: from) else { return .unknown(.horizonNotReached) }
        return .noneThrough(end)
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
        try? firstSlotResult(occurrenceDate: occurrenceDate, startDate: startDate, startMatches: startMatches, startRIDSlot: startRIDSlot,
                             earliestListedSlot: earliestListedSlot, viaStandIn: viaStandIn, isDetached: isDetached).get()
    }

    /// `firstSlot` with the cause when the slot cannot be shown (round 5, LOW).
    static func firstSlotResult(occurrenceDate: Date?, startDate: Date, startMatches: Int, startRIDSlot: Date?,
                                earliestListedSlot: Date?, viaStandIn: Bool, isDetached: Bool) -> Result<Date, FirstSlotFailure> {
        if viaStandIn { return .failure(.init(cause: .standIn)) }
        if isDetached { return .failure(.init(cause: .detached)) }
        guard startMatches == 1 else { return .failure(.init(cause: .notOneAtStart)) }
        let recorded = occurrenceDate ?? startDate
        let first: Date
        if let rid = startRIDSlot {
            guard UndoPostState.sameInstant(recorded, rid) || UndoPostState.sameInstant(recorded, startDate) else {
                return .failure(.init(cause: .recordedDisagrees))
            }
            // Round 4 (LOW 5): a `/RID=` slot after the shown start, with the recorded first at the
            // shown start, is a later occurrence moved onto it (the first deleted, on a store where
            // the series object still refreshes), or the first moved earlier: either way not shown.
            if rid.timeIntervalSince(startDate) >= 1, UndoPostState.sameInstant(recorded, startDate),
               !UndoPostState.sameInstant(recorded, rid) { return .failure(.init(cause: .ridAfterStart)) }
            first = rid
        } else {
            guard UndoPostState.sameInstant(recorded, startDate) else { return .failure(.init(cause: .recordedDisagrees)) }
            first = recorded
        }
        if let earliest = earliestListedSlot, earliest.timeIntervalSince(first) <= -1 { return .failure(.init(cause: .slotBeforeFirst)) }
        return .success(first)
    }

    struct FirstSlotFailure: Error, Equatable { let cause: FirstSlotCause }

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
    /// series the listing covers whole. Round 5 (LOW): "measured" only for a new start (a time of day or
    /// a date), the kind measured; for an end alone, a zone, a rule or an account it is not measured.
    static func deletedReason(blocked: RouteBlock?, change: ChangeKind = .start) -> String {
        let route: String
        switch blocked {
        case nil:
            let measured = change == .start ? "measured" : "measured for a new start only, not for this kind of change"
            route = "To change the time, start from an occurrence after the last one deleted: span 'future' with the occurrence_date of an occurrence after it, not edited on its own, changes the occurrences from there on, and the ones deleted before it stay deleted (\(measured)). Otherwise change the series in Calendar (not measured)."
        case .notCovered?:
            route = "No update route keeps the deletions here: the series goes on past what this check can list, so a write from a later occurrence is refused the same way (for a change of the start, end, all_day or time zone in the same account, the listing from an occurrence after the last deleted one does not reach two years from now, #506). Change the series in Calendar (not measured)."
        case .allDay?:
            route = "No update route keeps the deletions for an all_day change: from a later occurrence it is refused (#451). Change the series in Calendar (not measured)."
        case .firstSlotMissing?:
            route = "No update route keeps the deletions here: the series' first occurrence was deleted, so a write from a later occurrence reads the series through its first remaining occurrence and is refused the same way. Change the series in Calendar (not measured)."
        case .nothingAfter?:
            route = "No update route keeps the deletions here: no occurrence that was not edited on its own follows the last deleted one, so there is nowhere to start span 'future' from. Change the series in Calendar (not measured)."
        case .crossAccount?:
            route = "No update route keeps the deletions while the series moves to a calendar of another account: such a write checks every occurrence of the series, from any occurrence. Move it in Calendar (not measured), or drop the account change."
        case .firstOccurrenceOwnID?:
            route = "No update route keeps the deletions through this occurrence's own id: span 'future' from a later occurrence is not taken here (the series' id reads as edited before, #428). Change the series in Calendar (not measured)."
        }
        let found = "Among the occurrences this write reaches, at least one was deleted on its own (or moved where the listing does not reach)"
        // Round 6 (LOW 9): a new pattern alone is refused because it was not measured; no time route.
        if change == .pattern {
            return "\(found), and whether a new pattern of the rule (frequency, interval, days or count; a count replaced by an end_date or by no bound counts as one) over more than one occurrence keeps such occurrences was not measured (#503; a change of the start, end, all_day, or a time zone across a daylight-saving divergence brought them back, measured on iCloud, and a new end_date alone on a series that already ended at one kept them); undo does not restore them. \(keptText) No update route was measured for a new pattern: change the series in Calendar (not measured). Nothing was written."
        }
        return "\(found), and changing the start, end, all_day, or a time zone across a daylight-saving divergence, of more than one occurrence of a series brought every such occurrence back, while the call answered updated (#503, measured on iCloud); undo does not restore it. \(keptText) \(route) Nothing was written."
    }

    /// PR #505 round 4 (MEDIUM): a calendar of another account is a create plus a delete; whether the
    /// new series keeps the occurrences deleted on its own was not measured (no second account), so it
    /// is refused while one is found or cannot be ruled out. Round 5: the unknown text names its cause,
    /// and the same-account measurement is named as update_event's.
    /// Round 6 (LOW 6): `fromLaterOccurrence` names the part a span-future write moves.
    static func accountMoveReason(_ verdict: Verdict, fromLaterOccurrence: Bool = false) -> String {
        let found = foundText(verdict)
        let subject = fromLaterOccurrence ? "Moving the occurrences from this one on" : "Moving this series"
        return "\(subject) to a calendar of another account is a create plus a delete, and whether the new series keeps the occurrences deleted on its own was not measured (#503), \(found); undo does not restore them. Moving it with update_event to a calendar of the same account kept them (measured with span all, and with span future from a later occurrence together with a new end_date). Nothing was written."
    }

    private static func foundText(_ verdict: Verdict) -> String {
        if case .unknown(let cause) = verdict { return "and this check cannot rule one out: \(unknownCause(cause))" }
        return "and at least one occurrence of it was deleted on its own (or moved where the listing does not reach)"
    }

    /// #511: the undo of a whole-series move back to a calendar of another account, refused as the
    /// forward move is (`accountMoveReason`). The record is kept, so the text gives #269's way on.
    /// PR #516 round 1: the event named; Calendar's own move back is the same unmeasured move, so the
    /// text says to check the deleted occurrences after it; an unreadable account counts as another.
    static func undoAccountMoveReason(_ verdict: Verdict, title: String) -> String {
        "Cannot undo the move of the recurring event '\(undoShownTitle(title))': moving the whole series back to its original calendar in another account (or one whose account could not be read) is a create plus a delete, and whether the new series keeps the occurrences deleted on its own was not measured (#503), \(foundText(verdict)). Nothing was written and this history entry was kept. If it should go back, move it in Calendar, which may also bring back the occurrences deleted on their own, so check them afterwards; then ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."
    }

    /// MEDIUM 2 of round 6 (measured on iCloud, 2026-11-09): the fields that kept the deletions, and the spans.
    static let keptText = "A change of the title, notes, location, url, alarms or structured_location keeps them (measured on iCloud with span all and with span future from a later occurrence)."

    /// The condition that made the check unable to tell, one text each.
    static func unknownCause(_ cause: UnknownCause) -> String {
        switch cause {
        case .notListed: return "the series could not be listed"
        case .firstSlot(let slot):
            let why: String
            switch slot {
            case .standIn: why = "it is read through its first remaining occurrence, because its first occurrence was deleted"
            case .detached: why = "it is read through an occurrence edited on its own"
            case .notOneAtStart: why = "no occurrence, or more than one, is listed where the series shows its first"
            case .recordedDisagrees: why = "its recorded first slot disagrees with that occurrence's original slot and with its shown start"
            case .ridAfterStart: why = "the occurrence at its shown start has an original slot after that start, so another occurrence may have been moved onto a deleted first one"
            case .slotBeforeFirst: why = "a listed occurrence's slot lies before it"
            case .notShown: why = "it could not be shown"
            }
            return "its first slot cannot be shown (\(why))"
        case .editedWithoutSlot: return "an occurrence edited on its own without its original slot in its identifier was listed, so its slot may be its moved time"
        case .ruleNotFollowed: return "its rule is one the check does not follow (more than one rule, a numbered weekday, set positions, months, weeks or days of the year, days of the week on a daily, monthly or yearly rule, days of the month on a daily, weekly or yearly rule, an interval below 1, several days every two weeks or more, a first start off the rule's days, a day of the month after the 28th or counted from the month's end, or February 29 every year)"
        case .listedOffRule: return "a listed occurrence falls where the rule gives none"
        case .allDayEnd: return "it is an all-day series whose rule ends less than a day after an occurrence's start, and whether that day is listed east of UTC was not measured"
        case .notCovered: return "the listing cannot be shown to reach the series' end (no end, an end about five years or more after its start, or a count whose last occurrence the check cannot place close enough: a count with days of the month, a monthly or yearly count from the 29th to the 31st, or a long weekly count on several days); a change of the start, end, all_day or time zone in the same account, without a new rule pattern, is checked up to two years from now instead (#506)"
        case .horizonNotReached: return "the check cannot list the series whole, and the listing does not reach two years from now without a gap from the first occurrence this write reaches (#506: the series is listed from about a year before its first occurrence to about five years after it, and around now from about four years before to about three years ahead, so a series begun more than about nine years ago leaves a gap, as does an occurrence to start from past the listing)"
        }
    }

    static func unknownReason(_ cause: UnknownCause) -> String {
        "This write changes the start, end, all_day, time zone or rule of more than one occurrence of a series; a change of the start, end, all_day, or a time zone across a daylight-saving divergence brought back every occurrence deleted on its own among them (#503, measured on iCloud), and this check cannot rule one out: \(unknownCause(cause)). \(keptText) Nothing was written."
    }
}

extension DeletedOccurrenceCheck.Rule {
    /// The rule a call writes, as the expander reads it (PR #505 round 5).
    init(_ rule: RecurrenceRuleInput) {
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        interval = rule.interval
        daysOfWeek = rule.daysOfWeek ?? []
        daysOfMonth = rule.daysOfMonth ?? []
        endDate = rule.endDate
        occurrenceCount = rule.occurrenceCount ?? 0
        hasOtherParts = false
    }

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
