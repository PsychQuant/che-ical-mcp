import MCP
import XCTest
@testable import CheICalMCP

/// #544: what the create handlers answer for a skipped retry whose match was an occurrence edited on
/// its own. The fake hands back what `EventKitManager.createEvent` returns then: the matched
/// occurrence, and the identifier of the series the retry was checked against. These tests show
/// only that the handlers answer that identifier; which series is checked is held by
/// `ExclusionRetryTargetTests`, `ExclusionRetryTargetWiringTests` and the device cells.
private let seriesID = "6F2A:9B1C"
private let occurrenceID = "6F2A:9B1C/RID=811648800"

private actor SkippingWrites: EventWriteSource {
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        EventWriteValue(eventIdentifier: request.identifier, title: nil, isAllDay: false, startDate: Date(), endDate: Date())
    }
    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        let matched = EventWriteValue(eventIdentifier: request.title == "one-off" ? "ONE" : occurrenceID, title: request.title,
                                      isAllDay: false, startDate: request.startDate, endDate: request.endDate)
        return EventCreateValue(event: matched, isDuplicate: true,
                                existingSeriesIdentifier: request.title == "one-off" ? nil : seriesID)
    }
    func similarEventValues(title: String, calendarIdentifier: String, limit: Int) async throws -> [SimilarEventValue] { [] }
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { nil }
}

final class ExclusionRetryTargetHandlerTests: XCTestCase {
    private func item(_ title: String) -> Value {
        .object(["title": .string(title), "calendar_name": .string("Work"), "start_time": .string("2026-09-07T10:00:00+08:00"),
                 "end_time": .string("2026-09-07T11:00:00+08:00"),
                 "recurrence": .object(["frequency": .string("weekly"), "occurrence_count": .int(5),
                                        "excluded_occurrence_dates": .array([.string("2026-09-21")])])])
    }

    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testCreateEventAnswersTheSeriesIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: SkippingWrites())
        guard case .object(let arguments) = item("retry") else { return XCTFail("item") }
        let answer = try object(try await server.executeToolCall(name: "create_event", arguments: arguments))
        XCTAssertEqual(answer["action"] as? String, "skipped")
        XCTAssertEqual(answer["id"] as? String, seriesID)
    }

    func testABatchRowAnswersTheSeriesIdentifier() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: SkippingWrites())
        let raw = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array([item("retry"), item("one-off")])])
        let rows = try XCTUnwrap(try object(raw)["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["event_id"] as? String }, [seriesID, "ONE"])
        XCTAssertEqual(rows.map { $0["skipped"] as? Bool }, [true, true])
    }

    /// Without a series identifier the answer is the matched event's, as before.
    func testWithoutASeriesIdentifierTheMatchIsAnswered() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: SkippingWrites())
        guard case .object(let arguments) = item("one-off") else { return XCTFail("item") }
        let answer = try object(try await server.executeToolCall(name: "create_event", arguments: arguments))
        XCTAssertEqual(answer["id"] as? String, "ONE")
    }
}
