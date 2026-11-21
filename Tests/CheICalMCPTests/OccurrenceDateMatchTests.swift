import XCTest
@testable import CheICalMCP

/// #543: `occurrence_date` passed with an occurrence's own identifier names the day the occurrence
/// starts on or its original day, read from its `/RID=` with the series' all-day flag, on any host.
/// Every zone is a parameter, so these answer the same in every process zone (`TZ`).
final class OccurrenceDateMatchTests: XCTestCase {
    private static let utc = TimeZone(identifier: "UTC")!

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// `<series id>/RID=<seconds since 2001-01-01>`, as iCloud writes an occurrence edited on its own.
    private static func identifier(rid: Date) -> String {
        "SERIES-543/RID=\(Int(rid.timeIntervalSinceReferenceDate))"
    }

    // spec-example: occurrence-date-own-identifier / one shape on five host zones
    func testAnAllDayOccurrencesOriginalDayIsItsDayOnEveryHost() {
        // An all-day weekly series: the occurrence of 2026-12-28 (its /RID= the floating date, 00:00 UTC)
        // was moved on its own to 2026-12-30.
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        let expected: [Int: Bool] = [27: false, 28: true, 29: false, 30: true]
        for name in ["Pacific/Pago_Pago", "America/Los_Angeles", "UTC", "Asia/Taipei", "Pacific/Kiritimati"] {
            let host = TimeZone(identifier: name)!
            let shown = Self.day(2026, 12, 30, in: host)
            for (requestedDay, accepted) in expected.sorted(by: { $0.key < $1.key }) {
                let requested = Self.day(2026, 12, requestedDay, in: host)
                XCTAssertEqual(
                    OccurrenceDateMatch.matches(requested: requested, start: shown, startIsAllDay: true, zone: nil,
                                                eventIdentifier: Self.identifier(rid: rid), externalIdentifier: nil,
                                                occurrenceDate: shown, seriesIsAllDay: true, host: host),
                    accepted, "host \(name), occurrence_date 2026-12-\(requestedDay)")
            }
        }
    }

    /// The /RID= on the external identifier alone is read the same way.
    func testTheExternalIdentifiersRIDIsReadToo() {
        let host = TimeZone(identifier: "America/Los_Angeles")!
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        let shown = Self.day(2026, 12, 30, in: host)
        func matches(_ requestedDay: Int) -> Bool {
            OccurrenceDateMatch.matches(requested: Self.day(2026, 12, requestedDay, in: host), start: shown, startIsAllDay: true,
                                        zone: nil, eventIdentifier: "OTHER-ID", externalIdentifier: Self.identifier(rid: rid),
                                        occurrenceDate: nil, seriesIsAllDay: true, host: host)
        }
        XCTAssertTrue(matches(28))
        XCTAssertFalse(matches(27))
    }

    // spec-example: occurrence-date-own-identifier / A timed series' occurrence made all-day on its own
    func testATimedSeriesOccurrenceMadeAllDayKeepsTheInstantReading() {
        // Slot 2026-12-28 07:00 at Asia/Taipei is 2026-12-27 23:00 UTC: read as a floating date it would be the 27th.
        let host = TimeZone(identifier: "Asia/Taipei")!
        let rid = Self.day(2026, 12, 28, hour: 7, in: host)
        let shown = Self.day(2026, 12, 30, in: host)
        func matches(_ requestedDay: Int) -> Bool {
            OccurrenceDateMatch.matches(requested: Self.day(2026, 12, requestedDay, in: host), start: shown, startIsAllDay: true,
                                        zone: nil, eventIdentifier: Self.identifier(rid: rid), externalIdentifier: nil,
                                        occurrenceDate: shown, seriesIsAllDay: false, host: host)
        }
        XCTAssertTrue(matches(28))
        XCTAssertFalse(matches(27))
        XCTAssertTrue(matches(30), "the day it shows")
    }

    /// An all-day series' occurrence made timed on its own: its /RID= is still the floating date.
    func testAnAllDaySeriesOccurrenceMadeTimedKeepsTheFloatingReading() {
        let host = TimeZone(identifier: "America/Los_Angeles")!
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        let shown = Self.day(2026, 12, 30, hour: 10, in: host)
        func matches(_ requestedDay: Int) -> Bool {
            OccurrenceDateMatch.matches(requested: Self.day(2026, 12, requestedDay, in: host), start: shown, startIsAllDay: false,
                                        zone: host, eventIdentifier: Self.identifier(rid: rid), externalIdentifier: nil,
                                        occurrenceDate: shown, seriesIsAllDay: true, host: host)
        }
        XCTAssertTrue(matches(28))
        XCTAssertFalse(matches(27))
        XCTAssertTrue(matches(30), "the day it shows")
        XCTAssertFalse(matches(29))
    }

    /// The original slot is compared with the series' flag, not the occurrence's: an all-day series'
    /// occurrence made timed in a zone far from the host. Host UTC+14: the slot 2026-12-28 00:00 is
    /// 2026-12-26 23:00 at UTC−11, so compared as a timed instant in the occurrence's zone it would be the 26th.
    func testTheOriginalSlotIsComparedWithTheSeriesFlag() {
        let host = TimeZone(identifier: "Pacific/Kiritimati")!
        let zone = TimeZone(identifier: "Pacific/Pago_Pago")!
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        let shown = Self.day(2026, 12, 30, hour: 10, in: zone)
        func matches(_ requestedDay: Int) -> Bool {
            OccurrenceDateMatch.matches(requested: Self.day(2026, 12, requestedDay, in: zone), start: shown, startIsAllDay: false,
                                        zone: zone, eventIdentifier: Self.identifier(rid: rid), externalIdentifier: nil,
                                        occurrenceDate: shown, seriesIsAllDay: true, host: host)
        }
        XCTAssertTrue(matches(28))
        XCTAssertFalse(matches(26))
        XCTAssertFalse(matches(27))
        XCTAssertTrue(matches(30), "the day it shows")
    }

    /// A timed occurrence of a timed series, as on `main`: the /RID= is the slot's instant.
    func testATimedOccurrenceIsReadAsBefore() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let host = TimeZone(identifier: "Asia/Taipei")!
        let rid = Self.day(2026, 12, 28, hour: 9, in: zone)
        let shown = Self.day(2026, 12, 30, hour: 9, in: zone)
        func matches(_ requestedDay: Int) -> Bool {
            OccurrenceDateMatch.matches(requested: Self.day(2026, 12, requestedDay, in: zone), start: shown, startIsAllDay: false,
                                        zone: zone, eventIdentifier: Self.identifier(rid: rid), externalIdentifier: nil,
                                        occurrenceDate: shown, seriesIsAllDay: false, host: host)
        }
        XCTAssertTrue(matches(28))
        XCTAssertTrue(matches(30))
        XCTAssertFalse(matches(27))
        XCTAssertFalse(matches(29))
    }

    /// Without a /RID=, the original slot is `occurrenceDate`, already a day of the host for an all-day occurrence.
    func testWithoutRIDTheOccurrenceDateIsTheOriginalDay() {
        let host = TimeZone(identifier: "America/Los_Angeles")!
        let slot = Self.day(2026, 12, 28, in: host)
        let shown = Self.day(2026, 12, 30, in: host)
        func matches(_ requestedDay: Int) -> Bool {
            OccurrenceDateMatch.matches(requested: Self.day(2026, 12, requestedDay, in: host), start: shown, startIsAllDay: true,
                                        zone: nil, eventIdentifier: "PLAIN-ID", externalIdentifier: nil,
                                        occurrenceDate: slot, seriesIsAllDay: true, host: host)
        }
        XCTAssertTrue(matches(28))
        XCTAssertTrue(matches(30))
        XCTAssertFalse(matches(27))
    }
}
