import EventKit
import XCTest
@testable import CheICalMCP

/// #539: the two readings of an edited occurrence's `/RID=` (`SlotReadings`). Every test names its host
/// zone; none reads the process's. PR #558 round 3: the placement of a reading on the series' slots is
/// withdrawn, and its tests with it; fix round 4: only the #321 slot check reads the wall-clock reading.
final class SlotReadingsTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func rid(_ instant: Date) -> String { "S/RID=\(Int(instant.timeIntervalSinceReferenceDate))" }

    /// Every reading, the instant first.
    private func all(_ readings: SlotReadings) -> [Date] { [readings.instant] + (readings.wallClock.map { [$0] } ?? []) }

    // MARK: - the two readings

    /// Cell F1 of #539: the occurrence of 2027-02-25 10:00 in Taipei, edited while the series had no
    /// zone, reads `/RID=` of 2027-02-25T10:00:00Z. Its instant reading is 10:00Z, its wall-clock
    /// reading 10:00 in Taipei (02:00Z), the slot.
    // spec-example: undo-history-discard / the two readings of an identifier
    func testATimedRIDHasAnInstantAndAWallClockReading() throws {
        let digits = date(2027, 2, 25, 10, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: false, zone: taipei))
        XCTAssertEqual(readings.instant, digits)
        XCTAssertEqual(readings.wallClock, date(2027, 2, 25, 10, in: taipei))
        XCTAssertEqual(all(readings), [digits, date(2027, 2, 25, 10, in: taipei)])
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
        XCTAssertEqual(all(readings), [digits])
    }

    /// The external identifier is read when the event identifier has no `/RID=`, as `originalSlot` does.
    func testTheExternalIdentifierIsReadToo() throws {
        let digits = date(2027, 2, 25, 10, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: "S", externalIdentifier: "UID-" + rid(digits), occurrenceDate: nil,
                                                     isAllDay: false, zone: taipei))
        XCTAssertEqual(all(readings), [digits, date(2027, 2, 25, 10, in: taipei)])
    }

    /// An all-day occurrence keeps the one reading `ruleSlot` gave it: local midnight of its day.
    func testAnAllDayRIDHasOneReading() throws {
        let digits = date(2028, 5, 8, in: utc)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: rid(digits), externalIdentifier: nil, occurrenceDate: nil,
                                                     isAllDay: true, zone: taipei))
        XCTAssertEqual(all(readings), [date(2028, 5, 8, in: taipei)])
    }

    /// Without a `/RID=`, the `occurrenceDate`, one reading; with neither, none.
    func testWithoutARIDTheOccurrenceDateIsTheOneReading() throws {
        let slot = date(2027, 2, 25, 10, in: taipei)
        let readings = try XCTUnwrap(SlotReadings.of(eventIdentifier: "S", externalIdentifier: "UID-S", occurrenceDate: slot,
                                                     isAllDay: false, zone: taipei))
        XCTAssertEqual(all(readings), [slot])
        XCTAssertNil(SlotReadings.of(eventIdentifier: "S", externalIdentifier: nil, occurrenceDate: nil, isAllDay: false, zone: taipei))
    }

    /// Two readings that are one instant are one reading.
    func testEqualReadingsAreOne() {
        let at = date(2027, 2, 25, 10, in: utc)
        let readings = SlotReadings(instant: at, wallClock: at.addingTimeInterval(0.3))
        XCTAssertNil(readings.wallClock)
        XCTAssertEqual(all(readings), [at])
    }
}
