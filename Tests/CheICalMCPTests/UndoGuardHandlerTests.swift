import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #236: when the post-state guard refuses, the `undo` / `redo` handlers keep the record (D2) and
/// the client gets the refusal message verbatim, not `error_unknown`. The executor is a fake, so
/// no EventKit and no TCC prompt.
private actor RefusingExecutor: UndoExecutionSource {
    private(set) var undoCalls = 0
    private(set) var redoCalls = 0

    func executeUndo(_ operation: UndoOperation) async throws -> String {
        undoCalls += 1
        throw UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup", changedFields: ["title", "start_time"])
    }

    func executeRedo(_ operation: UndoOperation) async throws -> String {
        redoCalls += 1
        throw UndoTargetChangedError(verb: .redo, kind: .reminder, title: "Pay rent", changedFields: ["completed"])
    }
}

final class UndoGuardHandlerTests: XCTestCase {
    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return ""
        }
        return text
    }

    private func update(_ title: String) -> UndoOperation {
        .updateEvent(id: title, oldSnapshot: UndoSnapshotFixtures.event(title: title),
                     saved: UndoSnapshotFixtures.event(title: title))
    }

    func testUndoRefusalReachesTheClientAndKeepsTheRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(update("Older"))
        await history.record(update("Standup"))
        let before = await history.historySnapshot()
        let executor = RefusingExecutor()
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)

        let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot undo: the event 'Standup' was changed after this operation") && message.contains("(title, start_time)"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id), "the refused record stays on top, same id")
        XCTAssertEqual(after.redoCount, 0)
        let calls = await executor.undoCalls
        XCTAssertEqual(calls, 1)

        // The escape hatch the message names drops exactly that record.
        let top = try XCTUnwrap(after.entries.first?.id)
        _ = try await server.executeToolCall(name: "undo", arguments: ["discard_id": .string(top)])
        let remaining = await history.historySnapshot()
        XCTAssertEqual(remaining.entries.map(\.description), ["Updated event: Older"])
    }

    func testRedoRefusalKeepsTheRedoRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(.completeReminder(id: "r", wasCompleted: false, requestedCompleted: true,
                                               completionDate: nil, title: "Pay rent", redoCompletionDate: nil))
        let undone = try await history.beginUndo()
        await history.finishHistoryOperation(try XCTUnwrap(undone))   // as after a successful undo
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: RefusingExecutor())

        let result = await server.handleToolCallForTesting(name: "redo", arguments: [:])

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot redo: the reminder 'Pay rent' was changed after the undo") && message.contains("(completed)"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.redoCount, 1, "the refused redo record is kept")
        XCTAssertEqual(after.undoCount, 0)
    }
}
