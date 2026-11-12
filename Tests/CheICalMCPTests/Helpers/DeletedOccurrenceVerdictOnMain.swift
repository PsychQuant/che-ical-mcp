import Foundation
@testable import CheICalMCP

/// #520: `DeletedOccurrenceCheck.verdict` as it was on `main` at ef79cbc, before its three membership
/// scans (`isExpected`, `held`, `heldUnedited`) were replaced by `InstantSet`. Copied without a change
/// but its name, to run beside the current `verdict` over the same inputs
/// (`DeletedOccurrenceVerdictEquivalenceTests`). It is the old behaviour, kept on purpose: do not
/// update it when `verdict` changes its answers; drop the comparison then.
extension DeletedOccurrenceCheck {
    static func verdictOnMain(rules: [Rule], firstStart: Date?, observedSlots: [Date], uneditedSlots: [Date], slotsTrusted: Bool,
                        changesAllDay: Bool, reachedFrom: Date?, scannedTo: Date, coversWholeSeries: Bool,
                        calendar: Calendar, isAllDay: Bool = false, firstSlotCause: FirstSlotCause = .notShown,
                        listed: [DateInterval]? = nil, horizon: Date? = nil) -> Verdict {
        guard rules.count == 1 else { return .unknown(.ruleNotFollowed) }
        guard let firstStart else { return .unknown(.firstSlot(firstSlotCause)) }
        guard slotsTrusted else { return .unknown(.editedWithoutSlot) }
        let expected: [Date]
        switch expansion(of: rules[0], firstStart: firstStart, until: scannedTo, calendar: calendar) {
        case .slots(let slots): expected = slots
        case .notFollowed: return .unknown(.ruleNotFollowed)
        case .tooMany: return .unknown(.tooManySlots)
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
            // Verify r1 (item 1): on a series the listing does not cover, the route starts at the first
            // held, unedited slot after the last deletion whose unbroken listing reaches the horizon
            // (on an old series, one in the block around now), not at the first such slot.
            let after = expected.filter { $0 > lastMissing && heldUnedited($0) }
            let routeStart = coversWholeSeries ? after.first : after.first(where: reachesHorizon(from:))
            // Verify r2 (LOW 3): no occurrence after the deletion, or only edited ones, is nothingAfter on
            // any series; horizonNotReached only when there are some and none reaches the horizon.
            let blocked: RouteBlock? = !coversWholeSeries && horizon == nil ? .notCovered
                : changesAllDay ? .allDay
                : !held(firstStart) ? .firstSlotMissing
                : after.isEmpty ? .nothingAfter
                : routeStart == nil ? .horizonNotReached
                : nil
            // Verify r2 (MEDIUM 1): on a series the listing does not cover, the refusal names where the
            // route can start, since the next occurrence after the deletion may not reach the horizon.
            let window = coversWholeSeries || blocked != nil ? nil
                : routeStart.flatMap { start in listedEnd(of: ranges, from: start).map { DateInterval(start: start, end: $0) } }
            return .deleted(blocked: blocked, routeWindow: window)
        }
        if coversWholeSeries { return .none }
        guard horizon != nil else { return .unknown(.notCovered) }
        let from = reachedFrom ?? firstStart
        guard reachesHorizon(from: from), let end = listedEnd(of: ranges, from: from) else { return .unknown(.horizonNotReached) }
        return .noneThrough(end)
    }
}
