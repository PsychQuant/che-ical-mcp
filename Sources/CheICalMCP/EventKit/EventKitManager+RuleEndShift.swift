import EventKit
import Foundation

extension RuleEndShift {
    /// Which BY parts a rule has (PR #510 round 4, HIGH: `RuleParts.fixesDay` apart from having one).
    static func parts(_ rule: EKRecurrenceRule) -> RuleParts {
        func has(_ list: [Any]?) -> Bool { !(list ?? []).isEmpty }
        return RuleParts(daysOfWeek: has(rule.daysOfTheWeek), daysOfMonth: has(rule.daysOfTheMonth), daysOfYear: has(rule.daysOfTheYear),
                         weeksOfYear: has(rule.weeksOfTheYear), monthsOfYear: has(rule.monthsOfTheYear), setPositions: has(rule.setPositions))
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
    /// one of the ends it is checked against, or nil (`RuleEndShift.refusal` decides). `series` is the
    /// object the rules were read from (the series object, or the occurrence a span future starts
    /// from); its own occurrences are listed by `seriesID` and placed by their original slot (PR #510
    /// round 1, HIGH 1, MEDIUM 4). A series or calendar that cannot be read lists nothing, which
    /// refuses. Read only, so it runs before the first field is assigned.
    func ruleEndShiftRefusal(series: EKEvent, seriesID: String?, storedEnds: [Date], passedRule: RuleEndShift.PassedRule?,
                             plan: RuleEndShift.Plan, from: Date?, allDay: Bool, route: RuleEndShift.Route) -> String? {
        RuleEndShift.refusal(storedEnds: storedEnds, passedRule: passedRule, plan: plan, from: from, allDay: allDay, route: route) { range in
            guard let seriesID, let calendar = series.calendar,
                  let listed = try? events(from: range.start, to: range.end, calendars: [calendar]) else { return nil }
            let ids = UndoPostState.OccurrenceIDs(eventIdentifier: seriesID, externalIdentifier: series.calendarItemExternalIdentifier)
            return listed.compactMap { event in
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
        }
    }
}
