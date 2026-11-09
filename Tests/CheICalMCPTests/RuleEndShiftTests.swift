import XCTest
@testable import CheICalMCP

/// #509: a start change over a series re-expands its rule up to the same end instant, so an
/// occurrence whose moved start is after that end is lost (device, iCloud, 2026-11-09). The cases
/// below are the measured ones (#509's Diagnosis), plus the zone and day-rule variants.
final class RuleEndShiftTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let newYork = TimeZone(identifier: "America/New_York")!

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

    private func lost(end: String, planned: String, keepsDays: Bool = false, newZone: TimeZone? = nil) -> Date? {
        RuleEndShift.firstLost(
            slots: mondays, ruleEnd: at(end, taipei), storedStart: mondays[0], plannedStart: at(planned, taipei),
            storedZone: taipei, newZone: newZone ?? taipei, keepsDays: keepsDays)
    }

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

    /// A rule with days of its own keeps its days and takes the new time of day, so the same move
    /// can push the occurrence on the end's day past the end.
    func testARuleWithDaysIsReadAtTheNewTimeOfDay() {
        XCTAssertEqual(lost(end: "2027-01-04T10:00", planned: "2026-12-06T11:00", keepsDays: true), mondays[4])
        XCTAssertNil(lost(end: "2027-01-04T10:00", planned: "2026-12-06T09:00", keepsDays: true))
    }

    func testSlotsAfterTheEndAreNotCounted() {
        XCTAssertNil(RuleEndShift.firstLost(
            slots: mondays, ruleEnd: at("2026-12-28T10:00", taipei), storedStart: mondays[0],
            plannedStart: at("2026-12-07T09:00", taipei), storedZone: taipei, newZone: taipei, keepsDays: false))
        XCTAssertEqual(RuleEndShift.firstLost(
            slots: mondays, ruleEnd: at("2026-12-28T10:00", taipei), storedStart: mondays[0],
            plannedStart: at("2026-12-07T11:00", taipei), storedZone: taipei, newZone: taipei, keepsDays: false), mondays[3])
    }

    /// The store moves occurrences by wall clock: across a DST start a one-day move is 23 hours,
    /// and the occurrence after the change still moves a whole day.
    func testAShiftAcrossDaylightSavingTimeIsReadByTheWallClock() {
        let slots = ["2027-03-13T10:00", "2027-03-20T10:00"].map { at($0, newYork) }
        XCTAssertEqual(RuleEndShift.firstLost(
            slots: slots, ruleEnd: at("2027-03-21T09:30", newYork), storedStart: slots[0],
            plannedStart: at("2027-03-14T10:00", newYork), storedZone: newYork, newZone: newYork, keepsDays: false), slots[1])
    }

    func testTheNewZoneIsUsedForTheNewTimeOfDay() {
        // 11:00 in Tokyo is 10:00 in Taipei: the occurrence at the end stays.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertNil(RuleEndShift.firstLost(
            slots: mondays, ruleEnd: at("2027-01-04T10:00", taipei), storedStart: mondays[0],
            plannedStart: at("2026-12-07T10:00", taipei), storedZone: taipei, newZone: tokyo, keepsDays: true))
    }

    func testTheWindowReachesBackPastTheShift() {
        let end = at("2027-01-04T10:00", taipei)
        let window = RuleEndShift.listingWindow(ruleEnd: end, storedStart: mondays[0],
                                                plannedStart: mondays[0].addingTimeInterval(7 * 86_400))
        XCTAssertLessThanOrEqual(window.start, end.addingTimeInterval(-9 * 86_400))
        XCTAssertGreaterThan(window.end, end)
        let small = RuleEndShift.listingWindow(ruleEnd: end, storedStart: mondays[0], plannedStart: mondays[0].addingTimeInterval(-3_600))
        XCTAssertLessThanOrEqual(small.start, end.addingTimeInterval(-2 * 86_400))
        XCTAssertLessThan(small.duration, 4 * 86_400)
    }

    func testItAppliesOnlyToAStartMoveOverTheRestOfASeriesWithItsStoredRule() {
        let start = mondays[0], later = mondays[0].addingTimeInterval(3_600)
        XCTAssertTrue(RuleEndShift.applies(repeats: true, reachesEnd: true, writesRule: false, storedStart: start, plannedStart: later))
        XCTAssertFalse(RuleEndShift.applies(repeats: false, reachesEnd: true, writesRule: false, storedStart: start, plannedStart: later))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: false, writesRule: false, storedStart: start, plannedStart: later))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: true, writesRule: true, storedStart: start, plannedStart: later))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: true, writesRule: false, storedStart: start, plannedStart: start))
        XCTAssertFalse(RuleEndShift.applies(repeats: true, reachesEnd: true, writesRule: false, storedStart: start, plannedStart: nil))
    }

    func testTheReasonNamesTheOccurrenceTheEndAndTheMeasuredRoute() {
        let reason = RuleEndShift.lostReason(slot: mondays[4], ruleEnd: at("2027-01-04T10:00", taipei),
                                             movedTo: at("2027-01-04T11:00", taipei), zone: taipei)
        XCTAssertTrue(reason.contains("2027-01-04T10:00:00+08:00"), reason)
        XCTAssertTrue(reason.contains("2027-01-04T11:00:00+08:00"), reason)
        XCTAssertTrue(reason.contains("Nothing was written"), reason)
        XCTAssertTrue(reason.contains("recurrence"), reason)
        XCTAssertTrue(reason.contains("end_date"), reason)
        XCTAssertTrue(reason.contains("#509"), reason)
        XCTAssertTrue(RuleEndShift.unknownReason.contains("Nothing was written"))
    }
}
