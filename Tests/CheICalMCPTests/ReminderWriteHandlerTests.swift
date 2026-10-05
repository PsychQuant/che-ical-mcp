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
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        let touchedDue = request.dueDate != nil || request.clearDueDate || request.realignToDue
        let sync = request.clearDueDate
            ? ReminderDateSync.Report(startDate: .cleared, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 1)
            : ReminderDateSync.Report(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0, aligned: request.realignToDue)
        return ReminderUpdateResult(
            reminder: ReminderWriteSnapshot(id: request.identifier, title: request.title ?? "Saved", notes: request.notes),
            dateSync: touchedDue ? sync : nil)
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
    // #227: the response says what moved with the due date.
    func testUpdateResponseReportsDateSyncWhenTheDueDateMoves() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-08T10:00:00+08:00")]))
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["start_date"] as? String, "shifted")
        XCTAssertEqual(sync["absolute_alarms_shifted"] as? Int, 1)
        XCTAssertEqual(sync["absolute_alarms_removed"] as? Int, 0)
    }
    func testUpdateResponseReportsRemovedAlarmsWhenTheDueDateIsCleared() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "clear_due_date": .bool(true)]))
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["start_date"] as? String, "cleared")
        XCTAssertEqual(sync["absolute_alarms_removed"] as? Int, 1)
    }
    func testUpdateResponseOmitsDateSyncWhenTheDueDateIsUntouched() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "title": .string("Renamed")]))
        XCTAssertNil(result["date_sync"])
    }
    // #235: realign_to_due puts the start date and absolute alarms onto the due date.
    func testRealignToDueIsPassedThroughWithTheDueDate() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-08T10:00:00+08:00"), "realign_to_due": .bool(true)]))
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.realignToDue, true)
        XCTAssertNotNil(requests.first?.dueDate)
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["aligned"] as? Bool, true)
    }
    func testRealignToDueAloneReportsDateSync() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "realign_to_due": .bool(true)]))
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.realignToDue, true)
        XCTAssertNil(requests.first?.dueDate)
        XCTAssertNotNil(result["date_sync"] as? [String: Any])
    }
    func testRealignToDueIsOffByDefault() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-08T10:00:00+08:00")]))
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.realignToDue, false)
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["aligned"] as? Bool, false)
    }
    func testRealignToDueWithClearDueDateIsRejectedBeforeAnyWrite() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        do {
            _ = try await server.executeToolCall(name: "update_reminder", arguments: [
                "reminder_id": .string("r"), "clear_due_date": .bool(true), "realign_to_due": .bool(true)])
            XCTFail("realign_to_due with clear_due_date must be rejected")
        } catch let error as ToolError {
            XCTAssertTrue("\(error)".contains("realign_to_due"), "\(error)")
        }
        let requests = await fake.updated
        XCTAssertTrue(requests.isEmpty)
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
