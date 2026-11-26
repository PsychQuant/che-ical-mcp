import Foundation
import MCP
import XCTest
@testable import CheICalMCP

private struct FailingCompletionSource: ReminderCompletionSource {
    func completeReminder(identifier: String, completed: Bool) async throws -> ReminderCompletionResult {
        throw ToolError.invalidParameter("save failed")
    }
}

final class ReminderCompletionDispatchTests: XCTestCase {
    func testSaveFailureUsesMCPErrorEnvelope() async throws {
        let server = try await TestServer.make(reminderCompletionSource: FailingCompletionSource())
        let result = await server.handleToolCallForTesting(name: "complete_reminder", arguments: ["reminder_id": .string("r")])
        XCTAssertEqual(result.isError, true)
    }
}
