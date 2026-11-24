import XCTest
@testable import CheICalMCP

/// #590: no event or reminder query reads every calendar unless the caller asks for it by leaving
/// the calendar out. The query paths a caller asks for (`list_events` without `calendar_name`, and
/// the like) pass a value that is nil only then; a literal `calendars: nil` is a query of every
/// calendar that no caller asked for, so none may be left in `Sources/`. Read over the code with
/// comments and string literals blanked (`SourceScan.codeOnly`).
final class NoUnrequestedAllCalendarQueryWiringTests: XCTestCase {
    private func code(_ file: URL) throws -> String {
        SourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
    }

    private func manager() throws -> String {
        try code(try SourceScan.sourcesDirectory().appendingPathComponent("EventKit/EventKitManager.swift"))
    }

    func testNoSourceFileQueriesEveryCalendarLiterally() throws {
        var found: [String] = []
        for file in try SourceScan.swiftFiles() {
            let count = SourcePins.ranges(ofPattern: #"calendars:\s*nil\b"#, in: try code(file)).count
            if count > 0 { found.append("\(file.lastPathComponent): \(count)") }
        }
        XCTAssertEqual(found, [], "a literal calendars: nil queries every calendar")
    }

    /// The search behind `create_events_batch`'s `similar_events` reads only the row's calendar.
    func testTheSimilarEventsSearchQueriesOnlyTheCalendarItIsGiven() throws {
        let code = try manager()
        let body = try XCTUnwrap(SourceScan.body(of: "func findSimilarEvents(title: String, calendarIdentifier: String, limit: Int = 5) async throws -> [EKEvent] {", in: code))
        XCTAssertEqual(SourcePins.ranges(of: "guard let calendar = eventStore.calendar(withIdentifier: calendarIdentifier) else {", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"events\(from: searched\.start, to: searched\.end, calendars: \[calendar\]\)"#, in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "calendars:", in: body).count, 1, "one query, of that calendar")
    }

    /// The adapter the batch handler calls: the saved event's calendar is recorded, and the
    /// identifier the handler passes is the one the search reads (an in-memory store has no saved
    /// event to show either, so they are pinned here).
    func testTheAdapterRecordsTheSavedCalendarAndForwardsIt() throws {
        let adapter = SourceScan.collapsingWhitespace(try code(try SourceScan.sourcesDirectory().appendingPathComponent("EventWriteSource.swift")))
        XCTAssertEqual(SourcePins.ranges(of: "seriesIdentifier: seriesIdentifier, calendarIdentifier: event.calendar?.calendarIdentifier)", in: adapter).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "try await findSimilarEvents(title: title, calendarIdentifier: calendarIdentifier, limit: limit)", in: adapter).count, 1)
    }

    /// #591: `enumerateDayWindow` queries the store with whatever calendars it is handed; it has
    /// exactly two callers, `findOccurrence` and `dayReadings`, which hand it the series' calendar
    /// (`OccurrenceLookupWiringTests`). Without this count, a third caller handing it some other range or
    /// calendars would go unnoticed.
    func testTheDayWindowHasExactlyItsTwoCallers() throws {
        var named: [String: Int] = [:]
        for file in try SourceScan.swiftFiles() {
            let count = SourcePins.ranges(of: "enumerateDayWindow", in: try code(file)).count
            if count > 0 { named[file.lastPathComponent] = count }
        }
        XCTAssertEqual(named, ["EventKitManager.swift": 3], "its declaration and its two callers")
        let code = try manager()
        XCTAssertEqual(SourcePins.ranges(of: "enumerate: enumerateDayWindow, read:", in: code).count, 2)
        XCTAssertEqual(SourcePins.ranges(of: "private func enumerateDayWindow(", in: code).count, 1)
    }
}
