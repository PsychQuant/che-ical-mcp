import XCTest
import Foundation
@testable import CheICalMCP

/// #546: the dates EventKit returns for an all-day event, read back as the days they stand for.
///
/// On a day whose midnight the process zone skips (it starts at 01:00), EventKit returns the end of
/// an all-day event an hour into the next day: measured on iCloud with `TZ=America/Havana`
/// (2026-11-22), a one-day event on 2028-03-12 read `2028-03-12T05:00:00Z` to `2028-03-13T04:59:59Z`
/// (01:00 to 00:59:59 of the next day), two days from that day read to 00:59:59 of the day after
/// the second. The issue's Google calendar returned the start an hour before the day begins instead
/// (`2028-03-12T04:00:00Z` to `2028-03-13T02:59:59Z`); that shape is taken from the issue, not
/// measured here. On every other day the mapping is the identity.
final class AllDayStoredDaysTests: XCTestCase {

    private func gapDay() throws -> (zone: TimeZone, start: Date, nextStart: Date) {
        for id in ["America/Havana", "America/Santiago", "America/Asuncion", "Africa/Cairo"] {
            guard let zone = TimeZone(identifier: id), let day = SkippedMidnightDateTests.skippedMidnight(in: zone) else { continue }
            let calendar = Calendar.gregorian(in: zone)
            let next = calendar.startOfDay(for: day.start.addingTimeInterval(36 * 3600))
            return (zone, day.start, next)
        }
        throw XCTSkip("this host's zone data has no skipped midnight in the zones tried")
    }

    private func stored(_ start: Date, _ end: Date, _ zone: TimeZone) -> (start: Date, end: Date) {
        AllDayRange.storedDays(start: start, end: end, calendar: Calendar.gregorian(in: zone))
    }

    // spec-example: all-day-skipped-midnight / a one-day event on the day reads as that day
    func testTheMeasuredOneDayShapeReadsAsThatDay() throws {
        let (zone, start, next) = try gapDay()
        let read = stored(start, start.addingTimeInterval(86_399), zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, next.addingTimeInterval(-1), "23:59:59 of that day, not 00:59:59 of the next")
    }

    func testTheMeasuredTwoDayShapeReadsAsTwoDays() throws {
        let (zone, start, next) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let dayAfterNext = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: next))
        let read = stored(start, start.addingTimeInterval(2 * 86_400 - 1), zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, dayAfterNext.addingTimeInterval(-1))
    }

    /// The issue's Google reading: the start an hour before the day begins, the end an hour before it ends.
    func testTheIssuesGoogleShapeReadsAsThatDay() throws {
        let (zone, start, next) = try gapDay()
        let read = stored(start.addingTimeInterval(-3600), next.addingTimeInterval(-3601), zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, next.addingTimeInterval(-1))
    }

    /// The issue's Google shape over two days (derived: both ends an hour early, as in its one-day row):
    /// 47 hours elapsed still count two days.
    func testTheIssuesGoogleShapeOverTwoDaysReadsAsTwoDays() throws {
        let (zone, start, next) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let dayAfterNext = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: next))
        let read = stored(start.addingTimeInterval(-3600), dayAfterNext.addingTimeInterval(-3601), zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, dayAfterNext.addingTimeInterval(-1))
    }

    /// The measured range from the day before over the 23-hour day (`create_event` 03-11 to 03-13):
    /// EventKit returned it whole, and it stays as it is.
    func testARangeThatStartsTheDayBeforeIsUnchanged() throws {
        let (zone, start, next) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let dayBefore = calendar.startOfDay(for: start.addingTimeInterval(-12 * 3600))
        let read = stored(dayBefore, next.addingTimeInterval(-1), zone)
        XCTAssertEqual(read.start, dayBefore)
        XCTAssertEqual(read.end, next.addingTimeInterval(-1))
    }

    /// On a 25-hour day (the clock goes back an hour after midnight), measured in Havana on
    /// 2028-11-05: the day reads from 00:00 to 23:59:59, 25 hours, and stays as it is.
    func testALongDayIsUnchanged() throws {
        for id in ["America/Havana", "America/Santiago", "America/Asuncion"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let calendar = Calendar.gregorian(in: zone)
            var transition = zone.nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: 978_307_200))
            var checked = 0
            while let t = transition, t < Date(timeIntervalSince1970: 1_609_459_200), checked < 4 {
                if zone.secondsFromGMT(for: t) < zone.secondsFromGMT(for: t.addingTimeInterval(-1)) {
                    let dayStart = calendar.startOfDay(for: t)
                    let nextStart = calendar.startOfDay(for: t.addingTimeInterval(30 * 3600))
                    let read = stored(dayStart, nextStart.addingTimeInterval(-1), zone)
                    XCTAssertEqual(read.start, dayStart, "\(id) \(t)")
                    XCTAssertEqual(read.end, nextStart.addingTimeInterval(-1), "\(id) \(t)")
                    checked += 1
                }
                transition = zone.nextDaylightSavingTimeTransition(after: t)
            }
        }
    }

    func testOrdinaryDaysAreUnchanged() throws {
        for id in ["UTC", "Asia/Taipei", "America/Los_Angeles", "America/Havana", "Australia/Lord_Howe"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let calendar = Calendar.gregorian(in: zone)
            var noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_767_225_600)))   // 2026-01-01
            for _ in 0..<400 {
                let day = calendar.startOfDay(for: noon)
                let next = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: noon)))
                let third = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: noon)))
                for end in [next, third] {
                    let read = stored(day, end.addingTimeInterval(-1), zone)
                    XCTAssertEqual(read.start, day, "\(id) \(day)")
                    XCTAssertEqual(read.end, end.addingTimeInterval(-1), "\(id) \(day)")
                }
                noon = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: noon))
            }
        }
    }

    /// A pair the rule cannot explain (more than three hours from the days it would stand for) is
    /// returned as it is, not moved to a day boundary.
    func testAPairFarFromItsDayBoundariesIsReturnedAsItIs() throws {
        let (zone, start, _) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: start.addingTimeInterval(3 * 86_400)))
        let read = stored(morning, morning.addingTimeInterval(12 * 3600), zone)
        XCTAssertEqual(read.start, morning)
        XCTAssertEqual(read.end, morning.addingTimeInterval(12 * 3600))
    }

    /// A pair with no length (start = end at a day start) is returned as it is, not turned into a
    /// pair that ends before it starts.
    func testAPairWithNoLengthIsReturnedAsItIs() throws {
        let (zone, start, _) = try gapDay()
        let read = stored(start, start, zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, start)
    }

    // spec-example: all-day-skipped-midnight / moving that event by its start keeps one day
    func testMovingTheMeasuredOneDayEventByItsStartKeepsOneDay() throws {
        let (zone, start, _) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let later = calendar.startOfDay(for: start.addingTimeInterval(4 * 86_400))
        let plan = try AllDayRange.planUpdate(
            storedStart: start, storedEnd: start.addingTimeInterval(86_399), storedAllDay: true,
            newStart: later, newEnd: nil, requestedAllDay: nil, calendar: calendar)
        let dayAfter = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: later))
        XCTAssertEqual(plan.datesToWrite?.start, later)
        XCTAssertEqual(plan.datesToWrite?.end, dayAfter.addingTimeInterval(-1), "one day, as stored")
    }

    /// The issue's Google shape moved by its end: the first day stays the day it stands for.
    func testMovingTheGoogleShapeByItsEndKeepsItsFirstDay() throws {
        let (zone, start, next) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let dayAfterNext = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: next))
        let plan = try AllDayRange.planUpdate(
            storedStart: start.addingTimeInterval(-3600), storedEnd: next.addingTimeInterval(-3601), storedAllDay: true,
            newStart: nil, newEnd: dayAfterNext, requestedAllDay: nil, calendar: calendar)
        XCTAssertEqual(plan.datesToWrite?.start, start, "the day it stands for, not the evening before")
        XCTAssertEqual(plan.datesToWrite?.end, dayAfterNext.addingTimeInterval(-1))
    }

    // spec-example: all-day-skipped-midnight / list_events gives that day
    func testTheEventDictGivesThatDay() async throws {
        let (zone, start, next) = try gapDay()
        let server = try await CheICalMCPServer()
        let event = FakeFormattableEvent(formatStartDate: start, formatEndDate: start.addingTimeInterval(86_399),
                                         formatSourceTimeZone: nil, formatIsAllDay: true)
        let dict = server.formatEventDict(event, displayTimezone: zone, allDayZone: zone)
        let day = FlexibleDate.formatter("yyyy-MM-dd", zone: TimeZone(identifier: "UTC")!)
            .string(from: start.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: start))))
        XCTAssertEqual(dict["start_date_local"] as? String, "\(day)T01:00:00")
        XCTAssertEqual(dict["end_date_local"] as? String, "\(day)T23:59:59")
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(dict["end_date"] as? String, iso.string(from: next.addingTimeInterval(-1)))
    }

    /// A timed event's dates are printed as EventKit returns them.
    func testATimedEventDictIsUnchanged() async throws {
        let (zone, start, _) = try gapDay()
        let server = try await CheICalMCPServer()
        let event = FakeFormattableEvent(formatStartDate: start, formatEndDate: start.addingTimeInterval(86_399),
                                         formatSourceTimeZone: zone, formatIsAllDay: false)
        let dict = server.formatEventDict(event, displayTimezone: zone, allDayZone: zone)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(dict["end_date"] as? String, iso.string(from: start.addingTimeInterval(86_399)))
    }
}
