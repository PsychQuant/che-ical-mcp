import EventKit
import Foundation

extension RuleEndShift {
    /// Whether a rule names days of its own (weekdays, days of the month or year, weeks, months or
    /// set positions): such a rule keeps its days when the start moves, instead of shifting whole.
    static func keepsDays(_ rule: EKRecurrenceRule) -> Bool {
        [rule.daysOfTheWeek?.count, rule.daysOfTheMonth?.count, rule.daysOfTheYear?.count,
         rule.weeksOfTheYear?.count, rule.monthsOfTheYear?.count, rule.setPositions?.count]
            .contains { ($0 ?? 0) > 0 }
    }

    /// The unit a plain rule repeats by; the coarsest of several rules (fail closed).
    static func unit(of rules: [EKRecurrenceRule]) -> Unit {
        if rules.contains(where: { $0.frequency == .yearly }) { return .year }
        if rules.contains(where: { $0.frequency == .monthly }) { return .month }
        return .day
    }

    static func passedRule(_ rule: RecurrenceRuleInput?, clearing: Bool) -> PassedRule? {
        if clearing { return .clear }
        guard let rule else { return nil }
        if let end = rule.endDate { return .end(end) }
        return rule.occurrenceCount != nil ? .count : .open
    }
}

extension EventKitManager {
    /// #509: the refusal for a start or zone change that would move an occurrence of the series past
    /// one of the ends it is checked against, or nil. `series` carries the rules (the series object,
    /// or the occurrence a span future starts from); its own occurrences are listed by `seriesID`
    /// around each end and placed by their original slot (PR #510 round 1, HIGH 1, MEDIUM 4: an
    /// occurrence edited on its own and moved within a year is listed; one that cannot be placed, or
    /// an empty listing, refuses). Read only, so it runs before the first field is assigned.
    func ruleEndShiftRefusal(series: EKEvent?, seriesID: String?, ends: [Date], plan: RuleEndShift.Plan,
                             from: Date?, ruleWritable: Bool) -> String? {
        guard !ends.isEmpty else { return nil }
        guard let series, let seriesID, let calendar = series.calendar else { return RuleEndShift.unknownReason(ruleWritable: ruleWritable) }
        let ids = UndoPostState.OccurrenceIDs(eventIdentifier: seriesID, externalIdentifier: series.calendarItemExternalIdentifier)
        for ruleEnd in ends {
            // PR #510 round 1 (MEDIUM 3): refused before any read when nothing would remain.
            if RuleEndShift.startsPastEnd(plannedStart: plan.plannedStart, ruleEnd: ruleEnd) {
                return RuleEndShift.pastEndReason(ruleEnd: ruleEnd, zone: plan.newZone)
            }
            guard let range = RuleEndShift.listingRange(ruleEnd: ruleEnd, plan: plan),
                  let listed = try? events(from: range.start, to: range.end, calendars: [calendar]) else {
                return RuleEndShift.unknownReason(ruleWritable: ruleWritable)
            }
            let own: [RuleEndShift.Listed] = listed.compactMap { event in
                let occurrence = UndoPostState.OccurrenceIDs(eventIdentifier: event.eventIdentifier,
                                                             externalIdentifier: event.calendarItemExternalIdentifier)
                guard UndoPostState.isOccurrence(occurrence, of: ids) else { return nil }
                let rid = UndoPostState.originalSlot(eventIdentifier: event.eventIdentifier,
                                                     externalIdentifier: event.calendarItemExternalIdentifier,
                                                     occurrenceDate: nil)
                let slot = rid.map {
                    UndoPostState.ruleSlot(eventIdentifier: event.eventIdentifier, externalIdentifier: event.calendarItemExternalIdentifier,
                                           occurrenceDate: event.occurrenceDate, isAllDay: series.isAllDay) ?? $0
                }
                return RuleEndShift.Listed(isDetached: event.isDetached, ridSlot: slot, occurrenceDate: event.occurrenceDate, start: event.startDate)
            }
            guard let slots = RuleEndShift.place(own) else { return RuleEndShift.unknownReason(ruleWritable: ruleWritable) }
            if let slot = RuleEndShift.firstLost(slots: slots, ruleEnd: ruleEnd, plan: plan, from: from) {
                return RuleEndShift.lostReason(slot: slot, ruleEnd: ruleEnd, movedTo: RuleEndShift.latestMove(slot: slot, plan: plan),
                                               zone: plan.newZone, ruleWritable: ruleWritable)
            }
        }
        return nil
    }
}
