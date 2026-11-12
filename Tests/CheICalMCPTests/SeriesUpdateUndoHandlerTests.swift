import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #263: `undo`, `undo_history` and `redo` on the record of a restorable whole-series update, through
/// the real handlers and `EventKitManager.executeUndo`. The store is not authorized, so the undo stops
/// at the access check of the #236 guard: unlike the recurring-update marker, the record is not
/// discarded, because it is restorable once the series can be read.
final class SeriesUpdateUndoHandlerTests: XCTestCase {
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

    private func record() -> UndoOperation {
        let exceptions = SeriesExceptions(window: DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 86_400 * 30),
                                          keptSlots: [], detached: [])
        return .updateSeries(SeriesUpdateRecord(
            id: "S", externalIdentifier: "X-S", old: UndoSnapshotFixtures.event(title: "Before", weeklyOccurrences: 3),
            saved: UndoSnapshotFixtures.event(title: "After", weeklyOccurrences: 3), fields: ["title"],
            before: exceptions, after: exceptions))
    }

    func testTheRecordIsListedAsRestorable() async throws {
        let history = CalendarUndoManager()
        await history.record(record())
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))

        let result = await server.handleToolCallForTesting(name: "undo_history", arguments: [:])

        XCTAssertNotEqual(result.isError, true)
        let listed = try text(result)
        XCTAssertTrue(listed.contains("Updated recurring event: Before (whole series; undo restores its title)"), listed)
    }

    func testAnUndoThatCannotReadTheSeriesKeepsTheRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(.createEvent(id: "older", title: "Older", created: UndoSnapshotFixtures.event(title: "Older")))
        await history.record(record())
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))

        let result = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        XCTAssertEqual(result.isError, true)
        let message = try text(result)
        XCTAssertFalse(message.contains("Cannot undo the update of the recurring event 'Before': it changed the whole series"), message)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description),
                       ["Updated recurring event: Before (whole series; undo restores its title)", "Created event: Older"],
                       "kept on top for a retry, not discarded as the marker is")
        XCTAssertEqual(after.redoCount, 0)
    }

    /// keep_later_edits merges only one-off updates; this record undoes as without it.
    func testKeepLaterEditsUndoesAsWithoutIt() async throws {
        let history = CalendarUndoManager()
        await history.record(record())
        let server = try await CheICalMCPServer(undoManager: history,
                                                undoExecutionSource: EventKitManager.forTesting(probe: DeniedProbe()))

        let result = await server.handleToolCallForTesting(name: "undo", arguments: ["keep_later_edits": .bool(true)])

        XCTAssertEqual(result.isError, true)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.count, 1, "kept")
    }
}
