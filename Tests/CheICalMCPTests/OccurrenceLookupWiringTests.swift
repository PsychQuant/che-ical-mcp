import XCTest
@testable import CheICalMCP

/// #573: each occurrence lookup names the calendar of the object it read. The query itself is
/// tested in `OccurrenceLookupTests`; what a fake store cannot show is which object's calendar
/// each caller passes, so it is pinned here over the source (comments stripped, whitespace
/// collapsed).
final class OccurrenceLookupWiringTests: XCTestCase {
    private func manager() throws -> String {
        let file = try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift")
        return SourceScan.collapsingWhitespace(SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
    }

    private func assertOnce(_ text: String, in code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SourcePins.ranges(of: text, in: code).count, 1, text, file: file, line: line)
    }

    /// Every call names a calendar: the parameter has no default, and the store is asked only
    /// through `OccurrenceLookup` with it.
    func testTheHelpersTakeTheCalendarAndQueryOnlyIt() throws {
        let code = try manager()
        assertOnce("func findOccurrence(identifier: String, on date: Date, in timeZone: TimeZone? = nil, slot: Date? = nil, calendar: EKCalendar?) -> EKEvent? { OccurrenceLookup.find(identifier: identifier, on: date, in: timeZone, slot: slot, seriesCalendar: calendar, enumerate: enumerateDayWindow, read: OccurrenceLookup.Candidate.init) }", in: code)
        assertOnce("func dayReadings(containing date: Date, in timeZone: TimeZone?, calendar: EKCalendar?) -> [EditedOccurrenceAddress.Reading] { OccurrenceLookup.dayReadings(containing: date, in: timeZone, seriesCalendar: calendar, enumerate: enumerateDayWindow, read: EditedOccurrenceAddress.Reading.init) }", in: code)
        assertOnce("private func enumerateDayWindow(_ start: Date, _ end: Date, _ calendars: [EKCalendar]?, _ body: (EKEvent) -> Bool) { let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)", in: code)
        XCTAssertFalse(code.contains("calendar: EKCalendar? = nil) -> EKEvent?"), "no default calendar on findOccurrence")
        // The only event query of every calendar left in the manager is the one a caller asks for by name.
        XCTAssertFalse(code.contains("predicateForEvents(withStart: window.start, end: window.end, calendars: nil)"))
    }

    /// The calendar each caller passes (the Diagnosis table): the series object it read, the event it
    /// just created, or the calendar the duplicate lookup searched; never the target of a move.
    func testEachCallerPassesTheSeriesCalendar() throws {
        let code = try manager()
        assertOnce("lookupHit: findOccurrence(identifier: seriesID, on: date, in: tz, calendar: calendar) != nil, onDay: dayReadings(containing: date, in: tz, calendar: calendar)", in: code)
        assertOnce("resolve: { self.findOccurrence(identifier: masterId, on: $0, in: timezone, calendar: event.calendar) }", in: code)
        XCTAssertEqual(SourcePins.ranges(of: "guard let occurrence = findOccurrence(identifier: identifier, on: date, in: Self.occurrenceZone(of: masterEvent), calendar: masterEvent.calendar) else {", in: code).count, 2,
                       "updateEvent and deleteEvent")
        assertOnce("guard let occurrence = findOccurrence(identifier: item.identifier, on: date, in: masterEvent.timeZone, slot: slot, calendar: masterEvent.calendar) else {", in: code)
        assertOnce("guard let occurrence = findOccurrence(identifier: identifier, on: date, in: Self.occurrenceZone(of: master), calendar: master.calendar) else {", in: code)
        assertOnce("matches: editedOccurrences(for: request, calendar: series.calendar), request: request)", in: code)
        assertOnce("EditedOccurrenceAddress.matches(onDay: dayReadings(containing: request.requested, in: request.seriesZone, calendar: calendar), for: request)", in: code)
        XCTAssertFalse(code.contains("calendar: targetCalendar) else {"), "a move looks the occurrence up in its own calendar")
        // Seven calls in all: none left without a calendar.
        XCTAssertEqual(SourcePins.ranges(of: "findOccurrence(identifier:", in: code).count, 7, "six calls and the declaration")
        XCTAssertEqual(SourcePins.ranges(of: "dayReadings(containing:", in: code).count, 3, "two calls and the declaration")
    }

    /// The exclusion retry's `calendar` is the calendar the duplicate lookup searched: the request's,
    /// bound once in `createEvent` before the lookup.
    func testTheRetryCalendarIsTheOneTheDuplicateLookupSearched() throws {
        let code = try manager()
        let create = try XCTUnwrap(code.range(of: "let calendar = try findCalendar(name: name, source: calendarSource, entityType: .event) if let existing = findDuplicateEvent(title: title, startDate: startDate, isAllDay: isAllDay, calendar: calendar) {"))
        let lookup = try XCTUnwrap(code.range(of: "lookupHit: findOccurrence(identifier: seriesID, on: date, in: tz, calendar: calendar)"))
        XCTAssertLessThan(create.lowerBound, lookup.lowerBound)
        let between = String(code[create.upperBound..<lookup.lowerBound])
        XCTAssertFalse(between.contains("let calendar"), "no other calendar is bound in between")
        XCTAssertFalse(between.contains("calendar ="), "no other calendar is bound in between")
    }
}
