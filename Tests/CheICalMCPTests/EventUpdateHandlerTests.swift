import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// `update_event` driven through an `EventWriteSource` fake: the response the handler builds from
/// the saved event.
private actor UpdateFake: EventWriteSource {
    private(set) var updates: [EventUpdateRequest] = []

    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        updates.append(request)
        // #268: a move to a calendar in another account ("Other") comes back with a new identifier.
        let id = request.calendarSource == "Other" ? "moved-" + request.identifier : request.identifier
        let start = request.startDate ?? Date(timeIntervalSince1970: 1_800_000_000)
        return EventWriteValue(eventIdentifier: id, title: request.title ?? "Saved",
                               isAllDay: request.isAllDay ?? false,
                               startDate: start, endDate: request.endDate ?? start.addingTimeInterval(3600))
    }
}

final class EventUpdateHandlerTests: XCTestCase {
    private func update(_ server: CheICalMCPServer, _ args: [String: Value]) async throws -> [String: Any] {
        let raw = try await server.executeToolCall(name: "update_event", arguments: args)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    // MARK: - #268 identifier after the save

    func testUpdateToACalendarInAnotherAccountReportsTheNewIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: UpdateFake())
        let result = try await update(server, ["event_id": .string("e1"), "calendar_name": .string("Work"),
                                               "calendar_source": .string("Other")])
        XCTAssertEqual(result["action"] as? String, "updated")
        XCTAssertEqual(result["id"] as? String, "moved-e1")
        XCTAssertEqual(result["id_changed"] as? Bool, true)
        XCTAssertEqual(result["previous_id"] as? String, "e1")
    }

    func testUpdateThatKeepsTheIdentifierSaysItDidNotChange() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: UpdateFake())
        let result = try await update(server, ["event_id": .string("e1"), "title": .string("Renamed")])
        XCTAssertEqual(result["title"] as? String, "Renamed")
        XCTAssertEqual(result["id"] as? String, "e1")
        XCTAssertEqual(result["id_changed"] as? Bool, false)
        XCTAssertNil(result["previous_id"])
    }

    func testTheRequestCarriesTheCallsFields() async throws {
        let fake = UpdateFake()
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
}
