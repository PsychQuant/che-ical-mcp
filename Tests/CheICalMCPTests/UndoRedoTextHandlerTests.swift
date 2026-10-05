import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #236, PR #259 round 6 findings 14, 23: the message-only redo arms echo the title like the undo
/// errors. Driven through the `redo` handler and the real `EventKitManager` arms, which return
/// their instruction without touching the store (the store here is not authorized).
final class UndoRedoTextHandlerTests: XCTestCase {
    private final class DeniedProbe: AuthorizationStatusSource {
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { .denied }
        func requestFullAccess(for: EKEntityType) async throws -> Bool { false }
    }

    private func redoText(of operation: UndoOperation) async throws -> String {
        let history = CalendarUndoManager()
        await history.record(operation)
        let undone = try await history.beginUndo()
        await history.finishHistoryOperation(try XCTUnwrap(undone))   // as after a successful undo
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))
        let result = await server.handleToolCallForTesting(name: "redo", arguments: [:])
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else { return "" }
        return text
    }

    func testRedoInstructionsShowTitlesLikeTheErrors() async throws {
        let title = "Stand\u{202E}up\u{200B} 'x'"
        let event = UndoSnapshotFixtures.event(title: title)
        let reminder = UndoSnapshotFixtures.reminder(title: title)
        let ops: [UndoOperation] = [
            .createEvent(id: "e", title: title, created: event),
            .deleteEvent(snapshot: event),
            .moveEvent(id: "e", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: title, isSeries: false),
            .createReminder(id: "r", title: title, created: reminder),
            .deleteReminder(snapshot: reminder),
            .updateRecurringEvent(id: "e", title: title, kind: .series),
        ]
        for op in ops {
            let text = try await redoText(of: op)
            XCTAssertTrue(text.contains("Standup 'x'") || text.contains("Standup \\'x\\'"), "\(op.description): \(text)")
            XCTAssertFalse(text.unicodeScalars.contains { [0x202E, 0x200B].contains($0.value) }, text)
        }
    }
}
