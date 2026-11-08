import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #490, the remainder of #482: the read handlers format what the read seams return. The probe
/// actor answers through `EventRowsPicked.picking`, as the manager does, from events whose every
/// accessor traps (`preconditionIsolated`, which also checks in -O builds) off the probe's actor.
/// What this proves: the keys and values the handlers receive forward nothing lazily, so neither a
/// handler nor `formatEventDict` reads an event after the await. It does not show where the
/// manager itself reads an `EKEvent`; the wiring pins in `ReadHandlerWiringTests` cover that.
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
        XCTAssertEqual(events.map { $0["title"] as? String }, ["#490 all-day"], "filtered on the key's all-day flag")
        XCTAssertNotNil(events.first?["attendees"])
        let reads = await probe.isolatedReads
        XCTAssertGreaterThan(reads, 0, "the keys and values were built from the trapping events, on the probe's actor")
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

    /// PR #495 round 1: only the rows a handler keeps are copied whole. Over 60 events, `limit: 3`
    /// copies 3 (a full copy reads the title; a key does not), with each handler that picks.
    func testOnlyTheKeptRowsAreCopiedWhole() async throws {
        for (tool, arguments) in [("list_events", range.merging(["limit": .int(3)]) { $1 }),
                                  ("search_events", range.merging(["keyword": .string("#490"), "limit": .int(3)]) { $1 }),
                                  ("list_events_quick", ["range": .string("today"), "limit": .int(3)] as [String: Value])] {
            let probe = ReadIsolationProbe(count: 60)
            let response = try await call(tool, arguments, probe: probe)
            XCTAssertEqual((response["events"] as? [[String: Any]])?.count, 3, tool)
            XCTAssertEqual(response["event_count"] as? Int, 60, tool)
            let copies = await probe.titleReads
            XCTAssertEqual(copies, 3, "\(tool) copies only the kept rows")
        }
    }

    /// The kept rows come back in the order the handler chose: `sort: desc` over the keys.
    func testTheKeptRowsComeBackInTheChosenOrder() async throws {
        let probe = ReadIsolationProbe(count: 5)
        let response = try await call("list_events", range.merging(["sort": .string("desc"), "limit": .int(2)]) { $1 }, probe: probe)
        let titles = (response["events"] as? [[String: Any]])?.map { $0["title"] as? String }
        XCTAssertEqual(titles, ["#490 timed 4", "#490 timed 3"])
    }
}

/// The read seams, answered through `EventRowsPicked.picking` on this actor from `TrappingEvent`s.
actor ReadIsolationProbe: EventRangeReadSource, CalendarListSource {
    private(set) var isolatedReads = 0
    private(set) var titleReads = 0
    private(set) var listCalls = 0
    private(set) var calendarTypes: [EKEntityType?] = []
    private let count: Int?

    /// nil: one timed and one all-day event; a number: that many timed events, an hour apart.
    init(count: Int? = nil) {
        self.count = count
    }

    fileprivate func noteRead(title: Bool) {
        isolatedReads += 1
        if title { titleReads += 1 }
    }

    private func events() -> [TrappingEvent] {
        let start = ISO8601DateFormatter().date(from: "2027-03-01T02:00:00Z")!
        if let count {
            return (0..<count).map { index in
                let at = start.addingTimeInterval(Double(index) * 3600)
                return TrappingEvent(probe: self, event: FakeFormattableEvent(formatTitle: "#490 timed \(index)", formatStartDate: at,
                                                                              formatEndDate: at.addingTimeInterval(1800)))
            }
        }
        return [
            TrappingEvent(probe: self, event: FakeFormattableEvent(formatTitle: "#490 timed", formatStartDate: start,
                                                                   formatEndDate: start.addingTimeInterval(3600))),
            TrappingEvent(probe: self, event: FakeFormattableEvent(formatTitle: "#490 all-day", formatStartDate: start,
                                                                   formatEndDate: start.addingTimeInterval(86_400),
                                                                   formatSourceTimeZone: nil, formatIsAllDay: true))
        ]
    }

    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        listCalls += 1
        return EventRowsPicked.picking(events(), pick)
    }

    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        EventRowsPicked.picking(events(), pick)
    }

    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue] {
        events().map(EventReadValue.init)
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

    private func read<T>(_ value: T, title: Bool = false) -> T {
        probe.preconditionIsolated("an event's property must be read on the actor that owns it")
        probe.assumeIsolated { $0.noteRead(title: title) }
        return value
    }

    var formatID: String? { read(event.formatID) }
    var formatTitle: String? { read(event.formatTitle, title: true) }
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
