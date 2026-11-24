import EventKit
import XCTest
@testable import CheICalMCP

/// #563: the create-undo scan of a series (`UndoPostState.differsFromSeries`) and an occurrence of an
/// all-day series edited on its own. Its `/RID=` digits are a floating date (the day at 00:00 read as
/// UTC, iCloud, 2026-10-14) while its start is midnight of that day in the host zone, so the instant
/// comparison alone counts it as moved off any host at UTC+0. Digits at 00:00 UTC can also be the
/// instant of a timed slot of a series later made all-day, and which one they are cannot be read
/// later (#543, PR #565). So the scan accepts more than the instant comparison only where both
/// readings name one day in the host zone.
///
/// The slot comparison (`onItsSlot`) is tested with the zone passed explicitly, so no result follows
/// `TZ`: an in-memory all-day `EKEvent` reads its start back at midnight of the process zone whatever
/// was set. The last test goes through `differsFromSeries` with events, in the process zone.
final class AllDayOccurrenceSlotTests: XCTestCase {
    private var store: EKEventStore { SharedTestStore.store }

    private func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier)! }
    private let utc = TimeZone(identifier: "UTC")!

    /// 00:00 UTC of `day` (`yyyy-MM-dd`): the instant the `/RID=` digits of an all-day occurrence of that day hold.
    private func utcMidnight(_ day: String) -> Date { midnight(day, in: utc) }

    private func midnight(_ day: String, in zone: TimeZone) -> Date {
        let parts = day.split(separator: "-").map { Int($0)! }
        return Calendar.gregorian(in: zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private func text(_ date: Date, _ zone: TimeZone, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Whether the scan counts an occurrence starting at `start` as moved off `slot` (the slot
    /// comparison only; the fields are compared as before).
    private func counted(start: Date, slot: Date, fromRID: Bool = true, occurrenceAllDay: Bool = true,
                         seriesAllDay: Bool = true, zone: TimeZone) -> Bool {
        !UndoPostState.onItsSlot(start: start, slot: slot, slotFromRID: fromRID,
                                 allDay: occurrenceAllDay && seriesAllDay, zone: zone)
    }

    // spec-example: create-undo-edited-occurrences / set back at its slot, by host zone
    func testAnAllDayOccurrenceSetBackAtItsSlotIsCountedOnlyWhereTheTwoReadingsNameDifferentDays() {
        let expected: [(String, Bool)] = [
            ("Pacific/Pago_Pago", true), ("America/Los_Angeles", true), ("UTC", false),
            ("Asia/Taipei", false), ("Pacific/Kiritimati", false),
        ]
        for (identifier, isCounted) in expected {
            let host = zone(identifier)
            XCTAssertEqual(counted(start: midnight("2027-01-11", in: host), slot: utcMidnight("2027-01-11"), zone: host),
                           isCounted, identifier)
        }
    }

    /// The process zone is not read: the zone passed decides.
    func testTheHostZoneIsTheOnePassed() {
        let taipei = zone("Asia/Taipei"), losAngeles = zone("America/Los_Angeles")
        XCTAssertFalse(counted(start: midnight("2027-01-11", in: taipei), slot: utcMidnight("2027-01-11"), zone: taipei))
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: utcMidnight("2027-01-11"), zone: losAngeles),
                      "a Taipei midnight read on a Los Angeles host is not that host's midnight")
        let tokyo = zone("Asia/Tokyo")
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: utcMidnight("2027-01-11"), zone: tokyo),
                      "east of UTC too, only the host's own midnight")
    }

    // spec-example: create-undo-edited-occurrences / shapes compared as before
    func testShapesOutsideTheAgreedDayAreComparedAsBefore() {
        let taipei = zone("Asia/Taipei")
        let slot = utcMidnight("2027-01-11")
        XCTAssertTrue(counted(start: midnight("2027-01-12", in: taipei), slot: slot, zone: taipei), "moved to the next day")
        XCTAssertTrue(counted(start: midnight("2027-01-10", in: taipei), slot: slot, zone: taipei), "moved to the day before")
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: slot, fromRID: false, zone: taipei),
                      "a slot from occurrenceDate is already local; compared as an instant")
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: slot.addingTimeInterval(3600), zone: taipei),
                      "digits not at 00:00 UTC cannot be a floating date")
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: slot, occurrenceAllDay: false, seriesAllDay: false, zone: taipei),
                      "a timed occurrence at local midnight, slot 08:00 Taipei")
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: slot, seriesAllDay: false, zone: taipei),
                      "an all-day occurrence of a timed series: its digits may be the timed slot")
        XCTAssertTrue(counted(start: midnight("2027-01-11", in: taipei), slot: slot, occurrenceAllDay: false, zone: taipei),
                      "a timed occurrence of an all-day series")
        XCTAssertFalse(counted(start: slot, slot: slot, occurrenceAllDay: false, seriesAllDay: false, zone: taipei),
                       "a timed occurrence at its /RID= instant, as before")
        XCTAssertFalse(counted(start: slot.addingTimeInterval(0.4), slot: slot, occurrenceAllDay: false, seriesAllDay: false, zone: taipei),
                       "to the second, as before")
    }

    /// On a UTC host the instant comparison already gives the answer.
    func testOnAUTCHostTheInstantComparisonDecides() {
        XCTAssertFalse(counted(start: utcMidnight("2027-01-11"), slot: utcMidnight("2027-01-11"), zone: utc))
        XCTAssertTrue(counted(start: utcMidnight("2027-01-12"), slot: utcMidnight("2027-01-11"), zone: utc))
    }

    /// A zone whose midnight is skipped on the slot's day: the occurrence starts at the day's first
    /// instant, which is what the host's midnight means there (PR #571).
    func testOnADayWithoutMidnightTheDaysFirstInstantIsTheSlot() {
        let havana = zone("America/Havana")
        let firstInstant = Calendar.gregorian(in: havana).startOfDay(for: utcMidnight("2028-03-12").addingTimeInterval(12 * 3600))
        XCTAssertTrue(counted(start: firstInstant, slot: utcMidnight("2028-03-12"), zone: havana),
                      "Havana is west of UTC: the two readings name different days")
        let east = TimeZone(secondsFromGMT: 3 * 3600)!
        XCTAssertFalse(counted(start: midnight("2028-03-12", in: east), slot: utcMidnight("2028-03-12"), zone: east))
    }

    /// Against `main`'s comparison (the start equals the slot as an instant), over zones from −12 to
    /// +14 hours and named zones, starts around three slots, every flag: nothing `main` accepts is
    /// counted, and every newly accepted cell is of the one kind the change accepts, checked by
    /// formatting the dates as text rather than through the code under test.
    func testNothingIsAcceptedBeyondMainExceptWhereBothReadingsNameOneDay() {
        var zones = (-12...14).compactMap { TimeZone(secondsFromGMT: $0 * 3600) }
        zones += ["America/Los_Angeles", "Asia/Taipei", "Asia/Kolkata", "America/St_Johns", "Pacific/Chatham", "America/Havana"].map(zone)
        let slots = ["2027-01-11", "2027-03-14", "2027-07-04"].flatMap { day in
            [utcMidnight(day), utcMidnight(day).addingTimeInterval(8 * 3600), utcMidnight(day).addingTimeInterval(-3600)]
        }
        var newlyAccepted = 0
        for host in zones {
            let calendar = Calendar.gregorian(in: host)
            for slot in slots {
                var starts = [slot, slot.addingTimeInterval(3600), slot.addingTimeInterval(-86_400)]
                for offset in -1...1 { starts.append(calendar.startOfDay(for: slot.addingTimeInterval(Double(offset) * 86_400))) }
                for start in starts {
                    for flags in 0..<8 {
                        let (fromRID, occurrenceAllDay, seriesAllDay) = (flags & 1 != 0, flags & 2 != 0, flags & 4 != 0)
                        let isCounted = counted(start: start, slot: slot, fromRID: fromRID, occurrenceAllDay: occurrenceAllDay,
                                                seriesAllDay: seriesAllDay, zone: host)
                        let label = "\(host.identifier) slot \(slot) start \(start) flags \(flags)"
                        if UndoPostState.sameInstant(start, slot) {
                            XCTAssertFalse(isCounted, "main's slot pass kept: " + label)
                            continue
                        }
                        guard !isCounted else { continue }
                        newlyAccepted += 1
                        let utcDay = text(slot, utc, "yyyy-MM-dd")
                        XCTAssertTrue(fromRID && occurrenceAllDay && seriesAllDay, label)
                        XCTAssertEqual(text(slot, utc, "HH:mm:ss"), "00:00:00", label)
                        XCTAssertEqual(text(slot, host, "yyyy-MM-dd"), utcDay, "both readings name one day: " + label)
                        XCTAssertEqual(text(start, host, "yyyy-MM-dd"), utcDay, label)
                        XCTAssertEqual(start, calendar.startOfDay(for: start), label)
                    }
                }
            }
        }
        XCTAssertGreaterThan(newlyAccepted, 0, "the grid reaches the cells the change accepts")
    }

    /// Through `differsFromSeries` with events as EventKit gives them in this process: an all-day
    /// occurrence reads its start at midnight of the process zone. Set back at the series' values, it
    /// is counted only where that zone puts 00:00 UTC of its day on another day; moved a day it is
    /// counted everywhere. The expectation is read off the formatted process-zone date.
    func testThroughTheScanComparisonInTheProcessZone() {
        func event(_ edit: (EKEvent) -> Void = { _ in }) -> EKEvent {
            let event = EKEvent(eventStore: store)
            event.title = "Gym"
            event.isAllDay = true
            event.startDate = midnight("2027-01-11", in: .current)
            event.endDate = event.startDate.addingTimeInterval(86_399)
            edit(event)
            return event
        }
        func face(_ event: EKEvent, fromRID: Bool = true) -> UndoPostState.OccurrenceFace {
            UndoPostState.OccurrenceFace(slot: utcMidnight("2027-01-11"), event: EventSnapshot(from: event, includeRecurrence: false),
                                         slotFromRID: fromRID)
        }
        let series = face(event())
        XCTAssertEqual(series.event.startDate, midnight("2027-01-11", in: .current), "precondition: EventKit's all-day start")
        let readingsDiffer = text(utcMidnight("2027-01-11"), .current, "yyyy-MM-dd") != "2027-01-11"
        XCTAssertEqual(UndoPostState.differsFromSeries(face(event()), series: series), readingsDiffer, TimeZone.current.identifier)
        let nextDay = event { $0.startDate = self.midnight("2027-01-12", in: .current); $0.endDate = $0.startDate.addingTimeInterval(86_399) }
        XCTAssertTrue(UndoPostState.differsFromSeries(face(nextDay), series: series))
        XCTAssertTrue(UndoPostState.differsFromSeries(face(event { $0.title = "Swim" }), series: series), "a field still counts")
        let onUTC = TimeZone.current.secondsFromGMT(for: utcMidnight("2027-01-11")) == 0
        XCTAssertEqual(UndoPostState.differsFromSeries(face(event(), fromRID: false), series: series), !onUTC,
                       "a slot from occurrenceDate: the instant comparison alone")
    }
}
