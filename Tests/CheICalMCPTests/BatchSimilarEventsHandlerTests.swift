import MCP
import XCTest
@testable import CheICalMCP

/// #590: `create_events_batch` searches for similar existing events only in the calendar each row was
/// written to. The fake records every search (title and calendar), so the test counts what was read;
/// that `findSimilarEvents` queries only the calendar it is given is pinned on its source
/// (`NoUnrequestedAllCalendarQueryWiringTests`).
private actor CountingSimilarSearches: EventWriteSource {
    struct Search: Hashable { let title: String; let calendar: String }
    private(set) var searches: [Search] = []
    private(set) var excluded: [Set<String>] = []
    private var created = 0

    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        EventWriteValue(eventIdentifier: request.identifier, title: nil, isAllDay: false, startDate: Date(), endDate: Date())
    }

    /// A row whose calendar is `Missing` fails as `createEvent` does; a row titled `duplicate` is
    /// answered as the existing event in its calendar; others are created there. The saved event's
    /// calendar identifier is `cal-<calendar_name>`, and `""` for the calendar `Blank`.
    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        let name = request.calendarName ?? "Default"
        if name == "Missing" { throw EventKitError.calendarNotFound(identifier: name) }
        created += 1
        let duplicate = request.title == "duplicate"
        var event = EventWriteValue(eventIdentifier: duplicate ? "existing-\(name)" : "created-\(created)", title: request.title,
                                    isAllDay: false, startDate: request.startDate, endDate: request.endDate)
        event.calendarIdentifier = name == "Blank" ? "" : "cal-\(name)"
        // A skipped row over a series answers the series' identifier, not the matched event's (#544).
        return EventCreateValue(event: event, isDuplicate: duplicate, existingSeriesIdentifier: duplicate ? "series-\(name)" : nil)
    }

    /// The calendar holds the events this fake created (newest), and one older event per calendar;
    /// the store leaves out `excluding` as `SimilarEvents.select` does.
    func similarEventValues(title: String, calendarIdentifier: String, excluding: Set<String>, limit: Int) async throws -> [SimilarEventValue] {
        searches.append(Search(title: title, calendar: calendarIdentifier))
        excluded.append(excluding)
        let own = (1...max(created, 1)).map { SimilarEventValue(eventIdentifier: "created-\($0)", title: title, calendarTitle: calendarIdentifier,
                                                              startDate: Date(timeIntervalSince1970: 1_900_000_000 + Double($0))) }
        let older = SimilarEventValue(eventIdentifier: "older-\(calendarIdentifier)", title: title + " (older)",
                                      calendarTitle: calendarIdentifier, startDate: Date(timeIntervalSince1970: 1_800_000_000))
        return Array((own + [older]).filter { $0.eventIdentifier.map { !excluding.contains($0) } ?? true }.prefix(limit))
    }

    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { nil }
}

final class BatchSimilarEventsHandlerTests: XCTestCase {
    private func row(_ title: String, calendar: String) -> Value {
        .object(["title": .string(title), "calendar_name": .string(calendar),
                 "start_time": .string("2026-12-07T10:00:00+08:00"), "end_time": .string("2026-12-07T11:00:00+08:00")])
    }

    private func run(_ rows: [Value], on fake: CountingSimilarSearches) async throws -> [String: Any] {
        let server = try await TestServer.make(eventWriteSource: fake)
        let raw = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array(rows)])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    // spec-example: batch-similar-events / what is searched
    func testEachRowIsSearchedInItsOwnCalendarOnceAndAFailedRowNotAtAll() async throws {
        let fake = CountingSimilarSearches()
        let response = try await run([row("Standup", calendar: "A"), row("Standup", calendar: "A"),
                                      row("Standup", calendar: "B"), row("Retro", calendar: "Missing")], on: fake)
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, true, false])
        let searches = await fake.searches
        XCTAssertEqual(searches.count, 2, "one search per distinct title and calendar: \(searches)")
        XCTAssertEqual(Set(searches), [.init(title: "Standup", calendar: "cal-A"), .init(title: "Standup", calendar: "cal-B")])
        XCTAssertFalse(searches.contains { $0.title == "Retro" }, "the failed row has no calendar to search")
        XCTAssertFalse(searches.contains { $0.calendar.isEmpty }, "no search without a calendar")
        let hints = try XCTUnwrap(response["similar_events"] as? [[String: Any]])
        XCTAssertEqual(Set(hints.compactMap { $0["existing_calendar"] as? String }), ["cal-A", "cal-B"])
    }

    /// The batch's own events are left out of the search, so only the older events are listed
    /// (spec: an event a row created or matched is not listed).
    func testTheBatchsOwnEventsAreNotListed() async throws {
        let fake = CountingSimilarSearches()
        let response = try await run([row("Standup", calendar: "A"), row("Standup", calendar: "B")], on: fake)
        let excluded = await fake.excluded
        XCTAssertEqual(excluded.count, 2)
        XCTAssertTrue(excluded.allSatisfy { $0.isSuperset(of: ["created-1", "created-2"]) }, "\(excluded)")
        let hints = try XCTUnwrap(response["similar_events"] as? [[String: Any]])
        XCTAssertEqual(hints.compactMap { $0["existing_title"] as? String }, ["Standup (older)", "Standup (older)"], "\(hints)")
    }

    /// A skipped row's matched event, and the identifier the row answered, are the row's own too:
    /// both are left out.
    func testASkippedRowsMatchIsNotListed() async throws {
        let fake = CountingSimilarSearches()
        let response = try await run([row("duplicate", calendar: "Work")], on: fake)
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["event_id"] as? String, "series-Work")
        let excluded = await fake.excluded
        XCTAssertEqual(excluded, [["existing-Work", "series-Work"]])
    }

    /// A saved event whose calendar identifier is empty is not searched.
    func testAnEmptyCalendarIdentifierIsNotSearched() async throws {
        let fake = CountingSimilarSearches()
        let response = try await run([row("Standup", calendar: "Blank")], on: fake)
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["success"] as? Bool, true)
        let searches = await fake.searches
        XCTAssertEqual(searches, [])
    }

    /// A skipped row is searched in the calendar of the existing event it matched.
    func testASkippedRowIsSearchedInItsDuplicatesCalendar() async throws {
        let fake = CountingSimilarSearches()
        let response = try await run([row("duplicate", calendar: "Work")], on: fake)
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["skipped"] as? Bool, true)
        let searches = await fake.searches
        XCTAssertEqual(searches, [.init(title: "duplicate", calendar: "cal-Work")])
    }

    /// A batch whose every row failed searches nothing and has no `similar_events`.
    func testABatchWithNoWrittenRowSearchesNothing() async throws {
        let fake = CountingSimilarSearches()
        let response = try await run([row("Retro", calendar: "Missing")], on: fake)
        let searches = await fake.searches
        XCTAssertEqual(searches, [])
        XCTAssertNil(response["similar_events"])
    }

    /// A saved event without a calendar identifier is not searched (no calendar to confine it to).
    func testARowWhoseSavedEventHasNoCalendarIsNotSearched() async throws {
        let fake = FakeEventWriteSource()
        let server = try await TestServer.make(eventWriteSource: fake)
        let raw = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array([row("Standup", calendar: "A")])])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["success"] as? Bool, true, "\(rows)")
        XCTAssertNil(response["similar_events_errors"], "\(response)")
        let searched = await fake.similarSearches
        XCTAssertEqual(searched, 0)
    }
}
