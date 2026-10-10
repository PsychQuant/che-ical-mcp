import XCTest
@testable import CheICalMCP

/// #297: one place decides whether a reminder's due is overdue and where it sorts. A timed due is
/// an instant; a date-only due is a day, overdue only once that day has ended in the host zone.
final class ReminderDueReadingTests: XCTestCase {
    static let taipei = TimeZone(identifier: "Asia/Taipei")!
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// A date-only due on 2026-10-09, judged at local times around that day. The same table drives
    /// `filter="overdue"` in `ReminderPageTests`, so the two cannot disagree.
    struct OverdueCase {
        let label: String
        let now: (Int, Int, Int, Int, Int)
        let overdue: Bool
    }

    static let dateOnlyDue = DateComponents(year: 2026, month: 10, day: 9)
    static let overdueCases: [OverdueCase] = [
        OverdueCase(label: "the day before, 23:59", now: (2026, 10, 8, 23, 59), overdue: false),
        OverdueCase(label: "its day, 00:00", now: (2026, 10, 9, 0, 0), overdue: false),
        OverdueCase(label: "its day, 12:00", now: (2026, 10, 9, 12, 0), overdue: false),
        OverdueCase(label: "its day, 23:59", now: (2026, 10, 9, 23, 59), overdue: false),
        OverdueCase(label: "the next day, 00:00", now: (2026, 10, 10, 0, 0), overdue: true),
        OverdueCase(label: "a week later", now: (2026, 10, 16, 9, 0), overdue: true),
    ]

    static func now(of c: OverdueCase, in zone: TimeZone) -> Date {
        local(c.now.0, c.now.1, c.now.2, c.now.3, c.now.4, in: zone)
    }

    func testADateOnlyDueIsOverdueOnlyAfterItsDayEnds() {
        for zone in [Self.taipei, Self.losAngeles] {
            for c in Self.overdueCases {
                XCTAssertEqual(ReminderDueReading.isOverdue(Self.dateOnlyDue, now: Self.now(of: c, in: zone), zone: zone),
                               c.overdue, "\(c.label) in \(zone.identifier)")
            }
        }
    }

    // The day is read in the host zone, not in a zone the stored components carry.
    func testAZoneOnADateOnlyDueIsIgnored() {
        var due = Self.dateOnlyDue
        due.timeZone = Self.losAngeles
        let now = Self.local(2026, 10, 10, 1, in: Self.taipei)   // still 2026-10-09 in Los Angeles
        XCTAssertEqual(ReminderDueReading.isOverdue(due, now: now, zone: Self.taipei), true)
    }

    /// PR #307 verify round 1 (Codex, MEDIUM): the `due_date` strings read a date-only due at the
    /// same instant `is_overdue` and the sort use, 00:00 of the day in the host zone, so a zone the
    /// components carry does not move the printed time either.
    func testADateOnlyDueDisplaysAtHostMidnightWhateverZoneItCarries() {
        var due = Self.dateOnlyDue
        due.timeZone = Self.losAngeles
        XCTAssertEqual(ReminderDueReading.displayInstant(due, zone: Self.taipei),
                       Self.local(2026, 10, 9, 0, in: Self.taipei))
        XCTAssertEqual(ReminderDueReading.displayInstant(Self.dateOnlyDue, zone: Self.taipei),
                       Self.local(2026, 10, 9, 0, in: Self.taipei))
    }

    /// PR #307 verify round 2 (Codex): a day the host zone skipped (Pacific/Apia has no
    /// 2011-12-30) has no midnight of its own. Foundation gives the next instant that exists,
    /// 2011-12-31 00:00, so `due_date_local` prints 12-31 while `due.date` says 12-30. The day has
    /// no length there: it is overdue from that same instant, and it sorts at that instant, before
    /// a timed due later on 12-31. Pinned so the three readings stay one instant.
    func testADaySkippedByTheHostZoneIsOneInstantForDisplaySortAndOverdue() throws {
        let apia = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        let skipped = DateComponents(year: 2011, month: 12, day: 30)
        let shown = try XCTUnwrap(ReminderDueReading.displayInstant(skipped, zone: apia))
        XCTAssertEqual(shown, Self.local(2011, 12, 31, 0, in: apia))
        XCTAssertEqual(ReminderDueReading.isOverdue(skipped, now: shown.addingTimeInterval(-1), zone: apia), false)
        XCTAssertEqual(ReminderDueReading.isOverdue(skipped, now: shown, zone: apia), true)
        let laterThatDay = DateComponents(timeZone: apia, year: 2011, month: 12, day: 31, hour: 8)
        XCTAssertTrue(ReminderDueReading.sortsBefore(skipped, laterThatDay, zone: apia))
    }

    func testATimedDueDisplaysAtItsInstant() {
        let due = DateComponents(timeZone: Self.losAngeles, year: 2026, month: 10, day: 9, hour: 9, minute: 30)
        XCTAssertEqual(ReminderDueReading.displayInstant(due, zone: Self.taipei),
                       Self.local(2026, 10, 9, 9, 30, in: Self.losAngeles))
        XCTAssertNil(ReminderDueReading.displayInstant(nil, zone: Self.taipei))
    }

    func testATimedDueIsOverdueFromItsInstant() {
        let due = DateComponents(timeZone: Self.taipei, year: 2026, month: 10, day: 9, hour: 9, minute: 30)
        let instant = Self.local(2026, 10, 9, 9, 30, in: Self.taipei)
        for zone in [Self.taipei, Self.losAngeles] {
            XCTAssertEqual(ReminderDueReading.isOverdue(due, now: instant.addingTimeInterval(-1), zone: zone), false)
            XCTAssertEqual(ReminderDueReading.isOverdue(due, now: instant, zone: zone), false)
            XCTAssertEqual(ReminderDueReading.isOverdue(due, now: instant.addingTimeInterval(1), zone: zone), true)
        }
    }

    func testNoDueIsNeitherOverdueNorNot() {
        XCTAssertNil(ReminderDueReading.isOverdue(nil, now: Date(), zone: Self.taipei))
    }

    // MARK: - Sort position

    private func timed(_ d: Int, _ h: Int, _ min: Int = 0, in zone: TimeZone = taipei) -> DateComponents {
        DateComponents(timeZone: zone, year: 2026, month: 10, day: d, hour: h, minute: min)
    }

    func testADateOnlyDueSortsAtTheHeadOfItsDay() {
        let zone = Self.taipei
        let day = Self.dateOnlyDue
        XCTAssertTrue(ReminderDueReading.sortsBefore(day, timed(9, 9), zone: zone))
        XCTAssertFalse(ReminderDueReading.sortsBefore(timed(9, 9), day, zone: zone))
        XCTAssertTrue(ReminderDueReading.sortsBefore(timed(8, 23, 59), day, zone: zone))
        XCTAssertFalse(ReminderDueReading.sortsBefore(day, timed(8, 23, 59), zone: zone))
    }

    // A timed due at 00:00 is the same instant; the date-only one goes first, whichever side it is on.
    func testADateOnlyDueSortsBeforeATimedDueAtMidnight() {
        let zone = Self.taipei
        XCTAssertTrue(ReminderDueReading.sortsBefore(Self.dateOnlyDue, timed(9, 0), zone: zone))
        XCTAssertFalse(ReminderDueReading.sortsBefore(timed(9, 0), Self.dateOnlyDue, zone: zone))
    }

    func testADueSortsBeforeNoDue() {
        XCTAssertTrue(ReminderDueReading.sortsBefore(Self.dateOnlyDue, nil, zone: Self.taipei))
        XCTAssertFalse(ReminderDueReading.sortsBefore(nil, Self.dateOnlyDue, zone: Self.taipei))
        XCTAssertFalse(ReminderDueReading.sortsBefore(nil, nil, zone: Self.taipei))
    }
}
