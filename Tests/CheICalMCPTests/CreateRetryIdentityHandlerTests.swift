import MCP
import XCTest
@testable import CheICalMCP

/// #578: what the create handlers answer for the refusal over a retitled first occurrence. The fake
/// throws what `EventKitManager.createEvent` throws; which events lead to it is held by the pure
/// tests, the wiring pins and the device cells.
private let refusal = EventKitError.createRetryRetitledFirstOccurrence(seriesId: "6F2A:9B1C", occurrenceId: "6F2A:9B1C/RID=818301600")

private actor RefusingCreates: EventWriteSource {
    private(set) var created: [String] = []
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        EventWriteValue(eventIdentifier: request.identifier, title: nil, isAllDay: false, startDate: Date(), endDate: Date())
    }
    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        if request.title == "retry" { throw refusal }
        created.append(request.title)
        return EventCreateValue(event: EventWriteValue(eventIdentifier: "created-\(created.count)", title: request.title, isAllDay: false,
                                                       startDate: request.startDate, endDate: request.endDate), isDuplicate: false)
    }
    func similarEventValues(title: String, calendarIdentifier: String, excluding: Set<String>, limit: Int) async throws -> [SimilarEventValue] { [] }
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { nil }
}

final class CreateRetryIdentityHandlerTests: XCTestCase {
    private func item(_ title: String) -> Value {
        .object(["title": .string(title), "calendar_name": .string("Work"), "start_time": .string("2026-12-07T10:00:00+08:00"),
                 "end_time": .string("2026-12-07T11:00:00+08:00"),
                 "recurrence": .object(["frequency": .string("weekly"), "occurrence_count": .int(6)])])
    }

    func testCreateEventAnswersTheRefusalNotSkipped() async throws {
        let server = try await TestServer.make(eventWriteSource: RefusingCreates())
        guard case .object(let arguments) = item("retry") else { return XCTFail("item") }
        let result = await server.handleToolCallForTesting(name: "create_event", arguments: arguments)
        XCTAssertEqual(result.isError, true)
        guard case let .text(text, _, _)? = result.content.first else { return XCTFail("no text") }
        XCTAssertEqual(text, "Error: \(try XCTUnwrap(refusal.errorDescription))")
        XCTAssertFalse(text.contains("skipped"), text)
    }

    func testABatchRowAnswersTheRefusalAndTheOtherRowIsCreated() async throws {
        let fake = RefusingCreates()
        let server = try await TestServer.make(eventWriteSource: fake)
        let raw = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array([item("retry"), item("fresh")])])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true])
        XCTAssertEqual(rows[0]["error"] as? String, refusal.errorDescription)
        let created = await fake.created
        XCTAssertEqual(created, ["fresh"])
    }
}
