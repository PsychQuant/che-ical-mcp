import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #247: `redo` of a record whose redo writes nothing (create, delete, update, move, and a batch
/// of deletes) calls nothing on the executor, answers `success: false` with the instruction, and
/// then drops that record from the redo stack (maintainer decision, 2026-10-07); the undo stack is
/// left as it was. Before, the record moved back to the undo stack and the next undo recreated a
/// deleted item a second time. The executor is a spy, so no EventKit.
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

    func testRedoOfARecordWhoseRedoWritesNothingAnswersItsInstructionOnceAndDropsIt() async throws {
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
            let message = try XCTUnwrap(redo["message"] as? String, operation.description)
            XCTAssertTrue(message.hasPrefix(try XCTUnwrap(operation.redoInstruction)), message)
            XCTAssertTrue(message.contains("removed from the redo history"), message)
            // PR #282 round 2, findings 7/11/15: the next redo applies to whatever is now on top,
            // which may be another entry that is only answered, not "the entry beneath it" redone.
            XCTAssertTrue(message.contains("The next redo applies to whatever is now on top of the redo history"), message)
            XCTAssertFalse(message.contains("redoes the entry beneath it"), message)
            XCTAssertEqual(redo["redo_available"] as? Int, 0, operation.description)
            XCTAssertEqual(redo["undo_available"] as? Int, 0, operation.description)
            let after = await history.historySnapshot()
            XCTAssertEqual(after.undoCount, before.undoCount, operation.description)
            XCTAssertEqual(after.redoCount, before.redoCount - 1, operation.description)
            let redoCalls = await executor.redoCalls
            XCTAssertEqual(redoCalls, 0, operation.description)

            // The instruction is answered once: the next redo has nothing left.
            let again = try json(await server.handleToolCallForTesting(name: "redo", arguments: [:]))
            XCTAssertEqual(again["message"] as? String, "Nothing to redo", operation.description)

            // The next undo finds nothing to undo instead of recreating the deleted item again.
            let next = try json(await server.handleToolCallForTesting(name: "undo", arguments: [:]))
            XCTAssertEqual(next["success"] as? Bool, false, operation.description)
            let undoCalls = await executor.undoCalls
            XCTAssertEqual(undoCalls, 1, operation.description)
        }
    }

    /// The record beneath a dropped one is reached on the next redo, and a redo that writes still
    /// moves its record to the undo stack.
    func testTheRecordBeneathADroppedOneIsRedoneNext() async throws {
        let history = CalendarUndoManager()
        await history.record(.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Standup")))
        await history.record(.completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                                               title: "Pay rent", redoCompletionDate: nil, wasRecurring: false))
        let executor = SpyExecutor()
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)
        _ = await server.handleToolCallForTesting(name: "undo", arguments: [:])   // the completion
        _ = await server.handleToolCallForTesting(name: "undo", arguments: [:])   // the delete, now on top of redo

        let first = try json(await server.handleToolCallForTesting(name: "redo", arguments: [:]))
        XCTAssertEqual(first["success"] as? Bool, false)
        XCTAssertEqual(first["redo_available"] as? Int, 1)
        XCTAssertEqual(first["undo_available"] as? Int, 0)

        let second = try json(await server.handleToolCallForTesting(name: "redo", arguments: [:]))

        XCTAssertEqual(second["success"] as? Bool, true)
        XCTAssertEqual(second["message"] as? String, "Redone")
        let calls = await executor.redoCalls
        XCTAssertEqual(calls, 1, "only the completion was executed")
        let state = await history.historySnapshot()
        XCTAssertEqual(state.undoCount, 1, "the redone completion moved to the undo stack")
        XCTAssertEqual(state.redoCount, 0)
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

    /// PR #282 round 1, finding 24: "Nothing to redo" carries the same counts as a redo that writes
    /// nothing, so a client reading them after any `success: false` redo finds them.
    func testNothingToRedoReportsTheCountsToo() async throws {
        let history = CalendarUndoManager()
        await history.record(.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Standup")))
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: SpyExecutor())

        let redo = try json(await server.handleToolCallForTesting(name: "redo", arguments: [:]))

        XCTAssertEqual(redo["success"] as? Bool, false)
        XCTAssertEqual(redo["message"] as? String, "Nothing to redo")
        XCTAssertEqual(redo["undo_available"] as? Int, 1)
        XCTAssertEqual(redo["redo_available"] as? Int, 0)
    }
}
