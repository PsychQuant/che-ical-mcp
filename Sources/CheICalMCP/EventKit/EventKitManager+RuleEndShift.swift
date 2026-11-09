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
}

extension EventKitManager {
    /// #509: the refusal for a start change that would move an occurrence of `series` past one of
    /// its rule ends, or nil. `series` carries the rules (the series object, or the occurrence a
    /// span future starts from); its occurrences are listed by `seriesID` in a short window before
    /// each end. Read only, so it runs before the first field of the update is assigned.
    func ruleEndShiftRefusal(series: EKEvent?, seriesID: String?, storedStart: Date, plannedStart: Date,
                             storedZone: TimeZone, newZone: TimeZone) -> String? {
        guard let series, let seriesID, let calendar = series.calendar else { return RuleEndShift.unknownReason }
        let rules = series.recurrenceRules ?? []
        let keepsDays = rules.contains(where: RuleEndShift.keepsDays)
        let ids = UndoPostState.OccurrenceIDs(eventIdentifier: seriesID, externalIdentifier: series.calendarItemExternalIdentifier)
        for ruleEnd in rules.compactMap({ $0.recurrenceEnd?.endDate }) {
            let window = RuleEndShift.listingWindow(ruleEnd: ruleEnd, storedStart: storedStart, plannedStart: plannedStart)
            // Through the chunked range query (#325), as every listing a range is built for; one
            // that fails is refused, not taken as no occurrence.
            guard let listed = try? events(from: window.start, to: window.end, calendars: [calendar]) else {
                return RuleEndShift.unknownReason
            }
            let slots: [Date] = listed.compactMap { event in
                let occurrence = UndoPostState.OccurrenceIDs(eventIdentifier: event.eventIdentifier,
                                                             externalIdentifier: event.calendarItemExternalIdentifier)
                guard UndoPostState.isOccurrence(occurrence, of: ids) else { return nil }
                // The original slot: an occurrence edited on its own shows another time.
                return UndoPostState.originalSlot(eventIdentifier: event.eventIdentifier,
                                                  externalIdentifier: event.calendarItemExternalIdentifier,
                                                  occurrenceDate: event.occurrenceDate)
                    ?? event.occurrenceDate ?? event.startDate
            }
            if let slot = RuleEndShift.firstLost(slots: slots, ruleEnd: ruleEnd, storedStart: storedStart, plannedStart: plannedStart,
                                                 storedZone: storedZone, newZone: newZone, keepsDays: keepsDays) {
                let moved = RuleEndShift.latestMove(slot: slot, storedStart: storedStart, plannedStart: plannedStart,
                                                    storedZone: storedZone, newZone: newZone, keepsDays: keepsDays)
                return RuleEndShift.lostReason(slot: slot, ruleEnd: ruleEnd, movedTo: moved, zone: newZone)
            }
        }
        return nil
    }
}
