import XCTest
import MCP
@testable import CheICalMCP

/// Handler-level tests verifying that invalid detail_level and
/// display_timezone values are rejected before reaching EventKit.
final class EventListingParamsHandlerTests: XCTestCase {

    // MARK: - Helpers

    private func makeServer() async throws -> CheICalMCPServer {
        let fake = FakeEventKitManager()
        return try await CheICalMCPServer(reminderCleanupSource: fake)
    }

    private func assertInvalidParameter(
        tool: String,
        arguments: [String: Value],
        messageContains needle: String,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let server = try await makeServer()
        do {
            _ = try await server.executeToolCall(name: tool, arguments: arguments)
            XCTFail("Expected ToolError.invalidParameter for \(tool)", file: file, line: line)
        } catch {
            guard case ToolError.invalidParameter(let msg) = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(msg.contains(needle),
                          "Expected message to contain '\(needle)', got '\(msg)'",
                          file: file, line: line)
        }
    }

    // MARK: - display_timezone rejection (all 3 tools)

    func testListEventsRejectsInvalidDisplayTimezone() async throws {
        try await assertInvalidParameter(
            tool: "list_events",
            arguments: [
                "start_date": .string("2026-01-01"),
                "end_date": .string("2026-01-02"),
                "display_timezone": .string("Fake/Zone")
            ],
            messageContains: "Fake/Zone"
        )
    }

    func testSearchEventsRejectsInvalidDisplayTimezone() async throws {
        try await assertInvalidParameter(
            tool: "search_events",
            arguments: [
                "keyword": .string("test"),
                "display_timezone": .string("Nope/Invalid")
            ],
            messageContains: "Nope/Invalid"
        )
    }

    func testListEventsQuickRejectsInvalidDisplayTimezone() async throws {
        try await assertInvalidParameter(
            tool: "list_events_quick",
            arguments: [
                "range": .string("today"),
                "display_timezone": .string("Not/Real")
            ],
            messageContains: "Not/Real"
        )
    }

    // MARK: - detail_level rejection (all 3 tools)

    func testListEventsRejectsInvalidDetailLevel() async throws {
        try await assertInvalidParameter(
            tool: "list_events",
            arguments: [
                "start_date": .string("2026-01-01"),
                "end_date": .string("2026-01-02"),
                "detail_level": .string("verbose")
            ],
            messageContains: "detail_level"
        )
    }

    func testSearchEventsRejectsInvalidDetailLevel() async throws {
        try await assertInvalidParameter(
            tool: "search_events",
            arguments: [
                "keyword": .string("test"),
                "detail_level": .string("minimal")
            ],
            messageContains: "detail_level"
        )
    }

    func testListEventsQuickRejectsInvalidDetailLevel() async throws {
        try await assertInvalidParameter(
            tool: "list_events_quick",
            arguments: [
                "range": .string("today"),
                "detail_level": .string("brief")
            ],
            messageContains: "detail_level"
        )
    }
}
