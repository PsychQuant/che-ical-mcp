import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// `update_event` driven through `FakeEventWriteSource` (Helpers/): the response the handler
/// builds from the saved event.
final class EventUpdateHandlerTests: XCTestCase {
    private func update(_ server: CheICalMCPServer, _ args: [String: Value]) async throws -> [String: Any] {
        let raw = try await server.executeToolCall(name: "update_event", arguments: args)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    // MARK: - #268 identifier after the save

    func testUpdateToACalendarInAnotherAccountReportsTheNewIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("e1"), "calendar_name": .string("Work"),
                                               "calendar_source": .string("Other")])
        XCTAssertEqual(result["action"] as? String, "updated")
        XCTAssertEqual(result["id"] as? String, "moved-e1")
        XCTAssertEqual(result["id_changed"] as? Bool, true)
        XCTAssertEqual(result["previous_id"] as? String, "e1")
    }

    func testUpdateThatKeepsTheIdentifierSaysItDidNotChange() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("e1"), "title": .string("Renamed")])
        XCTAssertEqual(result["title"] as? String, "Renamed")
        XCTAssertEqual(result["id"] as? String, "e1")
        XCTAssertEqual(result["id_changed"] as? Bool, false)
        XCTAssertNil(result["previous_id"])
    }

    /// #268 verify: the most common recurring edit (one occurrence, span this) answers the series'
    /// identifier, with the occurrence's own identifier beside it, whatever its shape.
    func testAnOccurrenceEditKeepsTheSeriesIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("series"), "title": .string("Second"),
                                               "occurrence_date": .string("2027-06-14T09:00:00+08:00")])
        XCTAssertEqual(result["id"] as? String, "series")
        XCTAssertEqual(result["id_changed"] as? Bool, false)
        XCTAssertNil(result["previous_id"])
        let occurrence = try XCTUnwrap(result["occurrence_id"] as? String)
        XCTAssertTrue(occurrence.hasPrefix("occurrence-"), occurrence)
    }

    /// Verify round 2: an occurrence edit with a calendar of another account moves the whole series.
    func testAnOccurrenceEditThatMovesTheSeriesReportsTheNewSeriesIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("series"), "calendar_name": .string("Work"),
                                               "calendar_source": .string("Other"),
                                               "occurrence_date": .string("2027-06-14T09:00:00+08:00")])
        XCTAssertEqual(result["id"] as? String, "moved-series")
        XCTAssertEqual(result["id_changed"] as? Bool, true)
        XCTAssertEqual(result["previous_id"] as? String, "series")
        XCTAssertNotNil(result["occurrence_id"] as? String)
    }

    /// span future from a later occurrence: the new series' id, no occurrence_id.
    func testASpanFutureSplitReportsTheNewSeriesIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("series"), "span": .string("future"),
                                               "occurrence_date": .string("2027-06-14T09:00:00+08:00")])
        XCTAssertEqual(result["id"] as? String, "split-series")
        XCTAssertEqual(result["id_changed"] as? Bool, true)
        XCTAssertEqual(result["previous_id"] as? String, "series")
        XCTAssertNil(result["occurrence_id"])
    }

    func testTheRequestCarriesTheCallsFields() async throws {
        let fake = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await update(server, ["event_id": .string("e1"), "calendar_name": .string("Work"),
                                      "calendar_source": .string("Other"), "span": .string("all"),
                                      "occurrence_date": .string("2026-03-28T10:00:00+08:00")])
        let updates = await fake.updates
        let request = try XCTUnwrap(updates.first)
        XCTAssertEqual(request.identifier, "e1")
        XCTAssertEqual(request.calendarName, "Work")
        XCTAssertEqual(request.calendarSource, "Other")
        XCTAssertEqual(request.span, .futureEvents)
        XCTAssertTrue(request.applyToAll)
        XCTAssertNotNil(request.occurrenceDate)
    }

    // MARK: - #372 all-day offset warnings

    func testAnAllDayUpdateWithAnEndWhoseOffsetMovesTheDayWarns() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("e1"), "all_day": .bool(true),
                                               "start_time": .string("2027-04-10"),
                                               "end_time": .string(FakeEventWriteSource.behindHost("2027-04-11", "23:30:00"))])
        let warnings = try XCTUnwrap(result["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0]["field"] as? String, "end_time")
        XCTAssertEqual(warnings[0]["written_day"] as? String, "2027-04-11")
        XCTAssertEqual(warnings[0]["host_day"] as? String, "2027-04-12")
    }

    /// Only `end_time` on an event that is already all-day: the first day is the saved one.
    func testAnEndOnlyUpdateOfAnAllDayEventWarns() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("allday-e1"),
                                               "end_time": .string(FakeEventWriteSource.behindHost("2027-04-11", "23:30:00"))])
        let warnings = try XCTUnwrap(result["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.map { $0["field"] as? String }, ["end_time"])
    }

    func testAStartOnlyUpdateOfAnAllDayEventWarnsOnTheStart() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("allday-e1"),
                                               "start_time": .string(FakeEventWriteSource.behindHost("2027-04-10", "23:30:00"))])
        let warnings = try XCTUnwrap(result["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.map { $0["field"] as? String }, ["start_time"])
        XCTAssertEqual(warnings[0]["host_day"] as? String, "2027-04-11")
    }

    func testAnUpdateThatLeavesTheEventTimedDoesNotWarn() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await update(server, ["event_id": .string("e1"),
                                               "start_time": .string(FakeEventWriteSource.behindHost("2027-04-10", "23:00:00")),
                                               "end_time": .string(FakeEventWriteSource.behindHost("2027-04-10", "23:30:00"))])
        XCTAssertNil(result["warnings"])
    }

    func testAnAllDayUpdateWithoutDatesOrWithoutOffsetsDoesNotWarn() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let titleOnly = try await update(server, ["event_id": .string("allday-e1"), "title": .string("Renamed")])
        XCTAssertNil(titleOnly["warnings"])
        let plain = try await update(server, ["event_id": .string("e1"), "all_day": .bool(true),
                                              "start_time": .string("2027-04-10"), "end_time": .string("2027-04-12")])
        XCTAssertNil(plain["warnings"])
    }
}
