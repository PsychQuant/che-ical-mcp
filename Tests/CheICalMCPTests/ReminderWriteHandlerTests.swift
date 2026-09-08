import MCP
import XCTest
@testable import CheICalMCP

private actor WriteFake: ReminderWriteSource {
    var created: [ReminderCreateRequest] = []
    var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        created.append(request)
        return .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: request.notes), isDuplicate: request.title == "duplicate")
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderWriteSnapshot {
        updated.append(request)
        return ReminderWriteSnapshot(id: request.identifier, title: request.title ?? "Saved", notes: request.notes)
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: "original\n#old")
    }
}
final class ReminderWriteHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    func testNormalAndDuplicateCreateResponses() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        for (title, action) in [("new", "created"), ("duplicate", "skipped")] {
            let result = try object(await server.executeToolCall(name: "create_reminder", arguments: ["title": .string(title), "tags": .array([.string("tag")])]))
            XCTAssertEqual(result["action"] as? String, action)
            XCTAssertEqual(result["id"] as? String, "saved")
        }
        let requests = await fake.created
        XCTAssertEqual(requests.first?.notes, "#tag")
    }
    func testUpdateNotesPreservesTagsAndClearTagsPreservesBody() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "notes": .string("replacement")])
        _ = try await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "clear_tags": .bool(true)])
        let requests = await fake.updated
        XCTAssertEqual(requests[0].notes, "replacement\n#old")
        XCTAssertEqual(requests[1].notes, "original")
    }
    func testBatchCountsDuplicateAndInvalidRows() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: ["reminders": .array([.object(["title": .string("new")]), .object(["title": .string("duplicate")]), .object([:])])]))
        XCTAssertEqual(result["total"] as? Int, 3)
        XCTAssertEqual(result["succeeded"] as? Int, 1)
        XCTAssertEqual(result["failed"] as? Int, 1)
        XCTAssertEqual(result["skipped"] as? Int, 1)
    }
}
