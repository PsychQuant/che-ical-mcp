import MCP
import XCTest
@testable import CheICalMCP

/// `create_event` and `create_events_batch` driven through `FakeEventWriteSource` (Helpers/).
final class EventCreateHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func create(_ server: CheICalMCPServer, title: String = "Trip", allDay: Bool,
                        start: String, end: String) async throws -> [String: Any] {
        try object(await server.executeToolCall(name: "create_event", arguments: [
            "title": .string(title), "calendar_name": .string("Work"), "all_day": .bool(allDay),
            "start_time": .string(start), "end_time": .string(end)]))
    }

    private var shiftedEnd: String { FakeEventWriteSource.behindHost("2027-04-11", "23:30:00") }

    // MARK: - #372 create_event

    func testAnAllDayCreateWithAnEndWhoseOffsetMovesTheDayWarns() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await create(server, allDay: true, start: "2027-04-10", end: shiftedEnd)
        XCTAssertEqual(result["action"] as? String, "created")
        XCTAssertEqual(result["id"] as? String, "created-1")
        let warnings = try XCTUnwrap(result["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0]["field"] as? String, "end_time")
        XCTAssertEqual(warnings[0]["written_day"] as? String, "2027-04-11")
        XCTAssertEqual(warnings[0]["host_day"] as? String, "2027-04-12")
    }

    /// A duplicate `skipped` answer carries the warning too, so created and skipped stay congruent.
    func testASkippedDuplicateCarriesTheWarning() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await create(server, title: "duplicate", allDay: true, start: "2027-04-10", end: shiftedEnd)
        XCTAssertEqual(result["action"] as? String, "skipped")
        let warnings = try XCTUnwrap(result["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.count, 1)
        try assertSkippedWording(warnings[0])
    }

    /// Verify round 3: on a skipped duplicate the days are the request's, not the existing event's
    /// (whose end differs here), so the message says the request would be written that way and the
    /// existing event was not changed.
    private func assertSkippedWording(_ warning: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(warning["written_day"] as? String, "2027-04-11", file: file, line: line)
        XCTAssertEqual(warning["host_day"] as? String, "2027-04-12", file: file, line: line)
        let message = try XCTUnwrap(warning["message"] as? String, file: file, line: line)
        XCTAssertTrue(message.contains("the request's dates would be written ending on 2027-04-12"), message, file: file, line: line)
        XCTAssertTrue(message.contains("the existing event was not changed"), message, file: file, line: line)
        XCTAssertFalse(message.contains("the event ends on"), message, file: file, line: line)
    }

    func testACreatedEventsWarningSaysTheEventEndsOnTheHostDay() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await create(server, allDay: true, start: "2027-04-10", end: shiftedEnd)
        let message = try XCTUnwrap((result["warnings"] as? [[String: Any]])?.first?["message"] as? String)
        XCTAssertTrue(message.contains("the event ends on 2027-04-12"), message)
        XCTAssertFalse(message.contains("not changed"), message)
    }

    func testATimedCreateDoesNotWarn() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await create(server, allDay: false,
                                      start: FakeEventWriteSource.behindHost("2027-04-11", "22:30:00"), end: shiftedEnd)
        XCTAssertEqual(result["action"] as? String, "created")
        XCTAssertNil(result["warnings"])
    }

    func testAnAllDayCreateWithoutOffsetsDoesNotWarn() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let result = try await create(server, allDay: true, start: "2027-04-10", end: "2027-04-12")
        XCTAssertNil(result["warnings"])
    }

    func testTheCreateRequestCarriesTheCallsFields() async throws {
        let fake = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await create(server, allDay: true, start: "2027-04-10", end: "2027-04-12")
        let creates = await fake.creates
        let request = try XCTUnwrap(creates.first)
        XCTAssertEqual(request.title, "Trip")
        XCTAssertEqual(request.calendarName, "Work")
        XCTAssertTrue(request.isAllDay)
    }

    // MARK: - #372 create_events_batch

    func testBatchItemsCarryTheirOwnWarnings() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        func item(_ title: String, allDay: Bool, end: String) -> Value {
            .object(["title": .string(title), "calendar_name": .string("Work"), "all_day": .bool(allDay),
                     "start_time": .string("2027-04-10"), "end_time": .string(end)])
        }
        let result = try object(await server.executeToolCall(name: "create_events_batch", arguments: [
            "events": .array([item("shifted", allDay: true, end: shiftedEnd),
                              item("plain", allDay: true, end: "2027-04-12"),
                              item("timed", allDay: false, end: shiftedEnd),
                              item("duplicate", allDay: true, end: shiftedEnd)])]))
        let rows = try XCTUnwrap(result["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, true, true, true])
        let warnings = rows.map { ($0["warnings"] as? [[String: Any]])?.map { $0["field"] as? String } }
        XCTAssertEqual(warnings[0], ["end_time"])
        XCTAssertNil(warnings[1])
        XCTAssertNil(warnings[2])
        XCTAssertEqual(warnings[3], ["end_time"])
        XCTAssertEqual(rows[3]["skipped"] as? Bool, true)
        try assertSkippedWording(try XCTUnwrap((rows[3]["warnings"] as? [[String: Any]])?.first))
        let created = try XCTUnwrap((rows[0]["warnings"] as? [[String: Any]])?.first?["message"] as? String)
        XCTAssertFalse(created.contains("not changed"), created)
    }
}
