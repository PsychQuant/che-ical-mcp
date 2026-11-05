import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// Answers with the events it was given, or the error.
private final class EventRangeReadFake: EventRangeReadSource, @unchecked Sendable {
    let events: [EKEvent]
    let readError: Error?

    init(events: [EKEvent], readError: Error? = nil) {
        self.events = events
        self.readError = readError
    }

    func listEvents(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?) async throws -> [EKEvent] {
        if let readError { throw readError }
        return events
    }

    func searchEvents(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                      calendarName: String?, calendarSource: String?) async throws -> [EKEvent] {
        if let readError { throw readError }
        return events
    }
}

/// #332: what `list_events` and `search_events` answer over a range wider than EventKit's old cut.
/// `event_count` stays the total (#107), so `event_count` minus the rows is what was left out, and
/// `truncated` is set exactly when the default output bound, not the caller's `limit`, left some out.
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

    private func call(_ tool: Tool, events: [EKEvent], days: Double, extra: [String: Value] = [:]) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventRangeReadSource: EventRangeReadFake(events: events))
        var arguments: [String: Value] = [
            "start_date": .string(iso.string(from: base)),
            "end_date": .string(iso.string(from: base.addingTimeInterval(days * day)))
        ]
        if tool == .search { arguments["keyword"] = .string("#332") }
        let raw = try await server.executeToolCall(name: tool.name, arguments: arguments.merging(extra) { $1 })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func rows(_ response: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(response["events"] as? [[String: Any]])
    }

    func testAWideRangeWithoutALimitReturnsTheDefaultAndSaysSo() async throws {
        for tool in Tool.allCases {
            let response = try await call(tool, events: events(501), days: 1462)
            XCTAssertEqual(try rows(response).count, 500, tool.name)
            XCTAssertEqual(response["event_count"] as? Int, 501, tool.name)
            XCTAssertEqual(response["truncated"] as? Bool, true, tool.name)
            XCTAssertEqual(tool.holder(response)?["default_limit"] as? Int, 500, tool.name)
        }
    }

    func testAWideRangeAtTheDefaultIsNotTruncated() async throws {
        for tool in Tool.allCases {
            let response = try await call(tool, events: events(500), days: 1462)
            XCTAssertEqual(try rows(response).count, 500, tool.name)
            XCTAssertEqual(response["event_count"] as? Int, 500, tool.name)
            XCTAssertNil(response["truncated"], tool.name)
            XCTAssertNil(tool.holder(response)?["default_limit"], tool.name)
        }
    }

    func testTheCallersLimitWinsOverAWideRange() async throws {
        for tool in Tool.allCases {
            for limit in [3, 2000] {
                let response = try await call(tool, events: events(501), days: 1462, extra: ["limit": .int(limit)])
                XCTAssertEqual(try rows(response).count, min(limit, 501), tool.name)
                XCTAssertEqual(response["event_count"] as? Int, 501, tool.name)
                XCTAssertNil(response["truncated"], tool.name)
                XCTAssertEqual(tool.holder(response)?["limit"] as? Int, limit, tool.name)
                XCTAssertNil(tool.holder(response)?["default_limit"], tool.name)
            }
        }
    }

    func testARangeOfAtMost1461DaysIsUnchanged() async throws {
        for tool in Tool.allCases {
            let response = try await call(tool, events: events(501), days: 1461)
            XCTAssertEqual(try rows(response).count, 501, tool.name)
            XCTAssertEqual(response["event_count"] as? Int, 501, tool.name)
            XCTAssertNil(response["truncated"], tool.name)
            XCTAssertNil(tool.holder(response)?["default_limit"], tool.name)
        }
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

        let descending = try await call(.list, events: past, days: 1462, extra: ["sort": .string("desc")])
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
            XCTAssertTrue(text.contains("more than 20,000"), text)
            XCTAssertTrue(text.contains("Narrow the range"), text)
        }
    }
}
