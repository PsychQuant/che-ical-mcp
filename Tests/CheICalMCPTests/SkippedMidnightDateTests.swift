import XCTest
import Foundation
@testable import CheICalMCP

/// #546: a date-only value on a day whose midnight the zone skips (the clock goes from 23:59:59 to
/// 01:00) names that day, from its first instant. The days are found in the zone data, not typed in:
/// the data for future years can change, past transitions do not.
final class SkippedMidnightDateTests: XCTestCase {

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The first day between 2001 and 2020 in `zone` that does not start at 00:00, as "yyyy-MM-dd",
    /// with the instant it starts at.
    static func skippedMidnight(in zone: TimeZone) -> (day: String, start: Date)? {
        let calendar = Calendar.gregorian(in: zone)
        var transition = zone.nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: 978_307_200))
        while let t = transition, t < Date(timeIntervalSince1970: 1_609_459_200) {
            let dayStart = calendar.startOfDay(for: t)
            let clock = calendar.dateComponents([.hour, .minute, .second], from: t)
            if dayStart == t, clock.hour != 0 || clock.minute != 0 || clock.second != 0 {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = zone
                f.dateFormat = "yyyy-MM-dd"
                return (f.string(from: t), t)
            }
            transition = zone.nextDaylightSavingTimeTransition(after: t)
        }
        return nil
    }

    /// Zones whose clock skipped midnight at least once between 2001 and 2020 in this host's zone data.
    private func zonesWithASkippedMidnight() throws -> [(zone: TimeZone, day: String, start: Date)] {
        let found = ["America/Havana", "America/Santiago", "America/Asuncion", "Africa/Cairo"].compactMap { id -> (TimeZone, String, Date)? in
            guard let zone = TimeZone(identifier: id), let day = Self.skippedMidnight(in: zone) else { return nil }
            return (zone, day.day, day.start)
        }
        try XCTSkipIf(found.isEmpty, "this host's zone data has no skipped midnight in the zones tried")
        return found
    }

    // spec-example: all-day-skipped-midnight / a date on the skipped-midnight day
    func testADayWhoseMidnightIsSkippedIsReadFromItsFirstInstant() throws {
        for (zone, day, start) in try zonesWithASkippedMidnight() {
            XCTAssertNil(FlexibleDate.formatter("yyyy-MM-dd", zone: zone).date(from: day), zone.identifier)
            let date = try FlexibleDate.parse(day, defaultTimezone: zone, iso: iso, allowSkippedMidnight: true)
            XCTAssertEqual(date, start, "\(zone.identifier) \(day)")
            let calendar = Calendar.gregorian(in: zone)
            let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            XCTAssertEqual(String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), day, zone.identifier)
            let before = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-1))
            XCTAssertNotEqual(before.day, parts.day, zone.identifier)
        }
    }

    func testTheDaysAroundItStillStartAtMidnight() throws {
        for (zone, _, start) in try zonesWithASkippedMidnight() {
            let calendar = Calendar.gregorian(in: zone)
            for offset in [-1, 1] {
                let other = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start)!))
                let f = FlexibleDate.formatter("yyyy-MM-dd", zone: zone)
                let date = try FlexibleDate.parse(f.string(from: other), defaultTimezone: zone, iso: iso, allowSkippedMidnight: true)
                XCTAssertEqual(calendar.component(.hour, from: date), 0, zone.identifier)
                XCTAssertEqual(date, calendar.startOfDay(for: other), zone.identifier)
            }
        }
    }

    /// #299: a date that is not a calendar date stays refused, also in a zone that skips a midnight.
    func testADateThatDoesNotExistIsStillRefusedInSuchAZone() throws {
        for (zone, _, _) in try zonesWithASkippedMidnight() {
            for text in ["2026-02-30", "2026-13-01", "2026-00-10", "2026-04-31", "2025-02-29", "2026-02-00"] {
                XCTAssertThrowsError(try FlexibleDate.parse(text, defaultTimezone: zone, iso: iso, allowSkippedMidnight: true), "\(zone.identifier) \(text)")
            }
        }
    }

    /// A day the zone skips whole (Pacific/Apia went from 2011-12-29 to 2011-12-31) has no first
    /// instant: it stays refused rather than naming the next day.
    func testADayTheZoneSkipsWholeIsRefused() throws {
        let apia = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        let transition = try XCTUnwrap(iso.date(from: "2011-12-30T10:00:00Z"))
        let calendar = Calendar.gregorian(in: apia)
        XCTAssertEqual(calendar.component(.day, from: transition.addingTimeInterval(-1)), 29)
        XCTAssertEqual(calendar.component(.day, from: transition), 31)
        XCTAssertThrowsError(try FlexibleDate.parse("2011-12-30", defaultTimezone: apia, iso: iso, allowSkippedMidnight: true))
        XCTAssertNoThrow(try FlexibleDate.parse("2011-12-31", defaultTimezone: apia, iso: iso, allowSkippedMidnight: true))
    }

    func testTheFallbackRefusesAVariableWidthSpellingOfTheGapDate() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Havana"))
        let gap = try XCTUnwrap(Self.skippedMidnight(in: zone))
        let parts = gap.day.split(separator: "-")
        let alternative = "0\(parts[0])-\(try XCTUnwrap(Int(parts[1])))-\(parts[2])"
        XCTAssertNil(FlexibleDate.firstInstant(ofDay: alternative, in: zone))
        XCTAssertThrowsError(try FlexibleDate.parse(alternative, defaultTimezone: zone, iso: iso, allowSkippedMidnight: true))
    }

    func testOrdinaryParsingStillRefusesTheGapDateWithoutOptIn() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Havana"))
        let gap = try XCTUnwrap(Self.skippedMidnight(in: zone))
        XCTAssertThrowsError(try FlexibleDate.parse(gap.day, defaultTimezone: zone, iso: iso))
    }

    /// A form the date-only formatter refuses for its shape is refused the same way on that day.
    func testAMalformedValueIsStillRefused() throws {
        for (zone, day, _) in try zonesWithASkippedMidnight() {
            let year = String(day.prefix(4))
            for text in ["\(year)-3-1200", "\(year)/03/12", "\(year)-03-1x"] {
                XCTAssertThrowsError(try FlexibleDate.parse(text, defaultTimezone: zone, iso: iso, allowSkippedMidnight: true), "\(zone.identifier) \(text)")
            }
        }
    }
}
