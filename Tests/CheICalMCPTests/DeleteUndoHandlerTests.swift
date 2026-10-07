import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #244: `undo` of a delete-of-following-occurrences marker, alone or in a batch, runs through the
/// real `EventKitManager.executeUndo` arm and is refused before anything writes. The store here is
/// not authorized, so a write that slipped through would fail as calendar-not-found instead (and
/// keep the record) rather than discard it.
final class DeleteUndoHandlerTests: XCTestCase {
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

    private func undo(with history: CalendarUndoManager) async throws -> CallTool.Result {
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))
        return await server.handleToolCallForTesting(name: "undo", arguments: [:])
    }

    /// D2: refused and discarded, so the older record is on top again.
    func testUndoOfAFollowingOccurrencesDeleteWritesNothingAndDiscardsTheRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(.deleteFollowingOccurrences(title: "Standup"))

        let result = try await undo(with: history)

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot undo the delete of the recurring event 'Standup'"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Created event: Older"], "discarded; the older record is on top")
        XCTAssertEqual(after.redoCount, 0, "nothing moved to the redo stack")
    }

    /// D3: the batch is refused in the pre-check, before its restorable member runs. Undo runs the
    /// members newest first, so without the pre-check the whole-event member would run first and
    /// fail on the unauthorized store with a kept record.
    func testABatchWithAFollowingOccurrencesDeleteIsRefusedBeforeItsFirstWrite() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(.batch([.deleteFollowingOccurrences(title: "Standup"),
                                     .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Review"))]))

        let result = try await undo(with: history)

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertTrue(message.contains("Cannot undo this batch"), message)
        XCTAssertTrue(message.contains("none of the batch's events were restored"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Created event: Older"], "discarded; the older record is on top")
        XCTAssertEqual(after.redoCount, 0)
    }
}
