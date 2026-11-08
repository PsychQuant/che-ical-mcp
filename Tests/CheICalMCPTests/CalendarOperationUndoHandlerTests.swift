import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #273: `undo` of a calendar-operation marker runs through the real `EventKitManager.executeUndo`
/// arm and is refused before it touches the store: the store here is not authorized, so a lookup
/// or write that slipped through would fail with an access error instead (and keep the record).
/// The record is discarded and the older record is on top again, so the issue's sequence
/// (update_event, then delete_calendar, then undo) no longer reverts the update in the delete's place.
final class CalendarOperationUndoHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool { false }
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return ""
        }
        return text
    }

    func testEachCalendarOperationIsRefusedAndDiscardedSoTheOlderRecordIsReachable() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(.calendarOperation(kind: .created, title: "Scratch"))
        await history.record(.calendarOperation(kind: .updated, title: "Scratch"))
        await history.record(.calendarOperation(kind: .deleted, title: "Scratch"))
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))

        let steps: [(prefix: String, remaining: [String])] = [
            ("Cannot undo the deletion of a calendar",
             ["Updated calendar: Scratch (undo not available)", "Created calendar: Scratch (undo not available)", "Created event: Older"]),
            ("Cannot undo the update of a calendar",
             ["Created calendar: Scratch (undo not available)", "Created event: Older"]),
            ("Cannot undo the creation of a calendar",
             ["Created event: Older"]),
        ]
        for step in steps {
            let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])
            XCTAssertEqual(result.isError, true)
            let message = try text(result)
            XCTAssertTrue(message.contains(step.prefix), message)
            XCTAssertFalse(message.contains("Scratch"), "the error does not name the calendar: \(message)")
            let after = await history.historySnapshot()
            XCTAssertEqual(after.entries.map(\.description), step.remaining, "discarded; the older record is on top")
            XCTAssertEqual(after.redoCount, 0, "nothing moved to the redo stack")
        }
    }

    /// #247: the redo arm writes nothing for the marker (its undo never succeeds, so it never
    /// reaches the redo stack; this is the fallback `executeRedo` keeps for it).
    func testRedoOfTheMarkerWritesNothing() async throws {
        let manager = EventKitManager.forTesting(probe: DeniedProbe())
        for kind in [CalendarOperationKind.created, .updated, .deleted] {
            let op = UndoOperation.calendarOperation(kind: kind, title: "Scratch")
            let answer = try await manager.executeRedo(op)
            XCTAssertEqual(answer, op.redoInstruction, "\(kind)")
        }
    }
}
