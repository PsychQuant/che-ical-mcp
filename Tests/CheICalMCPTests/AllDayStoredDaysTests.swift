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
        return try XCTUnwrap(nil, "this host's zone data has no skipped midnight in the zones tried")
    }

    private func stored(_ start: Date, _ end: Date, _ zone: TimeZone) -> (start: Date, end: Date) {
        AllDayRange.storedDays(start: start, end: end, calendar: Calendar.gregorian(in: zone))
    }

    func testCopyRefusesAPairThatWouldWidenTheEvent() throws {
        let (zone, start, next) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let rawEnd = start.addingTimeInterval(86_399)
        for (rawStart, rawEnd) in [
            (start, rawEnd),
            (start.addingTimeInterval(-3600), next.addingTimeInterval(-3601))
        ] {
            XCTAssertThrowsError(try AllDayRange.validateCopy(start: rawStart, end: rawEnd, isAllDay: true,
                                                              eventZone: nil, calendar: calendar)) { error in
                XCTAssertTrue(error.localizedDescription.contains("#568"))
                XCTAssertTrue(error.localizedDescription.contains("widen"))
            }
        }
        XCTAssertThrowsError(try AllDayRange.validateCopy(start: start, end: rawEnd, isAllDay: true,
                                                          eventZone: zone, calendar: calendar))
        let bogota = try XCTUnwrap(TimeZone(identifier: "America/Bogota"))
        XCTAssertNoThrow(try AllDayRange.validateCopy(start: start, end: rawEnd, isAllDay: true,
                                                      eventZone: bogota, calendar: calendar))
        XCTAssertNoThrow(try AllDayRange.validateCopy(start: start, end: rawEnd, isAllDay: false,
                                                      eventZone: nil, calendar: calendar))
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
        var total = 0
        for id in ["America/Havana", "America/Santiago", "America/Asuncion"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let calendar = Calendar.gregorian(in: zone)
            var transition = zone.nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: 978_307_200))
            var checked = 0
            while let t = transition, t < Date(timeIntervalSince1970: 1_609_459_200), checked < 4 {
                if zone.secondsFromGMT(for: t.addingTimeInterval(-1)) - zone.secondsFromGMT(for: t) == 3600 {
                    let dayStart = calendar.startOfDay(for: t)
                    let nextStart = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart)))
                    XCTAssertEqual(nextStart.timeIntervalSince(dayStart), 25 * 3600, "\(id) \(t)")
                    let read = stored(dayStart, nextStart.addingTimeInterval(-1), zone)
                    XCTAssertEqual(read.start, dayStart, "\(id) \(t)")
                    XCTAssertEqual(read.end, nextStart.addingTimeInterval(-1), "\(id) \(t)")
                    checked += 1
                    total += 1
                }
                transition = zone.nextDaylightSavingTimeTransition(after: t)
            }
        }
        XCTAssertGreaterThan(total, 0)
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
        // 14:00 the day before is ten elapsed hours before the gap day starts.
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 14, minute: 0, second: 0, of: start.addingTimeInterval(-12 * 3600)))
        let read = stored(afternoon, afternoon.addingTimeInterval(12 * 3600), zone)
        XCTAssertEqual(read.start, afternoon)
        XCTAssertEqual(read.end, afternoon.addingTimeInterval(12 * 3600))
    }

    /// A pair with no length (start = end at a day start) is returned as it is, not turned into a
    /// pair that ends before it starts.
    func testAPairWithNoLengthIsReturnedAsItIs() throws {
        let (zone, start, _) = try gapDay()
        let read = stored(start, start, zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, start)
    }

    /// On a day that starts at midnight, a pair that does not end at 23:59:59 (an exact next
    /// midnight, or an hour short) is also returned as it is: only a day that starts at another time
    /// is read anew.
    func testAnOrdinaryDayPairWithAnotherEndIsReturnedAsItIs() throws {
        for id in ["UTC", "Asia/Taipei", "America/Havana"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let calendar = Calendar.gregorian(in: zone)
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
            let next = calendar.startOfDay(for: day.addingTimeInterval(36 * 3600))
            for end in [next, next.addingTimeInterval(-3600), next.addingTimeInterval(-7200)] {
                let read = stored(day, end, zone)
                XCTAssertEqual(read.start, day, id)
                XCTAssertEqual(read.end, end, "\(id) \(end)")
            }
        }
    }

    func testAGapMorningPairStartingAfterTheFirstInstantKeepsTheRawPair() throws {
        let (zone, start, _) = try gapDay()
        let rawStart = start.addingTimeInterval(3600)
        let rawEnd = rawStart.addingTimeInterval(86_399)
        let read = stored(rawStart, rawEnd, zone)
        XCTAssertEqual(read.start, rawStart)
        XCTAssertEqual(read.end, rawEnd)
    }

    func testATimedUpdateCannotUseAnAllDayEndpointFallback() throws {
        let (zone, start, _) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        XCTAssertThrowsError(try AllDayRange.planUpdate(
            storedStart: start, storedEnd: start.addingTimeInterval(3600), storedAllDay: false,
            newStart: start, newEnd: nil, requestedAllDay: nil, calendar: calendar,
            skippedMidnightEndpoint: "2001-04-01"))
        let allDay = try AllDayRange.planUpdate(
            storedStart: start, storedEnd: start.addingTimeInterval(3600), storedAllDay: true,
            newStart: start, newEnd: nil, requestedAllDay: nil, calendar: calendar,
            skippedMidnightEndpoint: "2001-04-01")
        XCTAssertTrue(allDay.isAllDay)
    }

    func testTheThreeHourMidnightGapIsCorrectedAtTheUpperLimit() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Antarctica/Casey"))
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2016-10-21T16:00:00Z"))
        let end = try XCTUnwrap(iso.date(from: "2016-10-22T12:59:59Z"))
        let calendar = Calendar.gregorian(in: zone)
        XCTAssertEqual(calendar.startOfDay(for: start), start)
        XCTAssertEqual(calendar.component(.hour, from: start), 3)
        let read = stored(start, start.addingTimeInterval(86_399), zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, end)
    }

    func testAMidnightGapOfFifteenMinutesUsesTheFirstInstant() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "1985-12-31T18:30:00Z"))
        let end = try XCTUnwrap(iso.date(from: "1986-01-01T18:14:59Z"))
        let calendar = Calendar.gregorian(in: zone)
        XCTAssertEqual(calendar.startOfDay(for: start), start)
        XCTAssertEqual(calendar.component(.minute, from: start), 15)
        let read = stored(start, start.addingTimeInterval(86_399), zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, end)
    }

    func testAnOrdinaryEveningPairThatMatchesTheGoogleTimesIsReturnedUnchanged() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2028-03-11T23:00:00Z"))
        let end = try XCTUnwrap(iso.date(from: "2028-03-12T22:59:59Z"))
        let read = stored(start, end, utc)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, end)
    }

    func testAMidnightGapOverThreeHoursKeepsTheRawPair() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Antarctica/Casey"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "1969-01-01T00:00:00Z"))
        let calendar = Calendar.gregorian(in: zone)
        XCTAssertEqual(calendar.startOfDay(for: start), start)
        XCTAssertEqual(calendar.component(.hour, from: start), 8)
        let end = start.addingTimeInterval(86_399)
        let read = stored(start, end, zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, end)
    }

    func testASecondsOnlyMidnightGapKeepsTheRawPair() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Whitehorse"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "1900-08-20T09:00:12Z"))
        let calendar = Calendar.gregorian(in: zone)
        XCTAssertEqual(calendar.startOfDay(for: start), start)
        XCTAssertEqual(calendar.component(.second, from: start), 12)
        let end = start.addingTimeInterval(86_399)
        let read = stored(start, end, zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, end)
    }

    func testAnEveningPairNearAGapIsReturnedUnchanged() throws {
        let (zone, start, next) = try gapDay()
        let rawStart = start.addingTimeInterval(-7200)
        for rawEnd in [next.addingTimeInterval(-7200), next.addingTimeInterval(-3601)] {
            let read = stored(rawStart, rawEnd, zone)
            XCTAssertEqual(read.start, rawStart)
            XCTAssertEqual(read.end, rawEnd)
        }
    }

    func testAFirstInstantWithAnUnrecognizedEndIsReturnedUnchanged() throws {
        let (zone, start, next) = try gapDay()
        let rawEnd = next.addingTimeInterval(-3600)
        let read = stored(start, rawEnd, zone)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, rawEnd)
    }

    func testAGoogleStartWithAnUnrecognizedEndIsReturnedUnchanged() throws {
        let (zone, start, next) = try gapDay()
        let rawStart = start.addingTimeInterval(-3600)
        let rawEnd = next.addingTimeInterval(-5401)
        let read = stored(rawStart, rawEnd, zone)
        XCTAssertEqual(read.start, rawStart)
        XCTAssertEqual(read.end, rawEnd)
    }

    func testAnAllDayToTimedFlipKeepsTheStoredEndpoints() throws {
        let (zone, start, _) = try gapDay()
        let end = start.addingTimeInterval(86_399)
        let plan = try AllDayRange.planUpdate(
            storedStart: start, storedEnd: end, storedAllDay: true,
            newStart: nil, newEnd: nil, requestedAllDay: false, calendar: Calendar.gregorian(in: zone))
        XCTAssertFalse(plan.isAllDay)
        XCTAssertEqual(plan.start, start)
        XCTAssertEqual(plan.end, end)
        XCTAssertNil(plan.datesToWrite)
    }

    func testMovingATimedEventOnTheGapDayKeepsItsElapsedDuration() throws {
        let (zone, start, _) = try gapDay()
        let moved = start.addingTimeInterval(4 * 86_400)
        let plan = try AllDayRange.planUpdate(
            storedStart: start, storedEnd: start.addingTimeInterval(86_399), storedAllDay: false,
            newStart: moved, newEnd: nil, requestedAllDay: nil, calendar: Calendar.gregorian(in: zone))
        XCTAssertEqual(plan.datesToWrite?.end, moved.addingTimeInterval(86_399))
    }

    func testTurningATimedPairIntoAllDayCountsTheRawDays() throws {
        let (zone, start, _) = try gapDay()
        let calendar = Calendar.gregorian(in: zone)
        let moved = calendar.startOfDay(for: start.addingTimeInterval(4 * 86_400))
        let plan = try AllDayRange.planUpdate(
            storedStart: start, storedEnd: start.addingTimeInterval(86_399), storedAllDay: false,
            newStart: moved, newEnd: nil, requestedAllDay: true, calendar: calendar)
        XCTAssertEqual(plan.datesToWrite?.end, moved.addingTimeInterval(2 * 86_400 - 1))
    }

    func testTheGoogleEventDictUsesTheAllDayZoneBeforeRenderingInAnotherZone() async throws {
        let (zone, start, next) = try gapDay()
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let server = try await CheICalMCPServer()
        let event = FakeFormattableEvent(formatStartDate: start.addingTimeInterval(-3600),
                                         formatEndDate: next.addingTimeInterval(-3601),
                                         formatSourceTimeZone: nil, formatIsAllDay: true)
        let dict = server.formatEventDict(event, displayTimezone: utc, allDayZone: zone)
        let iso = ISO8601DateFormatter()
        let expectedStart = iso.string(from: start)
        let expectedEnd = iso.string(from: next.addingTimeInterval(-1))
        XCTAssertEqual(dict["start_date"] as? String, expectedStart)
        XCTAssertEqual(dict["end_date"] as? String, expectedEnd)
        XCTAssertEqual(dict["start_date_local"] as? String, String(expectedStart.dropLast()))
        XCTAssertEqual(dict["end_date_local"] as? String, String(expectedEnd.dropLast()))
    }

    func testTheEventDictDefaultsToTheProcessZoneForAllDayDates() async throws {
        let (zone, start, next) = try gapDay()
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let server = try await CheICalMCPServer()
        let rawEnd = start.addingTimeInterval(86_399)
        let event = FakeFormattableEvent(formatStartDate: start, formatEndDate: rawEnd,
                                         formatSourceTimeZone: nil, formatIsAllDay: true)
        let dict = server.formatEventDict(event, displayTimezone: utc)
        // The Havana run exercises the correction with no injected all-day zone.
        if ProcessInfo.processInfo.environment["TZ"] == "America/Havana" {
            XCTAssertEqual(TimeZone.current.identifier, "America/Havana")
        }
        let expectedEnd = TimeZone.current.identifier == zone.identifier ? next.addingTimeInterval(-1) : rawEnd
        XCTAssertEqual(dict["end_date"] as? String, ISO8601DateFormatter().string(from: expectedEnd))
    }

    // Use the reported Havana transition to pin these exact overlapping shapes.
    func testCanonicalHalifaxAndBogotaPairsKeepTheirOwnDays() async throws {
        let havana = try XCTUnwrap(TimeZone(identifier: "America/Havana"))
        let server = try await CheICalMCPServer()
        let iso = ISO8601DateFormatter()
        for (identifier, startText, endText) in [
            ("America/Halifax", "2028-03-12T04:00:00Z", "2028-03-13T02:59:59Z"),
            ("America/Bogota", "2028-03-12T05:00:00Z", "2028-03-13T04:59:59Z")
        ] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            let start = try XCTUnwrap(iso.date(from: startText))
            let end = try XCTUnwrap(iso.date(from: endText))
            let event = FakeFormattableEvent(formatStartDate: start, formatEndDate: end,
                                             formatSourceTimeZone: zone, formatIsAllDay: true)
            let dict = server.formatEventDict(event, displayTimezone: zone, allDayZone: havana)
            XCTAssertEqual(dict["start_date"] as? String, startText, identifier)
            XCTAssertEqual(dict["end_date"] as? String, endText, identifier)
            XCTAssertEqual(dict["start_date_local"] as? String, "2028-03-12T00:00:00", identifier)
            XCTAssertEqual(dict["end_date_local"] as? String, "2028-03-12T23:59:59", identifier)

            let plan = try AllDayRange.planUpdate(storedStart: start, storedEnd: end, storedAllDay: true,
                                                  newStart: nil, newEnd: nil, requestedAllDay: nil,
                                                  calendar: .gregorian(in: havana), storedZone: zone)
            XCTAssertEqual(plan.start, start, identifier)
            XCTAssertEqual(plan.end, end, identifier)
        }
    }

    func testFractionalICloudAndGooglePairsAreRecognizedAtWholeSeconds() throws {
        let (zone, start, next) = try gapDay()
        let lastSecond = next.addingTimeInterval(-1)
        for (rawStart, rawEnd) in [
            (start, start.addingTimeInterval(86_399.25)),
            (start, start.addingTimeInterval(86_399)),
            (start.addingTimeInterval(-3599.75), lastSecond.addingTimeInterval(-3600)),
            (start.addingTimeInterval(-3600), lastSecond.addingTimeInterval(-3599.75))
        ] {
            let dates = stored(rawStart, rawEnd, zone)
            XCTAssertEqual(dates.start, start)
            XCTAssertEqual(dates.end, lastSecond)
        }

        // Spring and autumn offset changes cancel over this range. Its pair is already canonical.
        let havana = try XCTUnwrap(TimeZone(identifier: "America/Havana"))
        let iso = ISO8601DateFormatter()
        let springStart = try XCTUnwrap(iso.date(from: "2028-03-12T05:00:00Z"))
        let autumnEnd = try XCTUnwrap(iso.date(from: "2028-11-06T04:59:59Z")).addingTimeInterval(0.25)
        let canonical = stored(springStart, autumnEnd, havana)
        XCTAssertEqual(canonical.start, springStart)
        XCTAssertEqual(canonical.end, autumnEnd)
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
        let day = FlexibleDate.formatter("yyyy-MM-dd", zone: TimeZone(identifier: "UTC")!)
            .string(from: start.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: start))))
        let iso = ISO8601DateFormatter()
        for eventZone in [nil, zone] {
            let event = FakeFormattableEvent(formatStartDate: start, formatEndDate: start.addingTimeInterval(86_399),
                                             formatSourceTimeZone: eventZone, formatIsAllDay: true)
            let dict = server.formatEventDict(event, displayTimezone: zone, allDayZone: zone)
            XCTAssertEqual(dict["start_date_local"] as? String, "\(day)T01:00:00")
            XCTAssertEqual(dict["end_date_local"] as? String, "\(day)T23:59:59")
            XCTAssertEqual(dict["end_date"] as? String, iso.string(from: next.addingTimeInterval(-1)))
        }
    }

    /// A timed event's dates are printed as EventKit returns them.
    func testATimedEventDictIsUnchanged() async throws {
        let (zone, start, _) = try gapDay()
        let server = try await CheICalMCPServer()
        let event = FakeFormattableEvent(formatStartDate: start, formatEndDate: start.addingTimeInterval(86_399),
                                         formatSourceTimeZone: zone, formatIsAllDay: false)
        let dict = server.formatEventDict(event, displayTimezone: zone, allDayZone: zone)
        let iso = ISO8601DateFormatter()
        let expectedStart = iso.string(from: start)
        let expectedEnd = iso.string(from: start.addingTimeInterval(86_399))
        let local = FlexibleDate.formatter("yyyy-MM-dd'T'HH:mm:ss", zone: zone)
        XCTAssertEqual(dict["start_date"] as? String, expectedStart)
        XCTAssertEqual(dict["end_date"] as? String, expectedEnd)
        XCTAssertEqual(dict["start_date_local"] as? String, local.string(from: start))
        XCTAssertEqual(dict["end_date_local"] as? String, local.string(from: start.addingTimeInterval(86_399)))
    }
}
