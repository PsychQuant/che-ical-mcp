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
                      unit: RuleEndShift.Unit = .day, keepsDays: Bool = false) -> RuleEndShift.Plan {
        .init(storedStarts: [stored ?? mondays[0]], plannedStart: planned, storedZone: storedZone ?? taipei,
              newZone: newZone ?? storedZone ?? taipei, unit: unit, keepsDays: keepsDays)
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
                                  storedZone: taipei, newZone: taipei, unit: .day, keepsDays: false)
        XCTAssertEqual(RuleEndShift.firstLost(slots: mondays, ruleEnd: mondays[4], plan: p), mondays[4])
    }

    func testItAppliesToAStartOrZoneChangeOverTheRestOfASeries() {
        XCTAssertTrue(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: true, changesZone: false))
        XCTAssertTrue(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: false, changesZone: true))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: true, movesStart: false, changesZone: false))
        XCTAssertFalse(RuleEndShift.applies(repeats: false, reachesEnd: true, movesStart: true, changesZone: true))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: false, movesStart: true, changesZone: true))
    }

    /// MEDIUM 6: a rule passed in the call is checked against its own end; a count or no end drops
    /// nothing at the end.
    func testAPassedRuleIsCheckedAgainstItsOwnEnd() {
        let stored = [mondays[4]]
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: nil), stored)
        XCTAssertEqual(RuleEndShift.ends(stored: stored, passedRule: .end(at("2027-01-04T11:00", taipei))), [at("2027-01-04T11:00", taipei)])
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

    /// MEDIUM 3: the listing has a cap, and a start already past the end is refused before any read.
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
                                             zone: taipei, ruleWritable: true)
        XCTAssertTrue(reason.contains("2027-01-04T10:00:00+08:00"), reason)
        XCTAssertTrue(reason.contains("2027-01-04T11:00:00+08:00"), reason)
        XCTAssertTrue(reason.contains("may"), reason)
        XCTAssertTrue(reason.contains("end_date") && reason.contains("Nothing was written") && reason.contains("#509"), reason)
        let calendar = RuleEndShift.lostReason(slot: mondays[4], ruleEnd: mondays[4], movedTo: at("2027-01-04T11:00", taipei),
                                               zone: taipei, ruleWritable: false)
        XCTAssertFalse(calendar.contains("end_date"), calendar)
        XCTAssertTrue(calendar.contains("Calendar"), calendar)
        XCTAssertTrue(RuleEndShift.unknownReason(ruleWritable: true).contains("Nothing was written"))
        XCTAssertFalse(RuleEndShift.unknownReason(ruleWritable: false).contains("end_date"))
        XCTAssertTrue(RuleEndShift.pastEndReason(ruleEnd: mondays[4], zone: taipei).contains("2027-01-04T10:00:00+08:00"))
    }
}
