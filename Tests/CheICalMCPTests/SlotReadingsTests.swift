import EventKit
import XCTest
@testable import CheICalMCP

/// #539: the two readings of an edited occurrence's `/RID=` (`SlotReadings`) and the rule for placing
/// one on the series' slots. Every test names its host zone; none reads the process's.
final class SlotReadingsTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func rid(_ instant: Date) -> String { "S/RID=\(Int(instant.timeIntervalSinceReferenceDate))" }

    // MARK: - the two readings

    /// Cell F1 of #539: the occurrence of 2027-02-25 10:00 in Taipei, edited while the series had no
    /// zone, reads `/RID=` of 2027-02-25T10:00:00Z. Its instant reading is 10:00Z, its wall-clock
    /// reading 10:00 in Taipei (02:00Z), the slot.
    func testATimedRIDHasAnInstantAndAWallClockReading() throws {
        let digits = date(2027, 2, 25, 10, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: false, zone: taipei))
        XCTAssertEqual(readings.instant, digits)
        XCTAssertEqual(readings.wallClock, date(2027, 2, 25, 10, in: taipei))
        XCTAssertEqual(readings.all, [digits, date(2027, 2, 25, 10, in: taipei)])
    }

    /// West of UTC the wall-clock reading is later than the instant one (cell L1).
    func testTheWallClockReadingFollowsTheHostZone() throws {
        let digits = date(2027, 2, 25, 18, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: false, zone: losAngeles))
        XCTAssertEqual(readings.wallClock, date(2027, 2, 25, 18, in: losAngeles))
        XCTAssertEqual(readings.wallClock?.timeIntervalSince(digits), 8 * 3600)
    }

    /// On a host at UTC the two readings are one instant (cell U1): one reading.
    func testAtUTCThereIsOneReading() throws {
        let digits = date(2027, 2, 25, 20, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: false, zone: utc))
        XCTAssertNil(readings.wallClock)
        XCTAssertEqual(readings.all, [digits])
    }

    /// The external identifier is read when the event identifier has no `/RID=`, as `originalSlot` does.
    func testTheExternalIdentifierIsReadToo() throws {
        let digits = date(2027, 2, 25, 10, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: "S", externalIdentifier: "UID-" + rid(digits), occurrenceDate: nil,
                                                     isAllDay: false, zone: taipei))
        XCTAssertEqual(readings.all, [digits, date(2027, 2, 25, 10, in: taipei)])
    }

    /// An all-day occurrence keeps the one reading `ruleSlot` gave it: local midnight of its day.
    func testAnAllDayRIDHasOneReading() throws {
        let digits = date(2028, 5, 8, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: true, zone: taipei))
        XCTAssertEqual(readings.all, [date(2028, 5, 8, in: taipei)])
    }

    /// Without a `/RID=`, the `occurrenceDate`, one reading; with neither, none.
    func testWithoutARIDTheOccurrenceDateIsTheOneReading() throws {
        let slot = date(2027, 2, 25, 10, in: taipei)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: "S", externalIdentifier: "UID-S", occurrenceDate: slot,
                                                     isAllDay: false, zone: taipei))
        XCTAssertEqual(readings.all, [slot])
        XCTAssertNil(SlotReadings.of(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: nil, isAllDay: false, zone: taipei))
    }

    // MARK: - place

    func testOnlyTheInstantIsASlot() {
        let readings = SlotReadings(instant: date(2027, 2, 25, 2, in: utc), wallClock: date(2027, 2, 25, 2, in: taipei))
        XCTAssertEqual(readings.place(among: [date(2027, 2, 18, 2, in: utc), date(2027, 2, 25, 2, in: utc)]), date(2027, 2, 25, 2, in: utc))
    }

    func testOnlyTheWallClockIsASlot() {
        let readings = SlotReadings(instant: date(2027, 2, 25, 10, in: utc), wallClock: date(2027, 2, 25, 10, in: taipei))
        XCTAssertEqual(readings.place(among: [date(2027, 2, 18, 10, in: taipei), date(2027, 2, 25, 10, in: taipei)]),
                       date(2027, 2, 25, 10, in: taipei))
    }

    func testNeitherIsASlotIsNotPlaced() {
        let readings = SlotReadings(instant: date(2027, 2, 25, 10, in: utc), wallClock: date(2027, 2, 25, 10, in: taipei))
        XCTAssertNil(readings.place(among: [date(2027, 2, 25, 11, in: taipei)]))
        XCTAssertNil(readings.place(among: [Date]()))
    }

    /// A made-up slot list holding both readings: not placed (no rule EventKit writes gives two slots
    /// this close).
    func testBothAreSlotsIsNotPlaced() {
        let readings = SlotReadings(instant: date(2027, 2, 25, 10, in: utc), wallClock: date(2027, 2, 25, 10, in: taipei))
        XCTAssertNil(readings.place(among: [date(2027, 2, 25, 10, in: utc), date(2027, 2, 25, 10, in: taipei)]))
    }

    /// Two readings that are one instant are one reading, placed when it is a slot.
    func testEqualReadingsAreOne() {
        let at = date(2027, 2, 25, 10, in: utc)
        let readings = SlotReadings(instant: at, wallClock: at.addingTimeInterval(0.3))
        XCTAssertNil(readings.wallClock)
        XCTAssertEqual(readings.place(among: [at]), at)
    }

    /// `slot(placedAmong:)`: the placed reading, else the instant one, and the instant one with no slots.
    func testTheReaderFallbackIsTheInstantReading() {
        let readings = SlotReadings(instant: date(2027, 2, 25, 10, in: utc), wallClock: date(2027, 2, 25, 10, in: taipei))
        XCTAssertEqual(readings.slot(placedAmong: [date(2027, 2, 25, 10, in: taipei)]), date(2027, 2, 25, 10, in: taipei))
        XCTAssertEqual(readings.slot(placedAmong: [date(2027, 3, 4, 10, in: taipei)]), readings.instant)
        XCTAssertEqual(readings.slot(placedAmong: nil), readings.instant)
    }

    // MARK: - daylight-saving days in the host's zone (fail closed, not measured)

    /// 2027-03-14 02:30 does not exist in Los Angeles. Foundation places it at some instant; whatever
    /// it is, when the rule's slot that day is another instant the record is not placed.
    func testAWallClockTimeInTheSpringGapIsNotPlacedOnAnotherInstant() throws {
        let digits = date(2027, 3, 14, 2, 30, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: false, zone: losAngeles))
        let given = try XCTUnwrap(readings.wallClock)
        let other = given.addingTimeInterval(3600)
        XCTAssertNil(readings.place(among: [other, other.addingTimeInterval(7 * 86_400)]))
        XCTAssertEqual(readings.place(among: [given]), given, "placed only on the instant Foundation gave")
    }

    /// 2027-11-07 01:30 exists twice in Los Angeles: placed only on the one Foundation gives.
    func testAWallClockTimeInTheAutumnOverlapIsPlacedOnlyOnFoundationsInstant() throws {
        let digits = date(2027, 11, 7, 1, 30, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: false, zone: losAngeles))
        let given = try XCTUnwrap(readings.wallClock)
        let otherOne = abs(given.timeIntervalSince(date(2027, 11, 7, 8, 30, in: utc))) < 1
            ? date(2027, 11, 7, 9, 30, in: utc) : date(2027, 11, 7, 8, 30, in: utc)
        XCTAssertNil(readings.place(among: [otherOne]))
        XCTAssertEqual(readings.place(among: [given]), given)
    }

    // MARK: - per frequency: an occurrence edited floating lands on its own slot and on no neighbour

    private func rule(_ frequency: EKRecurrenceFrequency, interval: Int = 1, days: [Int] = [], monthDays: [Int] = [],
                      count: Int) -> DeletedOccurrenceCheck.Rule {
        DeletedOccurrenceCheck.Rule(frequency: frequency, interval: interval, daysOfWeek: days, daysOfMonth: monthDays,
                                    endDate: nil, occurrenceCount: count, hasOtherParts: false)
    }

    /// Daily, weekly on three days, monthly on two days and yearly, hosts at +08:00 and -08:00: for
    /// every slot, the `/RID=` written floating (its wall clock as UTC) is placed on that slot and only
    /// there; the same `/RID=` written as an instant (zoned) is placed on that slot too.
    func testEveryFrequencyPlacesBothKindsOnTheirOwnSlot() throws {
        for zone in [taipei, losAngeles] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let first = date(2027, 1, 4, 22, in: zone)   // a Monday, late in the evening
            let rules = [rule(.daily, count: 30), rule(.weekly, days: [2, 4, 6], count: 30),
                         rule(.monthly, monthDays: [4, 5], count: 24), rule(.yearly, count: 5)]
            for rule in rules {
                let slots = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule, firstStart: first,
                                                                              until: first.addingTimeInterval(6 * 366 * 86_400),
                                                                              calendar: calendar))
                let set = InstantSet(slots)
                for slot in slots {
                    let wall = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: slot)
                    let floatingDigits = date(wall.year!, wall.month!, wall.day!, wall.hour!, wall.minute!, in: utc)
                    let floating = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(floatingDigits), externalIdentifier: nil,
                                                                 occurrenceDate: nil, isAllDay: false, zone: zone))
                    XCTAssertEqual(floating.place(among: set), slot, "\(rule.frequency.rawValue) in \(zone.identifier)")
                    let zoned = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(slot), externalIdentifier: nil,
                                                              occurrenceDate: nil, isAllDay: false, zone: zone))
                    XCTAssertEqual(zoned.place(among: set), slot, "\(rule.frequency.rawValue) in \(zone.identifier), zoned")
                }
            }
        }
    }
}
