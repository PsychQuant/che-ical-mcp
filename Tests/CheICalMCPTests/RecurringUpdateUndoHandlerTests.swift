import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #236: `undo` of a recurring-update marker runs through the real `EventKitManager.executeUndo`
/// arm and is refused before it touches the store: the store here is not authorized, so any lookup
/// would fail as not found instead. The record is discarded and the older one is reachable.
final class RecurringUpdateUndoHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType) async throws -> Bool { false }
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return ""
        }
        return text
    }

    func testUndoOfARecurringUpdateWritesNothingAndDiscardsTheRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(.updateRecurringEvent(id: "series/RID=1", title: "Standup", kind: .occurrence))
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))

        let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot undo the update of the recurring event 'Standup'"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Created event: Older"], "discarded; the older record is on top")
        XCTAssertEqual(after.redoCount, 0, "nothing moved to the redo stack")
    }
}
