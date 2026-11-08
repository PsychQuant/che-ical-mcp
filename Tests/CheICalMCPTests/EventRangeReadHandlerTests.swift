import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// Answers with the events it was given, or the error. Scrambled, as EventKit's read order is:
/// it holds spans in order but is not date order (PR #430 verify round 2 measured 40 of the first
/// 500 rows among the oldest 500), so a test cannot pass by assuming it is.
private final class EventRangeReadFake: EventRangeReadSource, @unchecked Sendable {
    let events: [EKEvent]
    let readError: Error?

    init(events: [EKEvent], readError: Error? = nil) {
        self.events = events.enumerated().sorted { ($0.offset * 7919) % 1009 < ($1.offset * 7919) % 1009 }.map(\.element)
        self.readError = readError
    }

    func listEventValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?) async throws -> [EventReadValue] {
        if let readError { throw readError }
        return events.map(EventReadValue.init)
    }

    func searchEventValues(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                           calendarName: String?, calendarSource: String?) async throws -> [EventReadValue] {
        if let readError { throw readError }
        return events.map(EventReadValue.init)
    }

    /// #490: the conflicts read went through the range seam; these tests do not call it.
    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue] {
        if let readError { throw readError }
        return events.map(EventReadValue.init)
    }
}

/// #332: what `list_events` and `search_events` answer over a range wider than EventKit's old cut.
/// `event_count` stays the total (#107), `truncated` is set exactly when fewer rows came back than
/// `event_count`, whoever cut them, and `default_limit` only when the default output bound did.
final class EventRangeReadHandlerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let base = ISO8601DateFormatter().date(from: "2001-01-01T00:00:00Z")!
    private let iso = ISO8601DateFormatter()
    private var store: EKEventStore { SharedTestStore.store }

    private func events(_ count: Int, from: Date? = nil) -> [EKEvent] {
        let calendar = EKCalendar(for: .event, eventStore: store)
        let first = from ?? base
        return (0..<count).map { index in
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = "#332 \(index)"
            event.startDate = first.addingTimeInterval(Double(index) * 3600)
            event.endDate = event.startDate.addingTimeInterval(1800)
            return event
        }
    }

    private enum Tool: CaseIterable {
        case list, search

        var name: String { self == .list ? "list_events" : "search_events" }
        /// `limit` and `default_limit` sit where each tool has always put `limit`.
        func holder(_ response: [String: Any]) -> [String: Any]? {
            self == .list ? response["metadata"] as? [String: Any] : response
        }
    }

    private func call(_ tool: Tool, events: [EKEvent], days: Double, extra: [String: Value] = [:], oneSided: Bool = false) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventRangeReadSource: EventRangeReadFake(events: events))
        var arguments: [String: Value] = ["start_date": .string(iso.string(from: base))]
        if !oneSided { arguments["end_date"] = .string(iso.string(from: base.addingTimeInterval(days * day))) }
        if tool == .search { arguments["keyword"] = .string("#332") }
        let raw = try await server.executeToolCall(name: tool.name, arguments: arguments.merging(extra) { $1 })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func rows(_ response: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(response["events"] as? [[String: Any]])
    }

    func testAWideRangeWithoutALimitReturnsTheDefaultAndSaysSo() async throws {
        for tool in Tool.allCases {
            let response = try await call(tool, events: events(501), days: 1463)
            XCTAssertEqual(try rows(response).count, 500, tool.name)
            XCTAssertEqual(response["event_count"] as? Int, 501, tool.name)
            XCTAssertEqual(response["truncated"] as? Bool, true, tool.name)
            XCTAssertEqual(tool.holder(response)?["default_limit"] as? Int, 500, tool.name)
        }
    }

    func testAWideRangeAtTheDefaultIsNotTruncated() async throws {
        for tool in Tool.allCases {
            let response = try await call(tool, events: events(500), days: 1463)
            XCTAssertEqual(try rows(response).count, 500, tool.name)
            XCTAssertEqual(response["event_count"] as? Int, 500, tool.name)
            XCTAssertNil(response["truncated"], tool.name)
            XCTAssertNil(tool.holder(response)?["default_limit"], tool.name)
        }
    }

    /// The caller's `limit` replaces the default. `truncated` follows the rows, not who cut them: a
    /// retry with a larger limit that still leaves rows out must not read as complete (PR #430 verify).
    func testTheCallersLimitWinsOverAWideRange() async throws {
        for tool in Tool.allCases {
            let cut = try await call(tool, events: events(501), days: 1463, extra: ["limit": .int(3)])
            XCTAssertEqual(try rows(cut).count, 3, tool.name)
            XCTAssertEqual(cut["event_count"] as? Int, 501, tool.name)
            XCTAssertEqual(cut["truncated"] as? Bool, true, tool.name)
            XCTAssertEqual(tool.holder(cut)?["limit"] as? Int, 3, tool.name)
            XCTAssertNil(tool.holder(cut)?["default_limit"], tool.name)

            let whole = try await call(tool, events: events(501), days: 1463, extra: ["limit": .int(2000)])
            XCTAssertEqual(try rows(whole).count, 501, tool.name)
            XCTAssertEqual(whole["event_count"] as? Int, 501, tool.name)
            XCTAssertNil(whole["truncated"], tool.name)
            XCTAssertNil(tool.holder(whole)?["default_limit"], tool.name)
        }
    }

    /// No default below the wide line, and `truncated` still follows the rows there.
    func testARangeOfAtMost1462DaysHasNoDefault() async throws {
        for tool in Tool.allCases {
            let response = try await call(tool, events: events(501), days: 1462)
            XCTAssertEqual(try rows(response).count, 501, tool.name)
            XCTAssertEqual(response["event_count"] as? Int, 501, tool.name)
            XCTAssertNil(response["truncated"], tool.name)
            XCTAssertNil(tool.holder(response)?["default_limit"], tool.name)

            let limited = try await call(tool, events: events(501), days: 1462, extra: ["limit": .int(3)])
            XCTAssertEqual(limited["truncated"] as? Bool, true, tool.name)
            XCTAssertNil(tool.holder(limited)?["default_limit"], tool.name)
        }
    }

    /// The tool's own Tip sends a search for old events here: only start_date, so the end defaults
    /// to two years from today and the range is wide. The rows kept are the ones closest to today,
    /// not to the end of the range, in start order, and the answer says so (PR #430 verify).
    func testAOneSidedSearchKeepsTheRowsClosestToToday() async throws {
        let now = Date()
        let old = events(600)   // from 2001
        let recent = events(100, from: now.addingTimeInterval(-50 * 3600))   // around today
        // Just inside the end of the range: a cut measured from there would keep these instead.
        let late = events(600, from: now.addingTimeInterval(700 * day))
        let response = try await call(.search, events: old + recent + late, days: 0, oneSided: true)
        let searched = try XCTUnwrap(response["searched_range"] as? [String: Any])
        XCTAssertEqual(searched["is_default_range"] as? Bool, true)
        XCTAssertEqual(response["event_count"] as? Int, 1300)
        XCTAssertEqual(response["truncated"] as? Bool, true)
        XCTAssertEqual(response["default_limit"] as? Int, 500)
        let kept = try rows(response)
        XCTAssertEqual(kept.count, 500)
        let starts = try kept.map { try XCTUnwrap($0["start_date"] as? String) }
        XCTAssertEqual(starts, starts.sorted())
        // All 100 around today, then the 400 nearest of the late ones, none of the old ones.
        let iso = ISO8601DateFormatter()
        let first = try XCTUnwrap(iso.date(from: starts[0]))
        XCTAssertLessThan(abs(first.timeIntervalSince(now)), 60 * 3600, "the rows around today are kept")
        XCTAssertEqual(try kept.map { try XCTUnwrap($0["title"] as? String) }.last, "#332 399", "the 400 nearest of the late ones")
        let note = try XCTUnwrap(response["truncation_note"] as? String)
        for phrase in ["500 of 1300", "closest to today", "sorted by start", "limit", "narrower range"] {
            XCTAssertTrue(note.contains(phrase), "\(phrase): \(note)")
        }
    }

    /// One rule for any cut on search_events: a caller's `limit`, on a wide or a narrow range, keeps
    /// the rows closest to today too, sorted by start, and says so; only `default_limit` differs.
    func testACallersLimitOnASearchKeepsTheRowsClosestToToday() async throws {
        let now = Date()
        let around = events(9, from: now.addingTimeInterval(-4 * 3600))   // now - 4 h to now + 4 h
        let far = events(30)
        for days in [1463.0, 40.0] {
            let response = try await call(.search, events: far + around, days: days, extra: ["limit": .int(3)])
            let titles = try rows(response).map { try XCTUnwrap($0["title"] as? String) }
            XCTAssertEqual(titles, ["#332 3", "#332 4", "#332 5"], "\(days): the three closest to today, in start order")
            XCTAssertEqual(response["event_count"] as? Int, 39)
            XCTAssertEqual(response["truncated"] as? Bool, true)
            XCTAssertEqual(response["limit"] as? Int, 3)
            XCTAssertNil(response["default_limit"], "\(days)")
            let note = try XCTUnwrap(response["truncation_note"] as? String, "\(days)")
            XCTAssertTrue(note.contains("3 of 39"), note)
            XCTAssertTrue(note.contains("closest to today"), note)
        }
    }

    /// Nothing cut: no note, and the rows stay as they were read.
    func testAnUncutSearchHasNoNote() async throws {
        let response = try await call(.search, events: events(20), days: 40, extra: ["limit": .int(20)])
        XCTAssertNil(response["truncated"])
        XCTAssertNil(response["truncation_note"])
    }

    /// list_events has a sort: its `limit` keeps the first in that sort, closest to today or not.
    func testAListEventsLimitKeepsTheFirstInItsSort() async throws {
        let response = try await call(.list, events: events(20), days: 40, extra: ["limit": .int(2)])
        XCTAssertEqual(try rows(response).map { $0["title"] as? String }, ["#332 0", "#332 1"])
        XCTAssertNil(response["truncation_note"])
    }

    /// list_events cuts after filtering and sorting: `event_count` counts what the filter kept, and
    /// the rows are the first of the requested order.
    func testListEventsCutsAfterTheFilterAndTheSort() async throws {
        let past = events(501)
        let future = events(99, from: Date().addingTimeInterval(365 * day))
        let filtered = try await call(.list, events: past + future, days: 10_000, extra: ["filter": .string("past")])
        XCTAssertEqual(filtered["event_count"] as? Int, 501)
        XCTAssertEqual((filtered["metadata"] as? [String: Any])?["total_in_range"] as? Int, 600)
        XCTAssertEqual(try rows(filtered).count, 500)
        XCTAssertEqual(filtered["truncated"] as? Bool, true)

        let descending = try await call(.list, events: past, days: 1463, extra: ["sort": .string("desc")])
        XCTAssertEqual(try rows(descending).first?["title"] as? String, "#332 500")
    }

    /// What a client sees when the read bound stops the read: the whole message, not a generic one.
    func testTheReadBoundReachesTheCaller() async throws {
        let bound = EventRangeQuery.RangeError.tooManyEvents(limit: EventRangeQuery.maxEventsRead, from: base,
                                                             to: base.addingTimeInterval(36_500 * day),
                                                             readThrough: base.addingTimeInterval(1460 * day))
        for tool in Tool.allCases {
            let server = try await CheICalMCPServer(eventRangeReadSource: EventRangeReadFake(events: [], readError: bound))
            var arguments: [String: Value] = [
                "start_date": .string(iso.string(from: base)),
                "end_date": .string(iso.string(from: base.addingTimeInterval(36_500 * day)))
            ]
            if tool == .search { arguments["keyword"] = .string("#332") }
            let result = await server.handleToolCallForTesting(name: tool.name, arguments: arguments)
            XCTAssertEqual(result.isError, true, tool.name)
            guard case .text(let text, _, _)? = result.content.first else { return XCTFail(tool.name) }
            XCTAssertTrue(text.contains("more than 200,000"), text)
            XCTAssertTrue(text.contains("Narrow the range"), text)
            XCTAssertTrue(text.contains("A limit does not lift"), text)
        }
    }
}
