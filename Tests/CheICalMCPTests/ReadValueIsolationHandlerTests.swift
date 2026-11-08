import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #490, the remainder of #482: the read handlers format what the read seams return. The probe
/// actor builds its `EventReadValue`s on its own actor from an event whose every accessor traps
/// (`preconditionIsolated`, which also checks in -O builds) anywhere else, as the manager builds
/// them from `EKEvent`s on its actor. A handler, or `formatEventDict`, that read the event itself
/// after the await would run off that actor and trap; a value copied on the actor reads nothing.
final class ReadValueIsolationHandlerTests: XCTestCase {
    private func call(_ tool: String, _ arguments: [String: Value], probe: ReadIsolationProbe) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventRangeReadSource: probe, calendarListSource: probe)
        let text = try await server.executeToolCall(name: tool, arguments: arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private let range: [String: Value] = ["start_date": .string("2027-03-01T00:00:00Z"), "end_date": .string("2027-03-08T00:00:00Z")]

    func testListEventsFormatsValuesBuiltOnTheActor() async throws {
        let probe = ReadIsolationProbe()
        let response = try await call("list_events", range.merging(["filter": .string("all_day")]) { $1 }, probe: probe)
        let events = try XCTUnwrap(response["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["title"] as? String }, ["#490 all-day"], "filtered on the value's all-day flag")
        XCTAssertNotNil(events.first?["attendees"])
        let reads = await probe.isolatedReads
        XCTAssertGreaterThan(reads, 0, "the values were built from the trapping events, on the probe's actor")
    }

    func testSearchEventsFormatsValuesBuiltOnTheActor() async throws {
        let probe = ReadIsolationProbe()
        let response = try await call("search_events", range.merging(["keyword": .string("#490")]) { $1 }, probe: probe)
        XCTAssertEqual((response["events"] as? [[String: Any]])?.count, 2)
    }

    func testListEventsQuickFormatsValuesBuiltOnTheActor() async throws {
        let probe = ReadIsolationProbe()
        let response = try await call("list_events_quick", ["range": .string("today")], probe: probe)
        XCTAssertEqual((response["events"] as? [[String: Any]])?.count, 2)
        let lists = await probe.listCalls
        XCTAssertEqual(lists, 1, "list_events_quick reads through the range seam")
    }

    func testCheckConflictsFormatsValuesBuiltOnTheActor() async throws {
        let probe = ReadIsolationProbe()
        let response = try await call("check_conflicts", ["start_time": .string("2027-03-01T00:00:00Z"),
                                                          "end_time": .string("2027-03-02T00:00:00Z")], probe: probe)
        XCTAssertEqual(response["conflict_count"] as? Int, 2)
        XCTAssertEqual(response["has_conflicts"] as? Bool, true)
    }

    func testListCalendarsListsTheValues() async throws {
        let probe = ReadIsolationProbe()
        let server = try await CheICalMCPServer(eventRangeReadSource: probe, calendarListSource: probe)
        let text = try await server.executeToolCall(name: "list_calendars", arguments: ["type": .string("event")])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]], text)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["source_type"] as? String, "iCloud")
        XCTAssertEqual(rows.first?["title"] as? String, "#490 calendar")
        let types = await probe.calendarTypes
        XCTAssertEqual(types, [.event])
    }
}

/// The read seams, answered with values built on this actor from `TrappingEvent`s.
actor ReadIsolationProbe: EventRangeReadSource, CalendarListSource {
    private(set) var isolatedReads = 0
    private(set) var listCalls = 0
    private(set) var calendarTypes: [EKEntityType?] = []

    fileprivate func noteRead() { isolatedReads += 1 }

    private func values() -> [EventReadValue] {
        let start = ISO8601DateFormatter().date(from: "2027-03-01T02:00:00Z")!
        return [
            TrappingEvent(probe: self, event: FakeFormattableEvent(formatTitle: "#490 timed", formatStartDate: start,
                                                                   formatEndDate: start.addingTimeInterval(3600))),
            TrappingEvent(probe: self, event: FakeFormattableEvent(formatTitle: "#490 all-day", formatStartDate: start,
                                                                   formatEndDate: start.addingTimeInterval(86_400),
                                                                   formatSourceTimeZone: nil, formatIsAllDay: true))
        ].map(EventReadValue.init)
    }

    func listEventValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?) async throws -> [EventReadValue] {
        listCalls += 1
        return values()
    }

    func searchEventValues(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                           calendarName: String?, calendarSource: String?) async throws -> [EventReadValue] {
        values()
    }

    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue] {
        values()
    }

    func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue] {
        calendarTypes.append(entityType)
        return [CalendarReadValue(identifier: "C1", title: "#490 calendar", typeRawValue: EKCalendarType.calDAV.rawValue,
                                  allowsContentModifications: true, isSubscribed: false, sourceTitle: "iCloud", sourceType: .mobileMe)]
    }
}

/// Every accessor traps unless it runs on `probe`'s actor, then counts the read there.
private struct TrappingEvent: EventFormattingSource {
    let probe: ReadIsolationProbe
    let event: FakeFormattableEvent

    private func read<T>(_ value: T) -> T {
        probe.preconditionIsolated("an event's property must be read on the actor that owns it")
        probe.assumeIsolated { $0.noteRead() }
        return value
    }

    var formatID: String? { read(event.formatID) }
    var formatTitle: String? { read(event.formatTitle) }
    var formatStartDate: Date { read(event.formatStartDate) }
    var formatEndDate: Date { read(event.formatEndDate) }
    var formatSourceTimeZone: TimeZone? { read(event.formatSourceTimeZone) }
    var formatIsAllDay: Bool { read(event.formatIsAllDay) }
    var formatCalendarTitle: String { read(event.formatCalendarTitle) }
    var formatLocation: String? { read(event.formatLocation) }
    var formatNotes: String? { read(event.formatNotes) }
    var formatURL: URL? { read(event.formatURL) }
    var recurrenceRulesFragment: [[String: Any]]? { read(event.recurrenceRulesFragment) }
    var structuredLocationFragment: [String: Any]? { read(event.structuredLocationFragment) }
    var attendeesFragment: [[String: Any]]? { read(event.attendeesFragment) }
    var organizerFragment: [String: Any]? { read(event.organizerFragment) }
    var alarmsFragment: [ReminderReadSnapshot.Alarm] { read(event.alarmsFragment) }
}
