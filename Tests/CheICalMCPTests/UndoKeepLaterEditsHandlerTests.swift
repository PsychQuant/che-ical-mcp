import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #265: `undo` with `keep_later_edits`. The executor is scripted; this checks that the handler
/// validates the argument and routes it, and that without it nothing changes. No EventKit.
private actor KeepLaterEditsExecutor: UndoExecutionSource {
    private(set) var calls: [String] = []

    func executeUndo(_ operation: UndoOperation) async throws -> String {
        calls.append("plain")
        return "Undone: plain"
    }

    func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String {
        calls.append("restoreAvailable=\(restoreAvailable)")
        return "Undone: plain"
    }

    func executeUndoKeepingLaterEdits(_ operation: UndoOperation) async throws -> String {
        calls.append("keepLaterEdits")
        return "Undone: merged"
    }

    func executeRedo(_ operation: UndoOperation) async throws -> String { "Redone" }
}

final class UndoKeepLaterEditsHandlerTests: XCTestCase {
    private func update() -> UndoOperation {
        .updateEvent(id: "x", oldSnapshot: UndoSnapshotFixtures.event(title: "Old"), saved: UndoSnapshotFixtures.event(title: "New"))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else { return "" }
        return text
    }

    private func setUp() async throws -> (CalendarUndoManager, KeepLaterEditsExecutor, CheICalMCPServer) {
        let history = CalendarUndoManager()
        await history.record(update())
        let executor = KeepLaterEditsExecutor()
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)
        return (history, executor, server)
    }

    func testTheFlagRoutesToTheMergeAndConsumesTheRecord() async throws {
        let (history, executor, server) = try await setUp()
        let result = await server.handleToolCallForTesting(name: "undo", arguments: ["keep_later_edits": .bool(true)])
        XCTAssertNotEqual(result.isError, true)
        XCTAssertTrue(try text(result).contains("Undone: merged"))
        let calls = await executor.calls
        XCTAssertEqual(calls, ["keepLaterEdits"])
        let after = await history.historySnapshot()
        XCTAssertEqual(after.undoCount, 0)
    }

    func testWithoutTheFlagTheUndoIsTheSameAsBefore() async throws {
        for arguments: [String: Value] in [[:], ["keep_later_edits": .bool(false)]] {
            let (_, executor, server) = try await setUp()
            _ = await server.handleToolCallForTesting(name: "undo", arguments: arguments)
            let calls = await executor.calls
            XCTAssertEqual(calls, ["restoreAvailable=false"], "\(arguments)")
        }
    }

    func testANonBooleanFlagIsRefusedAndNothingChanges() async throws {
        let (history, executor, server) = try await setUp()
        let result = await server.handleToolCallForTesting(name: "undo", arguments: ["keep_later_edits": .string("yes")])
        XCTAssertEqual(result.isError, true)
        let calls = await executor.calls
        XCTAssertEqual(calls, [])
        let after = await history.historySnapshot()
        XCTAssertEqual(after.undoCount, 1)
    }

    func testTheFlagCannotJoinDiscardIdOrRestoreAvailable() async throws {
        let (history, executor, server) = try await setUp()
        let before = await history.historySnapshot()
        let id = try XCTUnwrap(before.entries.first?.id)
        for arguments: [String: Value] in [["keep_later_edits": .bool(true), "discard_id": .string(id)],
                                           ["keep_later_edits": .bool(true), "restore_available": .bool(true)]] {
            let result = await server.handleToolCallForTesting(name: "undo", arguments: arguments)
            XCTAssertEqual(result.isError, true, "\(arguments)")
            let message = try text(result)
            XCTAssertTrue(message.contains("keep_later_edits cannot be combined with"), message)
        }
        let calls = await executor.calls
        XCTAssertEqual(calls, [])
        let after = await history.historySnapshot()
        XCTAssertEqual(after.undoCount, 1, "nothing was discarded or undone")
    }
}
