import XCTest
@testable import CheICalMCP

/// #270 round 4: the day `findOccurrence` searches. A mutation that ignored the zone inside
/// `findOccurrence` kept every test green; the window is now a pure function tested with a zone
/// that differs from the host's, and `findOccurrence` is pinned to call it.
final class OccurrenceDayTests: XCTestCase {
    private let day = "2026-12-06"

    func testTheWindowIsTheDayInTheGivenZone() throws {
        let zone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let start = TestZones.midnight(day, in: zone)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: start.addingTimeInterval(13 * 3600), in: zone))
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end, TestZones.midnight("2026-12-07", in: zone))
    }

    /// The same instant in the host zone is another window: the zone is not ignored.
    func testTheZoneChangesTheWindow() throws {
        let zone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let instant = TestZones.midnight(day, in: zone)
        let inZone = try XCTUnwrap(OccurrenceDay.window(containing: instant, in: zone))
        let inHost = try XCTUnwrap(OccurrenceDay.window(containing: instant, in: nil))
        XCTAssertNotEqual(inZone.start, inHost.start)
        XCTAssertEqual(inHost.start, Calendar.current.startOfDay(for: instant), "nil is the host zone")
    }

    func testFindOccurrenceSearchesTheWindow() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        let body = try XCTUnwrap(SourceScan.body(of: "func findOccurrence(identifier: String, on date: Date, in timeZone: TimeZone? = nil, slot: Date? = nil) -> EKEvent? {", in: code))
        // PR #394 verify round 1: the predicate covers the candidate window (search day and host day).
        XCTAssertEqual(SourcePins.ranges(of: "guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone) else { return nil } let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)", in: body).count, 1)
        XCTAssertFalse(body.contains("startOfDay"), "the window is computed in one place")
        // Final review: a line inserted above the pinned text (shadowing `date` or `timeZone`)
        // survived a substring pin. The body must open with the window and never rebind either.
        let trimmed = body.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "{" || $0 == " " })
        XCTAssertTrue(trimmed.hasPrefix("guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone)"), String(trimmed.prefix(160)))
        for rebinding in ["let date", "var date", "let timeZone", "var timeZone", "date =", "timeZone ="] {
            XCTAssertFalse(body.contains(rebinding), "findOccurrence rebinds an input: \(rebinding)")
        }
    }

    /// Final review: the input the real chain sends is a date-only value parsed to exactly midnight
    /// in the event's zone. `startOfDay(for: date - 1s)` searched the day before and stayed green.
    func testMidnightInTheZoneIsTheStartOfItsOwnDay() throws {
        let zone = TestZones.eventZone(differingFromHostAt: TestZones.noonUTC(day))
        let midnight = TestZones.midnight(day, in: zone)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: midnight, in: zone))
        XCTAssertEqual(window.start, midnight)
        let before = try XCTUnwrap(OccurrenceDay.window(containing: midnight.addingTimeInterval(-1), in: zone))
        XCTAssertEqual(before.end, midnight, "the instant before midnight belongs to the previous day")
    }

    /// Final review: `end = start + 86 400` survived; a 25-hour DST day must end at the next midnight.
    func testA25HourDayEndsAtTheNextMidnight() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = TestZones.midnight("2026-11-01", in: ny)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: start.addingTimeInterval(3600), in: ny))
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 25 * 3600)
    }
}

/// #391: `findOccurrence` took the first occurrence of the series the day's predicate enumerated,
/// and EventKit's predicate also returns an occurrence that only touches the window at its end
/// (device, 2026-11-04: a daily 23:30-00:00 New York series, `occurrence_date` 2026-12-06,
/// updated the Dec 5 occurrence). An occurrence belongs to the day its start falls in.
final class OccurrenceDayStartRuleTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// The device case: Dec 5 23:30 New York ends at Dec 6 00:00, the window's start.
    func testAnOccurrenceEndingAtTheDayStartIsNotOnThatDay() {
        let requested = TestZones.midnight("2026-12-06", in: newYork)
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(
            occurrenceStart: at("2026-12-06T04:30:00Z"), isAllDay: false, requested: requested, in: newYork),
            "Dec 5 23:30 New York is the previous day's occurrence")
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(
            occurrenceStart: at("2026-12-07T04:30:00Z"), isAllDay: false, requested: requested, in: newYork),
            "Dec 6 23:30 New York is the requested one")
    }

    /// An overnight occurrence (22:00 to 02:00) overlaps the next day too; it is on the day it starts.
    func testAnOvernightOccurrenceIsOnTheDayItStarts() {
        let requested = TestZones.midnight("2026-12-06", in: newYork)
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(
            occurrenceStart: at("2026-12-06T03:00:00Z"), isAllDay: false, requested: requested, in: newYork))
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(
            occurrenceStart: at("2026-12-07T03:00:00Z"), isAllDay: false, requested: requested, in: newYork))
    }

    /// The window is half-open: a start at the day's first instant is on it, one at the next midnight is not.
    func testTheDayIsHalfOpen() throws {
        let requested = TestZones.midnight("2026-12-06", in: newYork)
        let window = try XCTUnwrap(OccurrenceDay.window(containing: requested, in: newYork))
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(occurrenceStart: window.start, isAllDay: false, requested: requested, in: newYork))
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(occurrenceStart: window.end.addingTimeInterval(-1), isAllDay: false, requested: requested, in: newYork))
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(occurrenceStart: window.end, isAllDay: false, requested: requested, in: newYork))
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(occurrenceStart: window.start.addingTimeInterval(-1), isAllDay: false, requested: requested, in: newYork))
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(occurrenceStart: nil, isAllDay: false, requested: requested, in: newYork))
    }

    /// An explicit instant (not midnight) asks for the day it falls in, in the search zone.
    func testAnInstantAsksForItsDayInTheZone() {
        let requested = at("2026-12-06T15:00:00Z")   // Dec 6 10:00 New York
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(
            occurrenceStart: at("2026-12-07T04:30:00Z"), isAllDay: false, requested: requested, in: newYork))
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(
            occurrenceStart: at("2026-12-06T04:30:00Z"), isAllDay: false, requested: requested, in: newYork))
    }

    /// An all-day occurrence is a floating day stored from this Mac's midnight (#364), so it is
    /// compared by its day in the host zone with the requested day in the search zone, whichever
    /// side of the host that zone is. By start instant alone, a zone behind the host would pick the
    /// next day's all-day occurrence (Dec 7 00:00 +08:00 is Dec 6 in New York).
    func testAnAllDayOccurrenceIsComparedByItsDay() {
        let host = TimeZone.current
        let zones = ["America/New_York", "Asia/Tokyo", "Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC"]
            .compactMap(TimeZone.init(identifier:)) + [host]
        for zone in zones.map(Optional.some) + [nil] {   // nil: the host zone (an all-day series has none)
            let requested = TestZones.midnight("2026-12-06", in: zone ?? host)
            for (day, expected) in [("2026-12-05", false), ("2026-12-06", true), ("2026-12-07", false)] {
                let allDayStart = TestZones.midnight(day, in: host)
                XCTAssertEqual(OccurrenceDay.startsOnRequestedDay(
                    occurrenceStart: allDayStart, isAllDay: true, requested: requested, in: zone), expected,
                    "all-day \(day) asked as 2026-12-06 in \(zone?.identifier ?? "nil")")
            }
        }
    }

    /// `findOccurrence` matches through this rule, with the enumerated event's own start and
    /// all-day flag and the requested date and zone it was called with.
    func testFindOccurrenceMatchesByTheStartRule() throws {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        let body = try XCTUnwrap(SourceScan.body(of: "func findOccurrence(identifier: String, on date: Date, in timeZone: TimeZone? = nil, slot: Date? = nil) -> EKEvent? {", in: code))
        XCTAssertEqual(SourcePins.ranges(of: "OccurrenceDay.startsOnRequestedDay(occurrenceStart: event.startDate, isAllDay: event.isAllDay, requested: date, in: timeZone)", in: body).count, 1)
        let rule = try XCTUnwrap(body.range(of: "OccurrenceDay.startsOnRequestedDay("))
        let pick = try XCTUnwrap(body.range(of: "target = event"))
        XCTAssertLessThan(rule.lowerBound, pick.lowerBound, "the rule gates the pick")
    }
}

/// PR #394 verify round 1: the enumeration window and the all-day exact-start case.
final class OccurrenceDayCandidateWindowTests: XCTestCase {
    private let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!   // +14
    private let pagoPago = TimeZone(identifier: "Pacific/Pago_Pago")!      // -11
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    /// Finding 1 (codex): host and search zone 25 hours apart. The host's all-day Dec 6
    /// [Dec 5 10:00Z, Dec 6 10:00Z) does not overlap the search zone's Dec 6
    /// [Dec 6 11:00Z, Dec 7 11:00Z), so a predicate over the search window never enumerated it.
    /// The candidate window covers both days, and the rule accepts that occurrence.
    func testTheCandidateWindowReachesTheHostDayOfAnAllDayOccurrence() throws {
        let requested = TestZones.midnight("2026-12-06", in: pagoPago)
        let allDayStart = TestZones.midnight("2026-12-06", in: kiritimati)
        let allDayEnd = TestZones.midnight("2026-12-07", in: kiritimati)
        let search = try XCTUnwrap(OccurrenceDay.window(containing: requested, in: pagoPago))
        XCTAssertFalse(allDayStart < search.end && allDayEnd > search.start, "the premise: no overlap with the search window")
        let candidate = try XCTUnwrap(OccurrenceDay.candidateWindow(containing: requested, in: pagoPago, host: kiritimati))
        XCTAssertTrue(allDayStart < candidate.end && allDayEnd > candidate.start, "the candidate window reaches it")
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(occurrenceStart: allDayStart, isAllDay: true, requested: requested,
                                                         in: pagoPago, host: kiritimati))
        // The reverse pair too (host behind the search zone).
        let reverse = try XCTUnwrap(OccurrenceDay.candidateWindow(containing: TestZones.midnight("2026-12-06", in: kiritimati),
                                                                  in: kiritimati, host: pagoPago))
        XCTAssertTrue(TestZones.midnight("2026-12-06", in: pagoPago) < reverse.end
                      && TestZones.midnight("2026-12-07", in: pagoPago) > reverse.start)
    }

    /// The candidate window always contains the search window (every timed occurrence the rule
    /// accepts is enumerated), and is the search window when the zones agree.
    func testTheCandidateWindowContainsTheSearchWindow() throws {
        for (zone, host) in [(newYork, taipei), (taipei, newYork), (kiritimati, pagoPago), (pagoPago, kiritimati), (taipei, taipei)] {
            let requested = TestZones.midnight("2026-12-06", in: zone).addingTimeInterval(5 * 3600)
            let search = try XCTUnwrap(OccurrenceDay.window(containing: requested, in: zone))
            let candidate = try XCTUnwrap(OccurrenceDay.candidateWindow(containing: requested, in: zone, host: host))
            XCTAssertLessThanOrEqual(candidate.start, search.start)
            XCTAssertGreaterThanOrEqual(candidate.end, search.end)
            let hostDay = (TestZones.midnight("2026-12-06", in: host), TestZones.midnight("2026-12-07", in: host))
            XCTAssertLessThanOrEqual(candidate.start, hostDay.0, "\(zone.identifier) / \(host.identifier)")
            XCTAssertGreaterThanOrEqual(candidate.end, hostDay.1, "\(zone.identifier) / \(host.identifier)")
            if zone == host { XCTAssertEqual(candidate.start, search.start); XCTAssertEqual(candidate.end, search.end) }
        }
        let nilZone = try XCTUnwrap(OccurrenceDay.candidateWindow(containing: TestZones.midnight("2026-12-06", in: taipei), in: nil, host: taipei))
        XCTAssertEqual(nilZone.start, TestZones.midnight("2026-12-06", in: taipei))
        XCTAssertEqual(nilZone.end, TestZones.midnight("2026-12-07", in: taipei))
    }

    /// Finding 3: `delete_events_batch` passes an item's own start with the series zone. An all-day
    /// exception of a timed New York series starts at host midnight (Taipei), whose New York day is
    /// the day before; the exact start still matches it.
    func testAnAllDayOccurrenceMatchesItsExactStart() {
        let start = TestZones.midnight("2026-12-06", in: taipei)
        XCTAssertTrue(OccurrenceDay.startsOnRequestedDay(occurrenceStart: start, isAllDay: true, requested: start,
                                                         in: newYork, host: taipei))
        XCTAssertFalse(OccurrenceDay.startsOnRequestedDay(occurrenceStart: start, isAllDay: true,
                                                          requested: start.addingTimeInterval(-86_400), in: newYork, host: taipei),
                       "another instant still goes by the day: Dec 5 00:00 Taipei is Dec 4 in New York")
    }
}
