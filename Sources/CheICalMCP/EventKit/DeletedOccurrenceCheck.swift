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

    enum Verdict: Equatable {
        /// Every slot the write reaches is listed, and the listing covers the series.
        case none
        /// A slot the write reaches has no occurrence: one was deleted on its own. `routeWorks`: the
        /// listing covers the series, so span future from an occurrence after the last deletion can pass
        /// this same check (PR #505 round 1, LOW 6).
        case deleted(routeWorks: Bool)
        /// The check cannot tell: the rule cannot be followed, or the listing does not cover it.
        case unknown
    }

    /// Whether the write is the measured shape: it reaches more than one occurrence, keeps the rule,
    /// and changes the start, the end or the all-day flag (the stored values written again kept them).
    static func applies(reachesSeveral: Bool, clearingRecurrence: Bool, plannedDates: (Date, Date)?,
                        storedStart: Date, storedEnd: Date, resultAllDay: Bool, storedAllDay: Bool) -> Bool {
        guard reachesSeveral, !clearingRecurrence else { return false }
        if resultAllDay != storedAllDay { return true }
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
    static func verdict(rules: [Rule], firstStart: Date?, observedSlots: [Date], slotsTrusted: Bool, reachedFrom: Date?,
                        scannedTo: Date, coversWholeSeries: Bool, calendar: Calendar) -> Verdict {
        guard rules.count == 1, let firstStart, slotsTrusted,
              let expected = expectedSlots(of: rules[0], firstStart: firstStart, until: scannedTo, calendar: calendar) else {
            return .unknown
        }
        let reached = reachedFrom.map { from in expected.filter { $0.timeIntervalSince(from) > -1 } } ?? expected
        if reached.contains(where: { slot in !observedSlots.contains { UndoPostState.sameInstant($0, slot) } }) {
            return .deleted(routeWorks: coversWholeSeries)
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

    /// PR #505 round 1 (HIGH, LOW 8): the series' original first slot, or nil when it cannot be shown.
    /// Never from a stand-in (the first remaining occurrence after the first was deleted, #326) or a
    /// detached object: neither shows the slot a deleted first occurrence had. The earlier of the
    /// object's `occurrenceDate` and the earliest listed `/RID=` slot, since `occurrenceDate` of a moved
    /// occurrence can report the moved time in a long-lived store (2026-10-10). Proven when it equals
    /// the object's own start (the first occurrence not edited) or that `/RID=` slot.
    static func firstSlot(occurrenceDate: Date?, startDate: Date, ridSlots: [Date], viaStandIn: Bool, isDetached: Bool) -> Date? {
        guard !viaStandIn, !isDetached else { return nil }
        let recorded = occurrenceDate ?? startDate
        let earliestRID = ridSlots.min()
        let first = earliestRID.map { min($0, recorded) } ?? recorded
        let proven = UndoPostState.sameInstant(first, startDate) || (earliestRID.map { UndoPostState.sameInstant($0, first) } ?? false)
        return proven ? first : nil
    }

    /// The rule's slots from `firstStart` (counted as the first) up to `until`, its end date or its
    /// count, in `calendar`'s zone, so a wall-clock time keeps across a daylight-saving change. nil
    /// for what is not followed: other parts, days of the week on a daily, monthly or yearly rule,
    /// days of the month on a daily or weekly one, several days every two weeks or more (they depend
    /// on the week start), a first start off the rule's days, days of the month outside 1...31, and
    /// a yearly rule from February 29 (RFC 5545 skips the years without one; date arithmetic does
    /// not). A month without the day is skipped, as RFC 5545 does.
    static func expectedSlots(of rule: Rule, firstStart: Date, until: Date, calendar: Calendar) -> [Date]? {
        guard !rule.hasOtherParts, rule.interval >= 1 else { return nil }
        var slots: [Date] = []
        /// false once the rule ends here; a slot past `until` or the end date is not taken.
        func take(_ slot: Date) -> Bool {
            if slot > until { return false }
            if let end = rule.endDate, slot > end { return false }
            slots.append(slot)
            if rule.occurrenceCount > 0, slots.count >= rule.occurrenceCount { return false }
            return slots.count < maxSlots
        }
        func past(_ date: Date) -> Bool { date > until || (rule.endDate.map { date > $0 } ?? false) }
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
    static func deletedReason(routeWorks: Bool) -> String {
        let route = routeWorks
            ? "No tested route changes the time and keeps them: span 'future' with the occurrence_date of an occurrence after the last one deleted changes only the occurrences from there on, and the ones deleted before it stay deleted (measured). Otherwise change the series in Calendar (not measured)."
            : "No update route keeps the deletions on this series: it goes on past what this check can list, so a write from a later occurrence is refused the same way. Change the series in Calendar (not measured)."
        return "Among the occurrences this write reaches, at least one was deleted on its own, and changing the start, end or all_day of more than one occurrence of a series brought every such occurrence back, while the call answered updated (#503, measured on iCloud); undo does not restore it. A title, notes or location change keeps them. \(route) Nothing was written."
    }

    static let unknownReason = "This write changes the start, end or all_day of more than one occurrence of a series, which brought back every occurrence deleted on its own among them (#503, measured on iCloud), and this check cannot rule one out: the series could not be listed; its first slot cannot be shown (its first occurrence was deleted, or the occurrence found for it was edited on its own with nothing showing its original slot); an occurrence edited on its own without its original slot in its identifier was listed, so its slot may be its moved time; its rule is one the check does not follow (more than one rule, a numbered weekday, set positions, months, weeks or days of the year, days of the week on a daily, monthly or yearly rule, days of the month on a daily or weekly rule, several days every two weeks or more, a first start off the rule's days, a day of the month after the 28th, or February 29 every year); or the listing cannot be shown to reach the series' end (no end, an end about five years or more after its start, or a count whose last occurrence the check cannot place close enough: a count with days of the month, a monthly or yearly count from the 29th to the 31st, or a long weekly count on several days). A title, notes or location change is not affected. Nothing was written."
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
