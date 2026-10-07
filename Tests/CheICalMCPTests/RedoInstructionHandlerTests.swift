import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #247: `redo` of a record whose redo writes nothing (create, delete, update, move, and a batch
/// of deletes) leaves both stacks as they were, calls nothing on the executor, and answers
/// `success: false` with the instruction. Before, the record moved back to the undo stack and the
/// next undo recreated a deleted item a second time. The executor is a spy, so no EventKit.
private actor SpyExecutor: UndoExecutionSource {
    private(set) var undoCalls = 0
    private(set) var redoCalls = 0

    func executeUndo(_ operation: UndoOperation) async throws -> String {
        undoCalls += 1
        return "Undone"
    }

    func executeRedo(_ operation: UndoOperation) async throws -> String {
        redoCalls += 1
        return "Redone"
    }
}

final class RedoInstructionHandlerTests: XCTestCase {
    private func json(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func testRedoOfARecordWhoseRedoWritesNothingLeavesBothStacks() async throws {
        let event = UndoSnapshotFixtures.event(title: "Standup")
        let reminder = UndoSnapshotFixtures.reminder(title: "Pay rent")
        let operations: [UndoOperation] = [
            .createEvent(id: "e", title: "Standup", created: event),
            .deleteEvent(snapshot: event),
            .updateEvent(id: "e", oldSnapshot: event, saved: event),
            .moveEvent(id: "e", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "Standup", isSeries: false),
            .createReminder(id: "r", title: "Pay rent", created: reminder),
            .deleteReminder(snapshot: reminder),
            .updateReminder(id: "r", oldSnapshot: reminder, saved: reminder),
            .batch([.deleteEvent(snapshot: event), .deleteEvent(snapshot: event)]),
        ]
        for operation in operations {
            let history = CalendarUndoManager()
            await history.record(operation)
            let executor = SpyExecutor()
            let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)
            let undo = try json(await server.handleToolCallForTesting(name: "undo", arguments: [:]))
            XCTAssertEqual(undo["success"] as? Bool, true, operation.description)
            let before = await history.historySnapshot()

            let result = await server.handleToolCallForTesting(name: "redo", arguments: [:])

            let redo = try json(result)
            XCTAssertEqual(redo["action"] as? String, "redo", operation.description)
            XCTAssertEqual(redo["success"] as? Bool, false, operation.description)
            XCTAssertEqual(redo["message"] as? String, operation.redoInstruction, operation.description)
            XCTAssertEqual(redo["redo_available"] as? Int, 1, operation.description)
            XCTAssertEqual(redo["undo_available"] as? Int, 0, operation.description)
            let after = await history.historySnapshot()
            XCTAssertEqual(after.undoCount, before.undoCount, operation.description)
            XCTAssertEqual(after.redoCount, before.redoCount, operation.description)
            let redoCalls = await executor.redoCalls
            XCTAssertEqual(redoCalls, 0, operation.description)

            // The next undo finds nothing to undo instead of recreating the deleted item again.
            let next = try json(await server.handleToolCallForTesting(name: "undo", arguments: [:]))
            XCTAssertEqual(next["success"] as? Bool, false, operation.description)
            let undoCalls = await executor.undoCalls
            XCTAssertEqual(undoCalls, 1, operation.description)
        }
    }

    func testRedoOfACompletionStillWrites() async throws {
        let history = CalendarUndoManager()
        await history.record(.completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                                               title: "Pay rent", redoCompletionDate: nil, wasRecurring: false))
        let executor = SpyExecutor()
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)
        _ = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        let redo = try json(await server.handleToolCallForTesting(name: "redo", arguments: [:]))

        XCTAssertEqual(redo["success"] as? Bool, true)
        XCTAssertEqual(redo["message"] as? String, "Redone")
        let calls = await executor.redoCalls
        XCTAssertEqual(calls, 1)
        let state = await history.historySnapshot()
        XCTAssertEqual(state.undoCount, 1)
        XCTAssertEqual(state.redoCount, 0)
    }
}
