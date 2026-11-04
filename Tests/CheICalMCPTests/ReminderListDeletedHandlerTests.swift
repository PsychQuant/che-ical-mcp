import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #281: the undo of `delete_reminder` recreates the reminder through `saveNewReminder`. When the
/// save returns but its list was deleted elsewhere in the meantime, nothing is written and
/// `NewObjectSave.ListDeletedDuringSave` is thrown. Through the `undo` handler the client gets that
/// text (it is trusted, not `error_unknown`) and the record stays on top under the same id, so the
/// next undo can report the list as unavailable and the user can give the entry up. The executor
/// is a fake, so no EventKit and no TCC prompt.
private actor ListDeletedExecutor: UndoExecutionSource {
    private(set) var undoCalls = 0

    func executeUndo(_ operation: UndoOperation) async throws -> String {
        undoCalls += 1
        throw NewObjectSave.ListDeletedDuringSave(restoring: true)
    }

    func executeRedo(_ operation: UndoOperation) async throws -> String {
        XCTFail("redo not expected")
        return ""
    }
}

/// `createReminder` as it ends when its save returned into a list deleted in the meantime: the
/// check throws before any result or undo entry exists. Titles other than "gone" are created.
private actor ListDeletedWriter: ReminderWriteSource {
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        if request.title == "gone" { throw NewObjectSave.ListDeletedDuringSave(restoring: false) }
        return .init(reminder: ReminderWriteSnapshot(id: "saved-" + request.title, title: request.title, notes: nil),
                     isDuplicate: false, storeDiffers: [], duplicateHasTime: false)
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        throw NewObjectSave.ListDeletedDuringSave(restoring: false)
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: nil)
    }
}

final class ReminderListDeletedHandlerTests: XCTestCase {
    private let createMessage = "The reminder list was deleted while the reminder was being saved; nothing was created."
    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return ""
        }
        return text
    }

    func testADeleteUndoWhoseListWasDeletedDuringTheSaveKeepsItsRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(.deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent")))
        let before = await history.historySnapshot()
        let executor = ListDeletedExecutor()
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)

        let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains(NewObjectSave.ListDeletedDuringSave(restoring: true).errorDescription ?? "-"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id), "the record stays on top, same id")
        XCTAssertEqual(after.redoCount, 0, "nothing moved to the redo stack")
        let calls = await executor.undoCalls
        XCTAssertEqual(calls, 1)
    }

    /// `create_reminder` fails with the message, not an identifier.
    func testCreateReminderReportsTheListDeletedErrorVerbatim() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: ListDeletedWriter())

        let result = await server.handleToolCallForTesting(name: "create_reminder", arguments: ["title": .string("gone"), "calendar_name": .string("L")])

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains(createMessage), message)
        XCTAssertFalse(message.contains("saved-"), message)
    }

    /// `create_reminders_batch` reports the error on that item only; the others are created.
    func testCreateRemindersBatchReportsTheListDeletedErrorOnThatItem() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: ListDeletedWriter())

        let raw = try await server.executeToolCall(name: "create_reminders_batch", arguments: [
            "reminders": .array([.object(["title": .string("kept"), "calendar_name": .string("L")]),
                                 .object(["title": .string("gone"), "calendar_name": .string("L")])]),
        ])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2, raw)
        XCTAssertEqual(results[0]["success"] as? Bool, true, raw)
        XCTAssertEqual(results[1]["success"] as? Bool, false, raw)
        XCTAssertEqual(results[1]["error"] as? String, createMessage, raw)
    }
}
