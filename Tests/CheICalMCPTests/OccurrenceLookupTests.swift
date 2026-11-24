import XCTest
@testable import CheICalMCP

/// #573: the occurrence lookups name the series' calendar. A fake store holds events in two calendars
/// over the searched day and records the calendars each query names, as EventKit's
/// `predicateForEvents(withStart:end:calendars:)` would take them.
final class OccurrenceLookupTests: XCTestCase {
    private struct Event: Equatable {
        let calendar: String
        let id: String?
        let slot: Date?
        let start: Date
        var isAllDay = false
    }

    private final class FakeStore {
        var events: [Event] = []
        private(set) var queriedCalendars: [[String]?] = []

        func enumerate(_ start: Date, _ end: Date, _ calendars: [String]?, _ body: (Event) -> Bool) {
            queriedCalendars.append(calendars)
            for event in events where event.start >= start && event.start < end {
                if let calendars, !calendars.contains(event.calendar) { continue }
                if body(event) { return }
            }
        }
    }

    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let iso = ISO8601DateFormatter()
    private func at(_ s: String) -> Date { iso.date(from: s)! }

    private static func read(_ event: Event) -> OccurrenceLookup.Candidate {
        OccurrenceLookup.Candidate(eventIdentifier: event.id, occurrenceDate: event.slot, startDate: event.start, isAllDay: event.isAllDay)
    }

    private func store() -> FakeStore {
        let store = FakeStore()
        let ten = at("2026-12-07T02:00:00Z")   // 10:00 in Taipei
        store.events = [
            Event(calendar: "Other", id: "OTHER-SERIES", slot: ten, start: ten),
            Event(calendar: "Other", id: nil, slot: nil, start: ten.addingTimeInterval(3_600)),
            Event(calendar: "Work", id: "SERIES", slot: ten, start: ten),
            Event(calendar: "Work", id: "SERIES", slot: ten.addingTimeInterval(7_200), start: ten.addingTimeInterval(7_200))
        ]
        return store
    }

    func testTheLookupNamesOnlyTheSeriesCalendarAndFindsTheOccurrence() {
        let store = store()
        let found = OccurrenceLookup.find(identifier: "SERIES", on: at("2026-12-07T04:00:00Z"), in: taipei, slot: nil,
                                          seriesCalendar: "Work", host: taipei, enumerate: store.enumerate, read: Self.read)
        XCTAssertEqual(found?.calendar, "Work")
        XCTAssertEqual(found?.start, at("2026-12-07T02:00:00Z"))
        XCTAssertEqual(store.queriedCalendars, [["Work"]], "one query, naming the series' calendar only")
    }

    func testTheSlotStillPicksAmongTheSeriesOccurrencesOfTheDay() {
        let store = store()
        let slot = at("2026-12-07T04:00:00Z")
        let found = OccurrenceLookup.find(identifier: "SERIES", on: slot, in: taipei, slot: slot,
                                          seriesCalendar: "Work", host: taipei, enumerate: store.enumerate, read: Self.read)
        XCTAssertEqual(found?.slot, slot)
    }

    /// The answer is the one the query of every calendar (`main`) gives, for each requested series.
    func testTheAnswerMatchesTheQueryOfEveryCalendar() {
        for (identifier, calendar) in [("SERIES", "Work"), ("OTHER-SERIES", "Other"), ("MISSING", "Work")] {
            let scoped = OccurrenceLookup.find(identifier: identifier, on: at("2026-12-07T04:00:00Z"), in: taipei, slot: nil,
                                               seriesCalendar: calendar, host: taipei, enumerate: store().enumerate, read: Self.read)
            let everywhere = OccurrenceLookup.find(identifier: identifier, on: at("2026-12-07T04:00:00Z"), in: taipei, slot: nil,
                                                   seriesCalendar: String?.none, host: taipei, enumerate: store().enumerate, read: Self.read)
            XCTAssertEqual(scoped, everywhere, identifier)
        }
    }

    /// An occurrence the store reports in another calendar is not found: the case this change gives up
    /// (not seen on iCloud, #426), and a miss writes nothing at any caller.
    func testAnOccurrenceReportedInAnotherCalendarIsNotFound() {
        let store = store()
        XCTAssertNil(OccurrenceLookup.find(identifier: "OTHER-SERIES", on: at("2026-12-07T04:00:00Z"), in: taipei, slot: nil,
                                           seriesCalendar: "Work", host: taipei, enumerate: store.enumerate, read: Self.read))
        XCTAssertEqual(store.queriedCalendars, [["Work"]])
    }

    /// Every calendar only when the series' calendar is unknown, as `main` queried.
    func testAnUnknownCalendarQueriesEveryCalendar() {
        let store = store()
        let found = OccurrenceLookup.find(identifier: "SERIES", on: at("2026-12-07T04:00:00Z"), in: taipei, slot: nil,
                                          seriesCalendar: String?.none, host: taipei, enumerate: store.enumerate, read: Self.read)
        XCTAssertEqual(found?.calendar, "Work")
        XCTAssertEqual(store.queriedCalendars, [nil])
        XCTAssertNil(OccurrenceLookup.scope(seriesCalendar: String?.none))
        XCTAssertEqual(OccurrenceLookup.scope(seriesCalendar: "Work"), ["Work"])
    }

    func testTheDayReadingsNameOnlyTheSeriesCalendar() {
        let store = store()
        let readings = OccurrenceLookup.dayReadings(containing: at("2026-12-07T04:00:00Z"), in: taipei, seriesCalendar: "Work",
                                                    host: taipei, enumerate: store.enumerate) {
            EditedOccurrenceAddress.Reading(eventIdentifier: $0.id, isAllDay: $0.isAllDay, start: $0.start)
        }
        XCTAssertEqual(readings.map(\.eventIdentifier), ["SERIES", "SERIES"])
        XCTAssertEqual(store.queriedCalendars, [["Work"]])
    }
}
