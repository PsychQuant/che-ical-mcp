import XCTest
@testable import CheICalMCP

/// #247: which records a redo writes for (`redoInstruction` / `redoWrites`), and what
/// `CalendarUndoManager.beginRedo` does with a record whose redo writes nothing: neither stack
/// moves. Pure apart from building snapshots in memory, so no TCC prompt.
final class UndoRedoClassificationTests: XCTestCase {
    private let event = UndoSnapshotFixtures.event(title: "Standup")
    private let reminder = UndoSnapshotFixtures.reminder(title: "Pay rent")

    private var completion: UndoOperation {
        .completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                          title: "Pay rent", redoCompletionDate: nil, wasRecurring: false)
    }

    /// Every record kind whose redo used to return an instruction and write nothing.
    private var instructionOnly: [UndoOperation] {
        [
            .createEvent(id: "EVT-1", title: "Standup", created: event),
            .deleteEvent(snapshot: event),
            .updateEvent(id: "EVT-1", oldSnapshot: event, saved: event),
            .updateRecurringEvent(id: "EVT-1", title: "Standup", kind: .series),
            .moveEvent(id: "EVT-1", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "Standup", isSeries: false),
            .createReminder(id: "REM-1", title: "Pay rent", created: reminder),
            .deleteReminder(snapshot: reminder),
            .updateReminder(id: "REM-1", oldSnapshot: reminder, saved: reminder),
        ]
    }

    func testOnlyCompletionRecordsWriteOnRedo() {
        for operation in instructionOnly {
            XCTAssertFalse(operation.redoWrites, operation.description)
            XCTAssertNotNil(operation.redoInstruction, operation.description)
        }
        XCTAssertTrue(completion.redoWrites)
        XCTAssertNil(completion.redoInstruction)
    }

    /// The batch path the issue did not list: a batch of deletes answered "Redone batch" for a
    /// no-op. A batch writes on redo only when every member does.
    func testBatchWritesOnRedoOnlyWhenEveryMemberDoes() {
        XCTAssertFalse(UndoOperation.batch([.deleteEvent(snapshot: event), .deleteEvent(snapshot: event)]).redoWrites)
        XCTAssertFalse(UndoOperation.batch([.deleteReminder(snapshot: reminder)]).redoWrites)
        XCTAssertFalse(UndoOperation.batch([completion, .deleteEvent(snapshot: event)]).redoWrites)
        XCTAssertFalse(UndoOperation.batch([]).redoWrites, "an empty batch writes nothing")
        XCTAssertTrue(UndoOperation.batch([completion, completion]).redoWrites)
    }

    /// The instruction names the title and the tool that repeats the operation, never the
    /// identifier (stale after an update-undo across accounts, #246), and says nothing was written.
    func testInstructionsNameTheTitleAndToolNotTheIdentifier() throws {
        let expectedTool = ["create_event", "delete_event", "update_event", nil, "move_events_batch",
                            "create_reminder", "delete_reminder", "update_reminder"]
        for (operation, tool) in zip(instructionOnly, expectedTool) {
            let text = try XCTUnwrap(operation.redoInstruction)
            XCTAssertFalse(text.contains("EVT-1") || text.contains("REM-1"), text)
            XCTAssertTrue(text.contains("'Standup'") || text.contains("'Pay rent'"), text)
            XCTAssertTrue(text.contains("Nothing was written"), text)
            if let tool { XCTAssertTrue(text.contains(tool), text) }
        }
        let events = try XCTUnwrap(UndoOperation.batch([.deleteEvent(snapshot: event), .deleteEvent(snapshot: event)]).redoInstruction)
        XCTAssertTrue(events.contains("2 events") && events.contains("delete_events_batch"), events)
        let reminders = try XCTUnwrap(UndoOperation.batch([.deleteReminder(snapshot: reminder)]).redoInstruction)
        XCTAssertTrue(reminders.contains("1 reminder") && reminders.contains("delete_reminders_batch"), reminders)
    }

    func testInstructionDropsHiddenCharactersFromTheTitle() throws {
        let text = try XCTUnwrap(UndoOperation.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Stand\u{202E}up\u{200B}")).redoInstruction)
        XCTAssertTrue(text.contains("'Standup'"), text)
    }

    // MARK: - CalendarUndoManager.beginRedo

    func testBeginRedoLeavesBothStacksForARecordWhoseRedoWritesNothing() async throws {
        let history = CalendarUndoManager()
        await history.record(completion)
        await history.record(.deleteEvent(snapshot: event))
        let undone = try await history.beginUndo()
        await history.finishHistoryOperation(try XCTUnwrap(undone))
        let before = await history.historySnapshot()

        let start = try await history.beginRedo()

        guard case .notRedoable(let record, let undoCount, let redoCount) = start else {
            return XCTFail("expected notRedoable, got \(start)")
        }
        XCTAssertEqual(record.id, undone?.id)
        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(redoCount, 1)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id))
        XCTAssertEqual(after.redoCount, 1)
        // No history operation was left active: another begin is not refused as busy.
        let again = try await history.beginRedo()
        guard case .notRedoable = again else { return XCTFail("expected notRedoable again, got \(again)") }
        let undoAgain = try await history.beginUndo()
        XCTAssertNotNil(undoAgain, "the older completion record is still undoable")
    }

    func testBeginRedoStillMovesACompletionRecord() async throws {
        let history = CalendarUndoManager()
        await history.record(completion)
        let undone = try await history.beginUndo()
        await history.finishHistoryOperation(try XCTUnwrap(undone))

        let start = try await history.beginRedo()

        guard case .started(let record) = start else { return XCTFail("expected started, got \(start)") }
        XCTAssertEqual(record.id, undone?.id)
        let state = await history.historySnapshot()
        XCTAssertEqual(state.undoCount, 1)
        XCTAssertEqual(state.redoCount, 0)
        do { _ = try await history.beginRedo(); XCTFail("a started redo holds the busy lock") } catch {}
    }

    func testBeginRedoOnAnEmptyRedoStack() async throws {
        let start = try await CalendarUndoManager().beginRedo()
        guard case .empty = start else { return XCTFail("expected empty, got \(start)") }
    }
}
