import XCTest
@testable import CheICalMCP

/// #247: which records a redo writes for (`redoInstruction` / `redoWrites`), and what
/// `CalendarUndoManager.beginRedo` does with a record whose redo writes nothing: it leaves the
/// redo stack and the undo stack does not move. Pure apart from building snapshots in memory, so
/// no TCC prompt.
final class UndoRedoClassificationTests: XCTestCase {
    // Static, so each fixture (and its EKEventStore) is built once per class when first used:
    // instance properties are built for every test when XCTest assembles the suite, and too
    // many stores in one process make EventKit refuse the real one other tests use.
    private static let eventFixture = UndoSnapshotFixtures.event(title: "Standup")
    private static let reminderFixture = UndoSnapshotFixtures.reminder(title: "Pay rent")
    private var event: EventSnapshot { Self.eventFixture }
    private var reminder: ReminderSnapshot { Self.reminderFixture }

    private var completion: UndoOperation {
        .completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                          title: "Pay rent", redoCompletionDate: nil, wasRecurring: false)
    }

    /// Every record kind whose redo used to return an instruction and write nothing.
    private var instructionOnly: [UndoOperation] {
        [
            .createEvent(id: "EVT-1", title: "Standup", created: event),
            .deleteEvent(snapshot: event),
            .deleteOccurrence(snapshot: event, notCarriedOver: []),
            .deleteFollowingOccurrences(title: "Standup"),
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
        let expectedTool = ["create_event", "delete_event", "delete_event", nil, "update_event", nil, "move_events_batch",
                            "create_reminder", "delete_reminder", "update_reminder"]
        // `zip` stops at the shorter list, so a kind added to one list only would be skipped
        // silently (PR #282 round 3, finding 37).
        XCTAssertEqual(instructionOnly.count, expectedTool.count)
        for (operation, tool) in zip(instructionOnly, expectedTool) {
            let text = try XCTUnwrap(operation.redoInstruction)
            XCTAssertFalse(text.contains("EVT-1") || text.contains("REM-1"), text)
            XCTAssertTrue(text.contains("'Standup'") || text.contains("'Pay rent'"), text)
            XCTAssertTrue(text.contains("Nothing was written"), text)
            XCTAssertFalse(text.contains("stays until"), "the entry is dropped, not kept (#247): \(text)")
            if let tool { XCTAssertTrue(text.contains(tool), text) }
        }
        let events = try XCTUnwrap(UndoOperation.batch([.deleteEvent(snapshot: event), .deleteEvent(snapshot: event)]).redoInstruction)
        XCTAssertTrue(events.contains("2 events") && events.contains("delete_events_batch"), events)
        let reminders = try XCTUnwrap(UndoOperation.batch([.deleteReminder(snapshot: reminder)]).redoInstruction)
        XCTAssertTrue(reminders.contains("1 reminder") && reminders.contains("delete_reminders_batch"), reminders)
    }

    /// #244 (PR #278): a restored occurrence is a one-off event, deleted again with `delete_event`;
    /// the marker of an occurrence-and-following delete is never undone (its undo discards the
    /// record), so there is nothing to redo. Neither writes on redo.
    func testTheOccurrenceDeleteRecordsWriteNothingOnRedo() throws {
        let occurrence = try XCTUnwrap(UndoOperation.deleteOccurrence(snapshot: event, notCarriedOver: ["absolute_alarms"]).redoInstruction)
        XCTAssertTrue(occurrence.contains("occurrence") && occurrence.contains("one-off event") && occurrence.contains("delete_event"), occurrence)
        let following = try XCTUnwrap(UndoOperation.deleteFollowingOccurrences(title: "Standup").redoInstruction)
        XCTAssertTrue(following.contains("was not undone") && following.contains("nothing to redo"), following)
    }

    /// A `delete_events_batch` record can mix whole events and occurrences (#244); both come back
    /// as events, so the batch instruction is the event one.
    func testABatchOfEventAndOccurrenceDeletesNamesDeleteEventsBatch() throws {
        let mixed = try XCTUnwrap(UndoOperation.batch([.deleteEvent(snapshot: event),
                                                       .deleteOccurrence(snapshot: event, notCarriedOver: [])]).redoInstruction)
        XCTAssertTrue(mixed.contains("2 events") && mixed.contains("delete_events_batch"), mixed)
    }

    func testInstructionDropsHiddenCharactersFromTheTitle() throws {
        let text = try XCTUnwrap(UndoOperation.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Stand\u{202E}up\u{200B}")).redoInstruction)
        XCTAssertTrue(text.contains("'Standup'"), text)
    }

    // MARK: - CalendarUndoManager.beginRedo

    /// Maintainer decision on #247 (2026-10-07): a top record whose redo writes nothing is removed
    /// from the redo stack once its instruction is returned, so the record beneath it is reachable
    /// on the next redo. The undo stack does not move, so the next undo cannot undo that record a
    /// second time (the repeated undo #247 reported).
    func testBeginRedoDropsATopRecordWhoseRedoWritesNothingAndLeavesTheUndoStack() async throws {
        let history = CalendarUndoManager()
        await history.record(.deleteEvent(snapshot: event))
        await history.record(completion)
        let completionRecord = try await history.beginUndo()
        await history.finishHistoryOperation(try XCTUnwrap(completionRecord))
        let undoneDelete = try await history.beginUndo()          // the delete, now on top of redo
        let deleteRecord = try XCTUnwrap(undoneDelete)
        await history.finishHistoryOperation(deleteRecord)
        let before = await history.historySnapshot()
        XCTAssertEqual(before.undoCount, 0)
        XCTAssertEqual(before.redoCount, 2)

        let start = try await history.beginRedo()

        guard case .dropped(let record, let undoCount, let redoCount) = start else {
            return XCTFail("expected dropped, got \(start)")
        }
        XCTAssertEqual(record.id, deleteRecord.id)
        XCTAssertEqual(undoCount, 0, "the undo stack is not touched")
        XCTAssertEqual(redoCount, 1, "the dropped record no longer counts")
        let after = await history.historySnapshot()
        XCTAssertEqual(after.undoCount, 0)
        XCTAssertEqual(after.redoCount, 1)

        // No history operation was left active, and the next redo reaches the completion beneath.
        guard case .started(let next) = try await history.beginRedo() else {
            return XCTFail("the record beneath the dropped one is redone next")
        }
        XCTAssertEqual(next.operation.description, completion.description)
    }

    /// The undo stack keeps what it held: an older record stays undoable after the drop.
    func testDroppingARedoRecordKeepsTheOlderUndoRecords() async throws {
        let history = CalendarUndoManager()
        await history.record(completion)
        await history.record(.deleteEvent(snapshot: event))
        let undoneRecord = try await history.beginUndo()
        let undone = try XCTUnwrap(undoneRecord)
        await history.finishHistoryOperation(undone)
        let before = await history.historySnapshot()

        guard case .dropped = try await history.beginRedo() else { return XCTFail("expected dropped") }

        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), before.entries.map(\.id))
        XCTAssertEqual(after.redoCount, 0)
        guard case .empty(let undoCount) = try await history.beginRedo() else { return XCTFail("nothing left to redo") }
        XCTAssertEqual(undoCount, 1)
        let undoAgain = try await history.beginUndo()
        XCTAssertNotEqual(undoAgain?.id, undone.id, "the dropped record is not undone again")
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
