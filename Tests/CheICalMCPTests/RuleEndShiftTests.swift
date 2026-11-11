import EventKit
import XCTest
@testable import CheICalMCP

/// #509: a start change over a series re-expands its rule up to the same end instant, so an
/// occurrence whose moved start is after that end is lost (device, iCloud, 2026-11-09). The cases
/// below are the measured ones (#509's Diagnosis), plus the zone, monthly and day-rule variants.
final class RuleEndShiftTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ text: String, _ zone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: text)!
    }

    /// Weekly at 10:00 Taipei from 2026-12-07, five occurrences.
    private var mondays: [Date] {
        ["2026-12-07", "2026-12-14", "2026-12-21", "2026-12-28", "2027-01-04"].map { at($0 + "T10:00", taipei) }
    }

    private func plan(planned: Date, stored: Date? = nil, storedZone: TimeZone? = nil, newZone: TimeZone? = nil,
                      unit: RuleEndShift.Unit = .day, keepsDays: Bool = false, dayFromStart: Bool? = nil,
                      expandable: Bool = true) -> RuleEndShift.Plan {
        .init(storedStarts: [stored ?? mondays[0]], plannedStart: planned, storedZone: storedZone ?? taipei,
              newZone: newZone ?? storedZone ?? taipei, unit: unit, keepsDays: keepsDays,
              dayFromStart: dayFromStart ?? !keepsDays, expandable: expandable)
    }

    private func lost(end: String, planned: String, keepsDays: Bool = false) -> Date? {
        RuleEndShift.firstLost(slots: mondays, ruleEnd: at(end, taipei), plan: plan(planned: at(planned, taipei), keepsDays: keepsDays))
    }

    // MARK: - The measured shapes

    func testALaterTimeLosesTheOccurrenceAtTheEnd() {
        XCTAssertEqual(lost(end: "2027-01-04T10:00", planned: "2026-12-07T11:00"), mondays[4])
    }

    func testAShiftThatStaysWithinTheEndKeepsEveryOccurrence() {
        XCTAssertNil(lost(end: "2027-01-04T10:30", planned: "2026-12-07T10:20"))
        XCTAssertEqual(lost(end: "2027-01-04T10:30", planned: "2026-12-07T10:40"), mondays[4])
    }

    func testTheEndIsInclusive() {
        XCTAssertNil(lost(end: "2027-01-04T10:30", planned: "2026-12-07T10:30"))
    }

    func testAnEarlierTimeKeepsEveryOccurrence() {
        XCTAssertNil(lost(end: "2027-01-04T10:00", planned: "2026-12-07T09:00"))
    }

    func testADayLaterLosesTheLastOccurrenceOfAPlainRule() {
        XCTAssertEqual(lost(end: "2027-01-04T22:00", planned: "2026-12-08T10:00"), mondays[4])
    }

    /// Measured: a day earlier and an hour later kept all five, because a plain rule shifts whole.
    func testANetEarlierMoveKeepsAPlainRule() {
        XCTAssertNil(lost(end: "2027-01-04T10:00", planned: "2026-12-06T11:00"))
    }

    /// Measured: a zone change alone between zones without daylight saving kept the instants.
    func testAZoneChangeWithoutDaylightSavingKeepsTheInstants() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertNil(RuleEndShift.firstLost(slots: mondays, ruleEnd: at("2027-01-04T10:00", taipei),
                                            plan: plan(planned: mondays[0], newZone: tokyo)))
    }

    // MARK: - Variants (round 1)

    /// A rule with days of its own keeps its days and takes the new time of day (not measured).
    func testARuleWithDaysIsReadAtTheNewTimeOfDay() {
        XCTAssertEqual(lost(end: "2027-01-04T10:00", planned: "2026-12-06T11:00", keepsDays: true), mondays[4])
        XCTAssertNil(lost(end: "2027-01-04T10:00", planned: "2026-12-06T09:00", keepsDays: true))
    }

    func testSlotsAfterTheEndAreNotCounted() {
        XCTAssertNil(RuleEndShift.firstLost(slots: mondays, ruleEnd: at("2026-12-28T10:00", taipei),
                                            plan: plan(planned: at("2026-12-07T09:00", taipei))))
        XCTAssertEqual(RuleEndShift.firstLost(slots: mondays, ruleEnd: at("2026-12-28T10:00", taipei),
                                              plan: plan(planned: at("2026-12-07T11:00", taipei))), mondays[3])
    }

    /// The store moves occurrences by the wall clock: across a DST start a one-day move is 23 hours,
    /// and the occurrence after the change still moves a whole day.
    func testAShiftAcrossDaylightSavingTimeIsReadByTheWallClock() {
        let slots = ["2027-03-13T10:00", "2027-03-20T10:00"].map { at($0, newYork) }
        XCTAssertEqual(RuleEndShift.firstLost(slots: slots, ruleEnd: at("2027-03-21T09:30", newYork),
                                              plan: plan(planned: at("2027-03-14T10:00", newYork), stored: slots[0], storedZone: newYork)),
                       slots[1])
    }

    // MARK: - Round 1 findings

    /// MEDIUM 5: a zone change alone, across a DST change: a New York series moved to UTC repeats at
    /// 15:00Z, an hour after its last occurrence's start (14:00Z, EDT).
    func testAZoneChangeAloneAcrossDaylightSavingIsChecked() {
        let slots = ["2027-03-06T10:00", "2027-03-13T10:00", "2027-03-20T10:00"].map { at($0, newYork) }
        let p = plan(planned: slots[0], stored: slots[0], storedZone: newYork, newZone: utc)
        XCTAssertEqual(RuleEndShift.firstLost(slots: slots, ruleEnd: slots[2], plan: p), slots[2])
        // A start one minute later in UTC, end at 14:30Z.
        let moved = plan(planned: slots[0].addingTimeInterval(60), stored: slots[0], storedZone: newYork, newZone: utc)
        XCTAssertEqual(RuleEndShift.firstLost(slots: slots, ruleEnd: at("2027-03-20T14:30", utc), plan: moved), slots[2])
    }

    /// MEDIUM 7: a plain monthly rule repeats on the new start's day of the month, so a move across a
    /// month boundary is read by months, not by days.
    func testAPlainMonthlyRuleIsReadByMonths() {
        let slots = ["2027-02-25", "2027-03-25", "2027-04-25"].map { at($0 + "T10:00", taipei) }
        let p = plan(planned: at("2027-03-01T10:00", taipei), stored: slots[0], unit: .month)
        XCTAssertEqual(RuleEndShift.firstLost(slots: slots, ruleEnd: at("2027-04-30T23:59", taipei), plan: p), slots[2])
    }

    /// HIGH 1, MEDIUM 4: slots come from the listed occurrences' original slots; an occurrence edited
    /// on its own counts by its /RID= slot wherever it shows, and one without it cannot be placed.
    func testSlotsArePlacedByTheirOriginalSlot() {
        let end = mondays[4]
        let moved = RuleEndShift.Listed(isDetached: true, ridSlot: end, occurrenceDate: nil, start: at("2027-01-01T15:00", taipei))
        let plain = RuleEndShift.Listed(isDetached: false, ridSlot: nil, occurrenceDate: mondays[3], start: mondays[3])
        XCTAssertEqual(RuleEndShift.place([plain, moved]), [mondays[3], end])
        let unplaced = RuleEndShift.Listed(isDetached: true, ridSlot: nil, occurrenceDate: end, start: at("2027-01-01T15:00", taipei))
        XCTAssertNil(RuleEndShift.place([plain, unplaced]), "an edited occurrence without its slot")
        XCTAssertNil(RuleEndShift.place([]), "an empty listing is never safe")
    }

    /// HIGH 2: the check runs on the routes through an occurrence's own id (#416, #428), whose object
    /// has no rules of its own.
    func testTheOwnIdRoutesAreChecked() {
        XCTAssertTrue(RuleEndShift.repeats(masterHasRules: false, addressesOwnOccurrence: true))
        XCTAssertTrue(RuleEndShift.repeats(masterHasRules: true, addressesOwnOccurrence: false))
        XCTAssertFalse(RuleEndShift.repeats(masterHasRules: false, addressesOwnOccurrence: false))
        // The stored start is read both from the shown start and the original slot.
        let p = RuleEndShift.Plan(storedStarts: [at("2026-12-07T12:00", taipei), mondays[0]], plannedStart: at("2026-12-07T11:00", taipei),
                                  storedZone: taipei, newZone: taipei, unit: .day, keepsDays: false,
                                  dayFromStart: true, expandable: true)
        XCTAssertEqual(RuleEndShift.firstLost(slots: mondays, ruleEnd: mondays[4], plan: p), mondays[4])
    }

    func testItAppliesToAStartOrZoneChangeOverTheRestOfASeries() {
        XCTAssertTrue(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: true, changesZone: false, changesAllDay: false))
        XCTAssertTrue(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: false, changesZone: true, changesAllDay: false))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: false, changesZone: false, changesAllDay: false))
        XCTAssertFalse(RuleEndShift.applies(repeats: false, reachesEnd: true, movesStart: true, changesZone: true, changesAllDay: false))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: false, movesStart: true, changesZone: true, changesAllDay: false))
    }

    /// MEDIUM 6: a rule passed in the call is checked against its own end; a count or no end drops
    /// nothing at the end.
    func testAPassedRuleIsCheckedAgainstItsOwnEnd() {
        let stored = [mondays[4]]
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: nil), [.init(rule: mondays[4], listAround: mondays[4])])
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: .end(at("2027-01-04T11:00", taipei))),
                       [.init(rule: at("2027-01-04T11:00", taipei), listAround: mondays[4])])
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: .end(at("2027-01-03T11:00", taipei))),
                       [.init(rule: at("2027-01-03T11:00", taipei), listAround: at("2027-01-03T11:00", taipei))])
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: .count), [])
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: .open), [])
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: .clear), [])
    }

    /// LOW 8: span future moves only the occurrences from its own slot on.
    func testSpanFutureCountsOnlyTheSlotsItMoves() {
        let p = plan(planned: at("2027-01-12T10:00", taipei), stored: mondays[4])
        XCTAssertEqual(RuleEndShift.firstLost(slots: mondays, ruleEnd: at("2027-01-04T22:00", taipei), plan: p, from: mondays[4]), mondays[4])
        XCTAssertEqual(RuleEndShift.firstLost(slots: mondays, ruleEnd: at("2027-01-04T22:00", taipei), plan: p), mondays[3])
    }

    /// MEDIUM 3: the listing has a cap, and a start already past the end is refused (round 5: after the
    /// listing, which gives its route; see `testAStartPastTheEndWithoutSlotsGivesTheCauseNotTheRoute`).
    func testTheListingIsBoundedAndAStartPastTheEndIsRefusedEarly() {
        let end = mondays[4]
        XCTAssertNotNil(RuleEndShift.listingRange(ruleEnd: end, plan: plan(planned: at("2026-12-07T11:00", taipei))))
        XCTAssertNil(RuleEndShift.listingRange(ruleEnd: end, plan: plan(planned: mondays[0].addingTimeInterval(400 * 86_400))))
        let range = RuleEndShift.listingRange(ruleEnd: end, plan: plan(planned: at("2026-12-07T11:00", taipei)))!
        XCTAssertLessThan(range.duration, 800 * 86_400)
        XCTAssertGreaterThan(range.end, end.addingTimeInterval(365 * 86_400), "an occurrence moved a year away is still listed")
        XCTAssertTrue(RuleEndShift.startsPastEnd(plannedStart: end.addingTimeInterval(1), ruleEnd: end))
        XCTAssertFalse(RuleEndShift.startsPastEnd(plannedStart: end, ruleEnd: end))
    }

    // MARK: - Texts

    func testTheTextsSayMayAndOfferTheRouteOnlyWhenTheRuleCanBeWritten() {
        let reason = RuleEndShift.lostReason(slot: mondays[4], ruleEnd: mondays[4], movedTo: at("2027-01-04T11:00", taipei),
                                             keepEnd: at("2027-01-04T11:00", taipei), zone: taipei, route: .passRule)
        XCTAssertTrue(reason.contains("2027-01-04T10:00:00+08:00"), reason)
        XCTAssertTrue(reason.contains("2027-01-04T11:00:00+08:00"), reason)
        XCTAssertTrue(reason.contains("may"), reason)
        XCTAssertTrue(reason.contains("end_date") && reason.contains("Nothing was written") && reason.contains("#509"), reason)
        let calendar = RuleEndShift.lostReason(slot: mondays[4], ruleEnd: mondays[4], movedTo: at("2027-01-04T11:00", taipei),
                                               keepEnd: at("2027-01-04T11:00", taipei), zone: taipei, route: .unwritableRule)
        XCTAssertFalse(calendar.contains("end_date"), calendar)
        XCTAssertTrue(calendar.contains("Calendar"), calendar)
        for cause in [RuleEndShift.Unchecked.unreadable, .unlisted, .unplaced, .empty, .tooFar, .allDay, .monthEnd, .unexpandable, .firstSlot] {
            let text = RuleEndShift.uncheckedReason(cause)
            XCTAssertTrue(text.contains("Nothing was written") && text.contains("Calendar"), text)
            XCTAssertFalse(text.contains("end_date") || text.contains("recurrence"), text)
        }
        XCTAssertTrue(RuleEndShift.pastEndReason(ruleEnd: mondays[4], zone: taipei).contains("2027-01-04T10:00:00+08:00"))
        // Round 3 LOW 6: not measured, so "may".
        XCTAssertTrue(RuleEndShift.pastEndReason(ruleEnd: mondays[4], zone: taipei).contains("may be dropped"))
        XCTAssertFalse(RuleEndShift.pastEndReason(ruleEnd: mondays[4], zone: taipei).contains("would remain"))
    }

    // MARK: - Round 2 findings

    private func listed(_ slots: [Date]) -> [RuleEndShift.Listed] {
        slots.map { RuleEndShift.Listed(isDetached: false, ridSlot: nil, occurrenceDate: $0, start: $0) }
    }

    /// Lists `slots` that fall in the range asked for, as the store does.
    private func listing(_ slots: [Date]) -> (DateInterval) -> [RuleEndShift.Listed]? {
        { range in self.listed(slots.filter { range.contains($0) }) }
    }

    private func refusal(_ slots: [Date], stored: [Date], passed: RuleEndShift.PassedRule? = nil, plan: RuleEndShift.Plan,
                         from: Date? = nil, allDay: Bool = false, route: RuleEndShift.Route = .passRule) -> String? {
        RuleEndShift.refusal(storedEnds: stored, passedRule: passed, plan: plan, from: from, allDay: allDay, route: route,
                             list: listing(slots))
    }

    /// HIGH 1: a series known to repeat whose rules cannot be read is not "no end": no series object
    /// (`ruleHolder == nil`) and a series object whose rules cannot be fetched both refuse.
    func testRulesThatCannotBeReadAreNotReadAsNoEnd() {
        XCTAssertNil(RuleEndShift.readRules(nil as [EKRecurrenceRule]?), "no series object")
        XCTAssertNil(RuleEndShift.readRules([EKRecurrenceRule]()), "a series object with no rules read")
        let unfetched = EKEvent(eventStore: SharedTestStore.store)
        XCTAssertNil(RuleEndShift.readRules(unfetched.recurrenceRules), "a series object whose rules cannot be fetched")
        let open = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        let read = RuleEndShift.readRules([open])
        XCTAssertEqual(read?.count, 1, "rules read with no end are read")
        // Read with no end: nothing is lost at an end, so the write goes on.
        XCTAssertNil(refusal(mondays, stored: read!.compactMap { $0.recurrenceEnd?.endDate },
                             plan: plan(planned: at("2026-12-07T11:00", taipei))))
        XCTAssertTrue(RuleEndShift.uncheckedReason(.unreadable).contains("could not be read"))
    }

    /// MEDIUM 2: a move of more than a year has its own reason, pointing to Calendar; following a
    /// recurrence retry with a later end_date would be refused the same way, so none is offered.
    func testAMoveOfMoreThanAYearPointsToCalendarAndARetryIsRefusedTheSame() {
        let far = plan(planned: mondays[0].addingTimeInterval(400 * 86_400))
        XCTAssertTrue(RuleEndShift.exceedsMaxShift(far))
        XCTAssertFalse(RuleEndShift.exceedsMaxShift(plan(planned: at("2026-12-07T11:00", taipei))))
        let first = refusal(mondays, stored: [at("2028-06-01T10:00", taipei)], plan: far)
        XCTAssertEqual(first, RuleEndShift.uncheckedReason(.tooFar))
        XCTAssertFalse(first!.contains("recurrence") || first!.contains("end_date"), first!)
        XCTAssertTrue(first!.contains("Calendar") && first!.contains("more than a year"), first!)
        let retry = refusal(mondays, stored: [at("2028-06-01T10:00", taipei)], passed: .end(at("2029-06-01T10:00", taipei)), plan: far)
        XCTAssertEqual(retry, RuleEndShift.uncheckedReason(.tooFar))
    }

    /// LOW 3 (d): a passed end far after the stored end is checked around the stored end, so a call
    /// that moves the series and extends it by years at once goes through.
    func testAPassedEndYearsAfterTheStoredEndGoesThrough() {
        let passed = at("2029-01-04T12:00", taipei)
        XCTAssertEqual(RuleEndShift.ends(stored: [mondays[4]], passedRule: .end(passed)), [.init(rule: passed, listAround: mondays[4])])
        XCTAssertNil(refusal(mondays, stored: [mondays[4]], passed: .end(passed), plan: plan(planned: at("2026-12-07T11:00", taipei))))
    }

    /// LOW 4: the end_date the refusal offers keeps every occurrence the move reaches, and a call that
    /// follows it goes through.
    func testFollowingTheOfferedEndDateGoesThrough() {
        let days = (0..<5).map { mondays[0].addingTimeInterval(Double($0) * 86_400) }
        let twoLater = plan(planned: days[0].addingTimeInterval(2 * 86_400), stored: days[0])
        let reason = refusal(days, stored: [days[4]], plan: twoLater)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("at or after 2026-12-13T10:00:00+08:00"), reason!)
        XCTAssertEqual(RuleEndShift.keepEnd(slots: days, ruleEnd: days[4], plan: twoLater), days[4].addingTimeInterval(2 * 86_400))
        XCTAssertNil(refusal(days, stored: [days[4]], passed: .end(days[4].addingTimeInterval(2 * 86_400)), plan: twoLater))
        // A passed end before the stored end: the offered end takes in the occurrences it then reaches.
        let early = refusal(days, stored: [days[4]], passed: .end(days[2]), plan: twoLater)
        XCTAssertTrue(early!.contains("at or after 2026-12-13T10:00:00+08:00"), early!)
        XCTAssertNil(refusal(days, stored: [days[4]], passed: .end(days[4].addingTimeInterval(2 * 86_400)), plan: twoLater))
        // Span future counts only the occurrences from its own slot.
        let future = plan(planned: days[3].addingTimeInterval(2 * 86_400), stored: days[3])
        XCTAssertEqual(RuleEndShift.keepEnd(slots: days, ruleEnd: days[4], plan: future, from: days[3]), days[4].addingTimeInterval(2 * 86_400))
        XCTAssertNil(refusal(days, stored: [days[4]], passed: .end(days[4].addingTimeInterval(2 * 86_400)), plan: future, from: days[3]))
    }

    /// LOW 3, LOW 6: a route only where one works. Through an occurrence's own id (#416, #428) a call
    /// cannot also pass the rule, so it points to Calendar, as an unwritable rule does.
    func testEachCauseHasARouteThatWorks() {
        func route(_ writable: Bool, own: Bool = false, standIn: Bool = false, days: Bool = false, ended: Bool = false) -> RuleEndShift.Route {
            RuleEndShift.route(ruleWritable: writable, addressesOwnOccurrence: own, viaStandIn: standIn, keepsDays: days,
                               endedAfterHappening: ended)
        }
        // Round 4 LOW 1: through a stand-in (#326) passing recurrence is refused, so Calendar.
        XCTAssertEqual(route(true, standIn: true), .standIn)
        XCTAssertEqual(route(true), .passRule)
        XCTAssertEqual(route(true, own: true), .ownOccurrence)
        XCTAssertEqual(route(false), .unwritableRule)
        XCTAssertEqual(route(false, own: true), .ownOccurrence)
        // Round 3: a rule with days of its own, and a series that ended after an occurrence happened.
        XCTAssertEqual(route(true, days: true), .ruleWithDays)
        XCTAssertEqual(route(true, ended: true), .endedSeries)
        XCTAssertEqual(route(false, days: true), .unwritableRule)
        let own = refusal(mondays, stored: [mondays[4]], plan: plan(planned: at("2026-12-07T11:00", taipei)), route: .ownOccurrence)
        XCTAssertFalse(own!.contains("end_date"), own!)
        XCTAssertTrue(own!.contains("Calendar") && own!.contains("#416"), own!)
        XCTAssertEqual(RuleEndShift.refusal(storedEnds: [mondays[4]], passedRule: nil, plan: plan(planned: at("2026-12-07T11:00", taipei)),
                                            from: nil, allDay: false, route: .passRule, list: { _ in nil }),
                       RuleEndShift.uncheckedReason(.unlisted))
        let unplaced = RuleEndShift.Listed(isDetached: true, ridSlot: nil, occurrenceDate: nil, start: mondays[4])
        XCTAssertEqual(RuleEndShift.refusal(storedEnds: [mondays[4]], passedRule: nil, plan: plan(planned: at("2026-12-07T11:00", taipei)),
                                            from: nil, allDay: false, route: .passRule, list: { _ in [unplaced] }),
                       RuleEndShift.uncheckedReason(.unplaced))
    }

    /// LOW 5: the note lists the measured shapes as the CHANGELOG does.
    func testTheLostReasonListsTheMeasuredShapes() {
        let reason = RuleEndShift.lostReason(slot: mondays[4], ruleEnd: mondays[4], movedTo: mondays[4], keepEnd: mondays[4],
                                             zone: taipei, route: .passRule)
        for shape in ["a later time or day on a weekly series", "a zone change across a daylight-saving change",
                      "a plain monthly series moved to the next month", "the series' rule passed again with the same end"] {
            XCTAssertTrue(reason.contains(shape), shape)
        }
    }

    /// LOW 7: how an all-day series' rule end compares with its days was not shown, so an all-day
    /// series with an end is refused as not checked; one with no end has nothing to compare.
    func testAnAllDaySeriesWithAnEndIsRefusedAsNotChecked() {
        let later = plan(planned: at("2026-12-08T00:00", taipei))
        XCTAssertEqual(refusal(mondays, stored: [mondays[4]], plan: later, allDay: true), RuleEndShift.uncheckedReason(.allDay))
        XCTAssertEqual(refusal(mondays, stored: [], passed: .end(mondays[4]), plan: later, allDay: true), RuleEndShift.uncheckedReason(.allDay))
        XCTAssertNil(refusal(mondays, stored: [], plan: later, allDay: true))
        XCTAssertTrue(RuleEndShift.uncheckedReason(.allDay).contains("all-day"))
    }

    // MARK: - Round 3 findings

    /// HIGH 1: a plain monthly or yearly rule repeats on its start's day and skips a month without
    /// it, while date addition clamps to the month's end. 2028-01-29 → 01-30 on a rule ending
    /// 2028-03-31 loses the leap-day February occurrence, and every reading stays inside the end.
    func testAPlainMonthlyRuleNearTheMonthEndIsNotChecked() {
        let slots = ["2028-01-29", "2028-02-29", "2028-03-29"].map { at($0 + "T10:00", taipei) }
        let end = at("2028-03-31T23:59", taipei)
        let p = plan(planned: at("2028-01-30T10:00", taipei), stored: slots[0], unit: .month)
        XCTAssertNil(RuleEndShift.firstLost(slots: slots, ruleEnd: end, plan: p), "the readings alone pass it")
        XCTAssertTrue(RuleEndShift.nearMonthEnd(p))
        XCTAssertEqual(refusal(slots, stored: [end], plan: p), RuleEndShift.uncheckedReason(.monthEnd))
        // The new start alone on the 29th-31st counts, and so does a yearly rule.
        let toEnd = plan(planned: at("2027-01-31T10:00", taipei), stored: at("2027-01-25T10:00", taipei), unit: .month)
        XCTAssertTrue(RuleEndShift.nearMonthEnd(toEnd))
        XCTAssertTrue(RuleEndShift.nearMonthEnd(plan(planned: at("2028-02-29T11:00", taipei), stored: at("2028-02-29T10:00", taipei), unit: .year)))
        // Days of its own, or a daily or weekly rule, or days before the 29th: checked as before.
        XCTAssertFalse(RuleEndShift.nearMonthEnd(plan(planned: at("2028-01-30T10:00", taipei), stored: slots[0], unit: .month, keepsDays: true)))
        XCTAssertFalse(RuleEndShift.nearMonthEnd(plan(planned: at("2028-01-30T10:00", taipei), stored: slots[0], unit: .day)))
        XCTAssertFalse(RuleEndShift.nearMonthEnd(plan(planned: at("2027-03-01T10:00", taipei), stored: at("2027-02-25T10:00", taipei), unit: .month)))
        XCTAssertTrue(RuleEndShift.uncheckedReason(.monthEnd).contains("29"))
    }

    /// MEDIUM 2: a change of all_day alone, with the start instant and zone unchanged (a series that
    /// starts at midnight), enters the check, and a rule with an end refuses it.
    func testAnAllDayToggleAloneIsRefusedOnASeriesWithAnEnd() {
        XCTAssertTrue(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: false, changesZone: false, changesAllDay: true))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: false, movesStart: false, changesZone: false, changesAllDay: true))
        let midnight = at("2026-12-07T00:00", taipei)
        let unchanged = plan(planned: midnight, stored: midnight)
        XCTAssertEqual(refusal([midnight], stored: [at("2027-01-04T00:00", taipei)], plan: unchanged, allDay: true),
                       RuleEndShift.uncheckedReason(.allDay))
    }

    /// MEDIUM 3: for a rule with days of its own the offered end_date can bring in an occurrence the
    /// series never had (Mon+Fri, start moved from Monday to Friday), so the refusal points to
    /// Calendar instead of offering one.
    func testARuleWithDaysOfItsOwnPointsToCalendar() {
        let slots = ["2026-12-07", "2026-12-11", "2026-12-14", "2026-12-18", "2027-01-08"].map { at($0 + "T10:00", taipei) }
        let p = plan(planned: at("2026-12-11T10:00", taipei), stored: slots[0], keepsDays: true)
        let reason = refusal(slots, stored: [slots[4]], plan: p, route: .ruleWithDays)
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason!.contains("end_date"), reason!)
        XCTAssertTrue(reason!.contains("Calendar") && reason!.contains("days of its own"), reason!)
    }

    /// LOW 7: once the series' rule has ended and an occurrence happened, a passed rule with a later
    /// end is refused by #451, so the refusal points to Calendar.
    func testAnEndedSeriesPointsToCalendar() {
        let reason = refusal(mondays, stored: [mondays[4]], plan: plan(planned: at("2026-12-07T11:00", taipei)), route: .endedSeries)
        XCTAssertFalse(reason!.contains("end_date"), reason!)
        XCTAssertTrue(reason!.contains("Calendar") && reason!.contains("#451"), reason!)
    }

    /// LOW 4: a listing with none of the series' occurrences near the end has its own words.
    func testAnEmptyListingHasItsOwnWords() {
        XCTAssertEqual(RuleEndShift.refusal(storedEnds: [mondays[4]], passedRule: nil, plan: plan(planned: at("2026-12-07T11:00", taipei)),
                                            from: nil, allDay: false, route: .passRule, list: { _ in [] }),
                       RuleEndShift.uncheckedReason(.empty))
        XCTAssertNotEqual(RuleEndShift.uncheckedReason(.empty), RuleEndShift.uncheckedReason(.unplaced))
        XCTAssertTrue(RuleEndShift.uncheckedReason(.empty).contains("no occurrence of the series was found"))
    }

    // MARK: - Round 4 findings

    private func parts(_ rule: EKRecurrenceRule) -> RuleEndShift.RuleParts { RuleEndShift.parts(rule) }

    private func yearly(months: [NSNumber]? = nil, weeks: [NSNumber]? = nil, positions: [NSNumber]? = nil,
                        weekdays: [EKRecurrenceDayOfWeek]? = nil, monthDays: [NSNumber]? = nil, yearDays: [NSNumber]? = nil) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: weekdays, daysOfTheMonth: monthDays, monthsOfTheYear: months,
                         weeksOfTheYear: weeks, daysOfTheYear: yearDays, setPositions: positions, end: nil)
    }

    /// HIGH: months of the year alone do not fix the day (it comes from the start), so a yearly rule
    /// on February with no day, moved from the 28th to the 29th, is refused as near the month end.
    func testAYearlyRuleOnFebruaryWithNoDayIsCheckedForTheMonthEnd() {
        let february = parts(yearly(months: [2]))
        XCTAssertFalse(february.fixesDay)
        XCTAssertTrue(february.expandable)
        let slots = ["2028-02-28", "2029-02-28", "2030-02-28", "2031-02-28"].map { at($0 + "T10:00", taipei) }
        let p = plan(planned: at("2028-02-29T10:00", taipei), stored: slots[0], unit: .year,
                     keepsDays: february.fixesDay, dayFromStart: !february.fixesDay)
        XCTAssertTrue(RuleEndShift.nearMonthEnd(p))
        XCTAssertEqual(refusal(slots, stored: [at("2032-03-01T10:00", taipei)], plan: p), RuleEndShift.uncheckedReason(.monthEnd))
        // A rule whose day is fixed is not; months with a day of the month fix the day.
        XCTAssertTrue(parts(yearly(months: [2], monthDays: [28])).fixesDay)
        XCTAssertTrue(parts(yearly(yearDays: [59])).fixesDay)
        // Several rules, one of them on the start's day: still checked for the month end.
        let mixed = plan(planned: at("2028-02-29T10:00", taipei), stored: slots[0], unit: .year, keepsDays: true, dayFromStart: true)
        XCTAssertTrue(RuleEndShift.nearMonthEnd(mixed))
    }

    /// HIGH, the other BY parts: weeks of the year or set positions with no day leave the day to the
    /// start in a way the check does not expand, so they are refused as not checked.
    func testWeeksOrPositionsWithNoDayAreNotChecked() {
        XCTAssertFalse(parts(yearly(weeks: [10])).expandable)
        XCTAssertFalse(parts(yearly(months: [2], positions: [-1])).expandable)
        let monday = EKRecurrenceDayOfWeek(.monday)
        XCTAssertTrue(parts(yearly(weeks: [10], weekdays: [monday])).expandable)
        XCTAssertTrue(parts(yearly(months: [2], positions: [-1], weekdays: [monday])).expandable)
        let p = plan(planned: at("2026-12-07T11:00", taipei), expandable: false)
        XCTAssertEqual(refusal(mondays, stored: [mondays[4]], plan: p), RuleEndShift.uncheckedReason(.unexpandable))
        XCTAssertNil(refusal(mondays, stored: [], plan: p), "no end: nothing to check")
    }

    /// LOW 5: the past-end refusal gives the route, and from the last occurrence before the end it
    /// points to span 'this'.
    func testThePastEndRefusalGivesARoute() {
        let past = plan(planned: at("2027-01-05T10:00", taipei))
        let reason = refusal(mondays, stored: [mondays[4]], plan: past)!
        XCTAssertTrue(reason.contains("may be dropped") && reason.contains("end_date at or after"), reason)
        let fromLast = plan(planned: at("2027-01-04T11:00", taipei), stored: mondays[4])
        let last = refusal(mondays, stored: [mondays[4]], plan: fromLast, from: mondays[4])!
        XCTAssertTrue(last.contains("span 'this'"), last)
        XCTAssertFalse(last.contains("end_date"), last)
        let calendar = refusal(mondays, stored: [mondays[4]], plan: past, route: .unwritableRule)!
        XCTAssertTrue(calendar.contains("Calendar") && !calendar.contains("end_date"), calendar)
    }

    /// INFO: an end passed in the call is named as that, not as the series' rule end.
    func testAPassedEndIsNamedAsTheCallsEnd() {
        let reason = refusal(mondays, stored: [mondays[4]], passed: .end(mondays[4]), plan: plan(planned: at("2026-12-07T11:00", taipei)))!
        XCTAssertTrue(reason.contains("the end_date in this call is"), reason)
        let stored = refusal(mondays, stored: [mondays[4]], plan: plan(planned: at("2026-12-07T11:00", taipei)))!
        XCTAssertTrue(stored.contains("the series' rule ends at"), stored)
    }

    // MARK: - Round 5 findings

    /// MEDIUM: through the series id with span all, a first occurrence moved on its own (10:00 to
    /// 11:00) shows its moved time, while the store may re-expand the rule from its slot. Weekly at
    /// 10:00, the rule ending on the last day at 10:30, start_time 10:40 on the first day: read from the
    /// shown start alone it is 20 minutes earlier and kept everything; from the slot it is 40 minutes
    /// later and the last occurrence may be dropped. Read from the rule's semantics, not measured.
    func testThroughTheSeriesIdAFirstOccurrenceMovedOnItsOwnIsReadFromItsSlot() {
        let shown = at("2026-12-07T11:00", taipei)
        let end = at("2027-01-04T10:30", taipei)
        let planned = at("2026-12-07T10:40", taipei)
        func plan(_ starts: [Date]) -> RuleEndShift.Plan {
            .init(storedStarts: starts, plannedStart: planned, storedZone: taipei, newZone: taipei, unit: .day,
                  keepsDays: false, dayFromStart: true, expandable: true)
        }
        XCTAssertNil(refusal(mondays, stored: [end], plan: plan([shown])), "the shown start alone lets it through")
        // The object's occurrenceDate may report the moved time (2026-10-10), so the slot is the proven one.
        let starts = RuleEndShift.storedStarts(shown: shown, slot: shown, needsFirstSlot: true, firstSlot: mondays[0])
        XCTAssertEqual(starts, [shown, shown, mondays[0]])
        let reason = refusal(mondays, stored: [end], plan: plan(starts!))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("2027-01-04T10:00:00+08:00") && reason!.contains("Nothing was written"), reason!)
        // A first slot that cannot be shown refuses (fail closed); a route that needs none reads the two.
        XCTAssertNil(RuleEndShift.storedStarts(shown: shown, slot: shown, needsFirstSlot: true, firstSlot: nil))
        XCTAssertEqual(RuleEndShift.storedStarts(shown: shown, slot: mondays[0], needsFirstSlot: false, firstSlot: nil), [shown, mondays[0]])
        let firstSlot = RuleEndShift.uncheckedReason(.firstSlot)
        XCTAssertTrue(firstSlot.contains("first occurrence") && firstSlot.contains("Calendar"), firstSlot)
    }

    /// MEDIUM, the gate: writing the shown start back moves the series from its slot, so it enters the
    /// check; through the series id over the whole series any date written enters, and the stored
    /// starts then decide whether anything moves.
    func testWritingTheShownStartBackFromAMovedSlotEntersTheCheck() {
        let shown = at("2026-12-07T11:00", taipei)
        XCTAssertTrue(RuleEndShift.moves(planned: shown, from: [shown, mondays[0]]))
        XCTAssertFalse(RuleEndShift.moves(planned: mondays[0], from: [mondays[0], mondays[0]]))
        XCTAssertTrue(RuleEndShift.mayMoveStart(planned: shown, from: [shown, mondays[0]], writesDates: true, firstSlotUnread: false))
        XCTAssertFalse(RuleEndShift.mayMoveStart(planned: shown, from: [shown, shown], writesDates: true, firstSlotUnread: false))
        XCTAssertTrue(RuleEndShift.mayMoveStart(planned: shown, from: [shown, shown], writesDates: true, firstSlotUnread: true))
        XCTAssertFalse(RuleEndShift.mayMoveStart(planned: shown, from: [shown, mondays[0]], writesDates: false, firstSlotUnread: true),
                       "no date written: a zone or all-day change enters on its own")
    }

    /// LOW: a move of more than a year that also passes the end is refused as too far, with no route
    /// through recurrence (a retry would be refused the same); and a new start past the end with no
    /// listing, an empty one or one that cannot be placed gets that cause, not the recurrence route.
    func testAStartPastTheEndWithoutSlotsGivesTheCauseNotTheRoute() {
        let far = plan(planned: mondays[0].addingTimeInterval(400 * 86_400))
        XCTAssertTrue(RuleEndShift.startsPastEnd(plannedStart: far.plannedStart, ruleEnd: mondays[4]))
        XCTAssertEqual(refusal(mondays, stored: [mondays[4]], plan: far), RuleEndShift.uncheckedReason(.tooFar))
        let past = plan(planned: at("2027-01-05T10:00", taipei))
        func decide(_ list: @escaping (DateInterval) -> [RuleEndShift.Listed]?) -> String? {
            RuleEndShift.refusal(storedEnds: [mondays[4]], passedRule: nil, plan: past, from: nil, allDay: false, route: .passRule, list: list)
        }
        XCTAssertEqual(decide { _ in nil }, RuleEndShift.uncheckedReason(.unlisted))
        XCTAssertEqual(decide { _ in [] }, RuleEndShift.uncheckedReason(.empty))
        let unplaced = RuleEndShift.Listed(isDetached: true, ridSlot: nil, occurrenceDate: nil, start: mondays[4])
        XCTAssertEqual(decide { _ in [unplaced] }, RuleEndShift.uncheckedReason(.unplaced))
    }

    /// LOW: the recurrence route says #503 can still refuse it (an occurrence deleted on its own, or
    /// one that check cannot rule out); a rule with days of its own is told span 'this' needs one of
    /// its days (#454). The not-checked texts no longer say every rule ends at a fixed time (a count
    /// rule does not).
    func testTheRoutesSayWhatCanStillRefuseThem() {
        let reason = refusal(mondays, stored: [mondays[4]], plan: plan(planned: at("2026-12-07T11:00", taipei)))!
        XCTAssertTrue(reason.contains("#503") && reason.contains("deleted on its own"), reason)
        let fromLast = plan(planned: at("2027-01-04T11:00", taipei), stored: mondays[4], keepsDays: true)
        let last = refusal(mondays, stored: [mondays[4]], plan: fromLast, from: mondays[4], route: .ruleWithDays)!
        XCTAssertTrue(last.contains("span 'this'") && last.contains("#454"), last)
        for cause in [RuleEndShift.Unchecked.unreadable, .unlisted, .unplaced, .empty, .tooFar, .allDay, .monthEnd, .unexpandable, .firstSlot] {
            XCTAssertFalse(RuleEndShift.uncheckedReason(cause).contains("ends at a fixed time"), "\(cause)")
        }
    }
}
