import Foundation
import XCTest
@testable import CheICalMCP

/// #270 / #271 verify (MEDIUM 1): `delete_event` reads a date-only `occurrence_date` in the
/// event's own zone. `OccurrenceDateInput.resolve` is that step on values: the zone is asked for
/// only when the span uses the date and the string has no explicit offset, and the date is read
/// in the zone it returns. A mutation that read it in the host zone again passed every test
/// before this file; round 2: so did dropping the lookup's result or flipping the span test in
/// the handler, so the span decision is made here too, and the handler only passes its span.
final class OccurrenceDateInputTests: XCTestCase {
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let newYork = TimeZone(identifier: "America/New_York")!

    /// Host Asia/Taipei, event America/New_York: "2026-12-06" is midnight of Dec 6 in New York,
    /// which in Taipei is already 13:00 that day; read in the host zone it would be Dec 5 11:00
    /// in New York, the neighbouring day the delete then searched.
    func testADateOnlyValueIsReadInTheEventsZone() async throws {
        let date = try await OccurrenceDateInput.resolve("2026-12-06", iso: iso, span: "this") { self.newYork }
        XCTAssertEqual(date, iso.date(from: "2026-12-06T00:00:00-05:00"))
        let taipeiMidnight = try FlexibleDate.parse("2026-12-06", defaultTimezone: TimeZone(identifier: "Asia/Taipei"), iso: iso)
        XCTAssertNotEqual(date, taipeiMidnight)
    }

    func testADateTimeWithoutOffsetIsReadInTheEventsZone() async throws {
        let date = try await OccurrenceDateInput.resolve("2026-12-06T09:30:00", iso: iso, span: "this") { self.newYork }
        XCTAssertEqual(date, iso.date(from: "2026-12-06T09:30:00-05:00"))
    }

    /// No occurrence_date, or one with an explicit offset: the zone is not looked up, so no
    /// access check, refresh or stand-in scan runs for it (verify LOW).
    func testTheZoneIsNotLookedUpWhenItIsNotNeeded() async throws {
        var lookups = 0
        let none = try await OccurrenceDateInput.resolve(nil, iso: iso, span: "this") { lookups += 1; return self.newYork }
        XCTAssertNil(none)
        let explicit = try await OccurrenceDateInput.resolve("2026-12-06T00:00:00+08:00", iso: iso, span: "this") { lookups += 1; return self.newYork }
        XCTAssertEqual(explicit, iso.date(from: "2026-12-06T00:00:00+08:00"))
        XCTAssertEqual(lookups, 0)
        _ = try await OccurrenceDateInput.resolve("2026-12-06", iso: iso, span: "this") { lookups += 1; return self.newYork }
        XCTAssertEqual(lookups, 1)
    }

    /// Round 2: spans `this` and `future` use the date, so the lookup is called and its zone used.
    func testSpansThatUseTheDateLookTheZoneUpAndUseIt() async throws {
        for span in ["this", "future"] {
            var lookups = 0
            let date = try await OccurrenceDateInput.resolve("2026-12-06", iso: iso, span: span) { lookups += 1; return self.newYork }
            XCTAssertEqual(lookups, 1, span)
            XCTAssertEqual(date, iso.date(from: "2026-12-06T00:00:00-05:00"), span)
        }
    }

    /// Round 2: span `all` ignores the date, so the zone is not looked up; the value is still
    /// checked as a date (an invalid one is refused, as before).
    func testSpanAllDoesNotLookTheZoneUpButStillChecksTheDate() async throws {
        var lookups = 0
        let date = try await OccurrenceDateInput.resolve("2026-12-06", iso: iso, span: "all") { lookups += 1; return self.newYork }
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(date, try FlexibleDate.parse("2026-12-06", iso: iso))
        do {
            _ = try await OccurrenceDateInput.resolve("not-a-date", iso: iso, span: "all") { lookups += 1; return self.newYork }
            XCTFail("an invalid date is refused with span all too")
        } catch {}
        XCTAssertEqual(lookups, 0)
    }

    /// When the lookup fails (calendar access), its error is returned before anything is parsed,
    /// so the date is never read in the host zone instead (verify LOW).
    func testALookupErrorIsReturnedInsteadOfAHostZoneDate() async {
        struct Denied: Error {}
        do {
            _ = try await OccurrenceDateInput.resolve("2026-12-06", iso: iso, span: "this") { throw Denied() }
            XCTFail("the lookup error must surface")
        } catch {
            XCTAssertTrue(error is Denied)
        }
    }

    /// No zone (event not found, or no zone set) keeps today's reading in the host zone; the
    /// write then reports not found.
    func testNoZoneFallsBackToTheHostZone() async throws {
        let date = try await OccurrenceDateInput.resolve("2026-12-06", iso: iso, span: "this") { nil }
        XCTAssertEqual(date, try FlexibleDate.parse("2026-12-06", iso: iso))
    }
}
