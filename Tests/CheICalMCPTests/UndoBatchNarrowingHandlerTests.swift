import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #248 A: when a batch undo fails after some members were written, `undo` puts back a record of
/// only the members not yet restored, under the same id, and the client gets the partial message
/// verbatim. A retry that succeeds then restores only those. The executor is scripted, so no
/// EventKit and no TCC prompt.
private actor PartiallyFailingExecutor: UndoExecutionSource {
    private(set) var received: [UndoOperation] = []
    private let firstFailure: UndoBatchPartiallyUndoneError

    init(firstFailure: UndoBatchPartiallyUndoneError) {
        self.firstFailure = firstFailure
    }

    func executeUndo(_ operation: UndoOperation) async throws -> String {
        received.append(operation)
        if received.count == 1 { throw firstFailure }
        guard case .batch(let members) = operation else { return "Undone" }
        return "Undone batch (\(members.count) operations)"
    }

    func executeRedo(_ operation: UndoOperation) async throws -> String { "Redone" }
}

final class UndoBatchNarrowingHandlerTests: XCTestCase {
    private func deleted(_ title: String) -> UndoOperation {
        .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: title))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return ""
        }
        return text
    }

    func testAPartialFailureKeepsTheRemainingMembersUnderTheSameId() async throws {
        let history = CalendarUndoManager()
        await history.record(deleted("Older"))
        await history.record(.batch(["A", "B", "C", "D"].map(deleted)))
        let before = await history.historySnapshot()
        let executor = PartiallyFailingExecutor(firstFailure: UndoBatchPartiallyUndoneError(
            remaining: [deleted("A"), deleted("B")], restoredCount: 2, memberError: "eventkit_error_1"))
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)

        let failed = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        XCTAssertEqual(failed.isError, true)
        let message = try text(failed)
        XCTAssertTrue(message.contains("2 items not yet restored") && message.contains("eventkit_error_1"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id), "the narrowed record keeps its id")
        XCTAssertEqual(after.entries.first?.description, "Batch (2 operations)")
        XCTAssertEqual(after.redoCount, 0)

        // The retry gets only the members not yet restored, and then the record is consumed.
        let retry = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        let retryText = try text(retry)
        XCTAssertNotEqual(retry.isError, true, retryText)
        let received = await executor.received
        XCTAssertEqual(received.count, 2)
        guard case .batch(let members)? = received.last else { return XCTFail("expected a batch") }
        XCTAssertEqual(members.map(\.description), ["Deleted event: A", "Deleted event: B"])
        let done = await history.historySnapshot()
        XCTAssertEqual(done.entries.map(\.description), ["Deleted event: Older"])
        XCTAssertEqual(done.redoCount, 1)
    }
}
