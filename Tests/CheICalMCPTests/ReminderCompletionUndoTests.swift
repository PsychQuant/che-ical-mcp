import EventKit
import XCTest
@testable import CheICalMCP

/// Completion undo records are value-only: no EventKitManager instance, and the
/// EventKit objects used are in-memory (never fetched or saved), so no TCC prompt.
final class ReminderCompletionUndoTests: XCTestCase {
    private func snapshot(title: String = "Daily reminder", completed: Bool = false) -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(
            id: "recurring-194", title: title, calendarID: "calendar",
            sourceID: "source", isCompleted: completed, hasRecurrence: true,
            due: nil, rules: [], completionDate: completed ? Self.recordedCompletion : nil
        )
    }

    func testLegacyCompletionConstructorAndDescriptionRemainAvailable() {
        let operation = UndoOperation.completeReminder(id: "once", wasCompleted: false, requestedCompleted: true, completionDate: nil, title: "Once")
        XCTAssertEqual(operation.description, "Completed reminder: Once")
    }

    func testHistoryDescriptionDistinguishesCompletionAndReopen() {
        let before = snapshot()
        XCTAssertEqual(
            UndoOperation.completeRecurringReminder(before: before, requestedCompleted: true).description,
            "Completed recurring reminder: Daily reminder")
        XCTAssertEqual(
            UndoOperation.completeRecurringReminder(before: before, requestedCompleted: false).description,
            "Reopened recurring reminder: Daily reminder")
    }

    func testHistoryDescriptionSanitizesUserControlledTitle() {
        let title = "Reminder\nForged log\r\t\u{001B}[31m"
        let operation = UndoOperation.completeRecurringReminder(before: snapshot(title: title), requestedCompleted: true)
        XCTAssertEqual(operation.description,
                       "Completed recurring reminder: \(EventKitErrorSanitizer.sanitizeForInterpolation(title))")
        XCTAssertFalse(operation.description.contains("\n"))
        XCTAssertFalse(operation.description.contains("\u{001B}"))
    }

    func testRecordPreservesRequestedStateForIdempotentCompletion() {
        let before = snapshot(completed: true)
        let record = UndoRecord(.completeRecurringReminder(before: before, requestedCompleted: true))
        guard case .completeRecurringReminder(let saved, let requested) = record.operation else {
            return XCTFail("Expected recurring completion record")
        }
        XCTAssertEqual(saved, before)
        XCTAssertTrue(requested)
    }

    func testDiscardFailedUndoDropsTheRecordAndKeepsOlderEntriesReachable() async {
        // Verify round 1, row 1: a permanently un-undoable record re-appended by
        // restoreFailedUndo blocks every older entry forever. Discarding it must
        // leave the older entry on top and must not resurrect it on the redo stack.
        let manager = CalendarUndoManager()
        await manager.record(.completeReminder(id: "older", wasCompleted: false, requestedCompleted: true, completionDate: nil, title: "Older"))
        await manager.record(.completeRecurringReminder(before: snapshot(), requestedCompleted: true))
        guard let popped = await manager.popUndo() else { return XCTFail("expected a record") }
        await manager.discardFailedUndo(popped)
        let descriptions = await manager.history().map(\.description)
        XCTAssertEqual(descriptions, ["Completed reminder: Older"])
        let canRedo = await manager.canRedo
        XCTAssertFalse(canRedo)
        guard case .completeReminder(let id, _, _, _, _)? = await manager.popUndo()?.operation else {
            return XCTFail("the older record must be the next undo target")
        }
        XCTAssertEqual(id, "older")
    }

    func testUndoFailureDispositionDiscardsOnlyUnrecoverableErrors() {
        XCTAssertEqual(UndoFailureDisposition.of(UnrecoverableUndoError(message: "gone")), .discard)
        XCTAssertEqual(UndoFailureDisposition.of(ToolError.invalidParameter("transient")), .restore)
        XCTAssertEqual(UndoFailureDisposition.of(EventKitError.reminderNotFound(identifier: "x")), .restore)
        XCTAssertEqual(UnrecoverableUndoError(message: "gone").errorDescription, "gone")
    }

    func testCompletionRecordFallsBackToLegacyWhenTheSnapshotIsNotIdentifiable() {
        // A guarded record that can never match again (no comparable due, no known
        // rules) would be discarded on its first undo with a misleading reason; the
        // legacy identifier-keyed record still restores such an unchanged item.
        let daily = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let identifiable = ReminderCompletionSnapshot(
            id: "r", title: "t", calendarID: "c", sourceID: "s", isCompleted: false, hasRecurrence: true,
            due: ReminderDueValue(components: DateComponents(year: 2026, month: 9, day: 5)), rules: [daily], completionDate: nil)
        guard case .completeRecurringReminder = UndoOperation.forCompletion(before: identifiable, requestedCompleted: true, savedTitle: "t") else {
            return XCTFail("identifiable recurring snapshot must get the guarded record")
        }
        guard case .completeReminder(let id, let wasCompleted, _, _, let title) = UndoOperation.forCompletion(before: snapshot(), requestedCompleted: true, savedTitle: "Saved") else {
            return XCTFail("non-identifiable recurring snapshot must fall back to the legacy record")
        }
        XCTAssertEqual(id, "recurring-194"); XCTAssertFalse(wasCompleted); XCTAssertEqual(title, "Saved")
        let oneOff = ReminderCompletionSnapshot(id: "o", title: "t", calendarID: "c", sourceID: "s", isCompleted: true, hasRecurrence: false, due: nil, rules: [], completionDate: Self.recordedCompletion)
        guard case .completeReminder(_, let was, _, _, _) = UndoOperation.forCompletion(before: oneOff, requestedCompleted: false, savedTitle: "t") else {
            return XCTFail("one-off reminder must use the legacy record")
        }
        XCTAssertTrue(was)
    }

    func testUnrecoverableUndoErrorMessageSurvivesResponseSanitization() {
        // The whole point of the permanent-failure path is the explicit message; an
        // untrusted error type is flattened to `error_unknown` on the wire.
        let sanitized = EventKitErrorSanitizer.sanitizeForResponse(UnrecoverableUndoError(message: "entry discarded; reopen explicitly"))
        XCTAssertEqual(sanitized.code, "entry discarded; reopen explicitly")
    }

    func testDiscardFailedUndoOnlyDropsTheRecordItWasHanded() async {
        // A contract slip (discard called for a record that is not the one just
        // popped) must not destroy an unrelated entry.
        let manager = CalendarUndoManager()
        await manager.record(.completeReminder(id: "a", wasCompleted: false, requestedCompleted: true, completionDate: nil, title: "A"))
        await manager.record(.completeReminder(id: "b", wasCompleted: false, requestedCompleted: true, completionDate: nil, title: "B"))
        guard let poppedB = await manager.popUndo() else { return XCTFail("expected b") }
        let unrelated = UndoRecord(.completeReminder(id: "zzz", wasCompleted: false, requestedCompleted: true, completionDate: nil, title: "Z"))
        await manager.discardFailedUndo(unrelated)
        let canRedo = await manager.canRedo
        XCTAssertTrue(canRedo, "b must still be on the redo stack — the unrelated record was not the popped one")
        await manager.discardFailedUndo(poppedB)
        let canRedoAfter = await manager.canRedo
        XCTAssertFalse(canRedoAfter)
    }

    // MARK: - #196 the completion instant is part of the record

    private static let recordedCompletion = Date(timeIntervalSince1970: 1_756_900_000)

    private func completedOneOff() -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(
            id: "one-off", title: "Once", calendarID: "calendar", sourceID: "source",
            isCompleted: true, hasRecurrence: false, due: nil, rules: [],
            completionDate: Self.recordedCompletion)
    }

    func testSnapshotCarriesTheRecordedCompletionDate() {
        XCTAssertEqual(completedOneOff().completionDate, Self.recordedCompletion)
        XCTAssertNil(snapshot().completionDate, "an incomplete snapshot records no completion instant")
    }

    func testForCompletionThreadsTheCompletionDateIntoTheLegacyRecord() {
        guard case .completeReminder(_, let wasCompleted, _, let recorded, _) =
                UndoOperation.forCompletion(before: completedOneOff(), requestedCompleted: false, savedTitle: "Once") else {
            return XCTFail("one-off items use the legacy record")
        }
        XCTAssertTrue(wasCompleted)
        XCTAssertEqual(recorded, Self.recordedCompletion)
    }

    func testForCompletionKeepsTheCompletionDateOnTheRecurringRecord() {
        let daily = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        let due = ReminderDueValue(components: DateComponents(year: 2026, month: 9, day: 6))
        let before = ReminderCompletionSnapshot(
            id: "recurring-196", title: "Daily", calendarID: "calendar", sourceID: "source",
            isCompleted: true, hasRecurrence: true, due: due, rules: [daily],
            completionDate: Self.recordedCompletion)
        guard case .completeRecurringReminder(let recorded, _) =
                UndoOperation.forCompletion(before: before, requestedCompleted: false, savedTitle: "Daily") else {
            return XCTFail("identifiable recurring items use the guarded record")
        }
        XCTAssertEqual(recorded.completionDate, Self.recordedCompletion)
        // Completion state is not occurrence identity: the same occurrence without
        // a completion instant is a different value but the same occurrence.
        let reopened = ReminderCompletionSnapshot(
            id: "recurring-196", title: "Daily", calendarID: "calendar", sourceID: "source",
            isCompleted: false, hasRecurrence: true, due: due, rules: [daily], completionDate: nil)
        XCTAssertNotEqual(before, reopened)
        XCTAssertTrue(before.matchesOccurrence(reopened))
    }

    // MARK: - #196 round 2: the restore decision is a pure value, redo replays the request

    func testRestorePlanUsesTheRecordedInstantWhenRestoringToCompleted() {
        let plan = ReminderCompletionWrite.plan(isCompleted: true, recorded: Self.recordedCompletion, now: Date())
        XCTAssertTrue(plan.isCompleted)
        XCTAssertEqual(plan.completionDate, Self.recordedCompletion)
    }

    func testRestorePlanFallsBackToNowWhenNothingWasRecorded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ReminderCompletionWrite.plan(isCompleted: true, recorded: nil, now: now).completionDate, now)
    }

    func testRestorePlanClearsTheInstantWhenRestoringToIncomplete() {
        let plan = ReminderCompletionWrite.plan(isCompleted: false, recorded: Self.recordedCompletion, now: Date())
        XCTAssertFalse(plan.isCompleted)
        XCTAssertNil(plan.completionDate)
    }

    func testLegacyRecordCarriesTheRequestedStateForIdempotentCompletion() {
        // complete(true) on an already-completed one-off: undo restores the
        // recorded instant; redo must re-apply the request, never flip to incomplete.
        guard case .completeReminder(_, let was, let requested, let recorded, _) =
                UndoOperation.forCompletion(before: completedOneOff(), requestedCompleted: true, savedTitle: "Once") else {
            return XCTFail("one-off items use the legacy record")
        }
        XCTAssertTrue(was)
        XCTAssertTrue(requested)
        XCTAssertEqual(recorded, Self.recordedCompletion)
    }

    func testSnapshotFromEKReminderCapturesTheCompletionInstant() {
        // In-memory EKReminder; nothing is fetched or saved, so no TCC prompt.
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "Done"
        reminder.completionDate = Self.recordedCompletion
        let snapshot = ReminderCompletionSnapshot(from: reminder)
        XCTAssertTrue(snapshot.isCompleted)
        XCTAssertEqual(snapshot.completionDate, Self.recordedCompletion)
    }

    // MARK: - #196 round 3 (post verify round 2): the mapping and the write are pinned

    func testUndoWriteRestoresTheRecordedInstantForBothRecords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = UndoOperation.forCompletion(before: completedOneOff(), requestedCompleted: false, savedTitle: "Once")
        XCTAssertEqual(legacy.completionWrite(undo: true, now: now),
                       ReminderCompletionWrite(isCompleted: true, completionDate: Self.recordedCompletion))
        let recurring = UndoOperation.completeRecurringReminder(before: snapshot(completed: true), requestedCompleted: false)
        XCTAssertEqual(recurring.completionWrite(undo: true, now: now),
                       ReminderCompletionWrite(isCompleted: true, completionDate: Self.recordedCompletion))
        XCTAssertNil(UndoOperation.createReminder(id: "x", title: "x").completionWrite(undo: true, now: now))
    }

    func testRedoWriteReplaysTheRequestNeverTheOppositeOfThePriorState() {
        // Idempotent completion: before.isCompleted == true, requested == true.
        // A redo that inferred !wasCompleted would reopen the reminder here.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = UndoOperation.forCompletion(before: completedOneOff(), requestedCompleted: true, savedTitle: "Once")
        XCTAssertEqual(legacy.completionWrite(undo: false, now: now),
                       ReminderCompletionWrite(isCompleted: true, completionDate: now))
        let reopen = UndoOperation.forCompletion(before: completedOneOff(), requestedCompleted: false, savedTitle: "Once")
        XCTAssertEqual(reopen.completionWrite(undo: false, now: now),
                       ReminderCompletionWrite(isCompleted: false, completionDate: nil))
        let recurring = UndoOperation.completeRecurringReminder(before: snapshot(completed: true), requestedCompleted: true)
        XCTAssertEqual(recurring.completionWrite(undo: false, now: now)?.isCompleted, true)
    }

    func testApplyWritesTheRecordedInstantOverEventKitsOwnStamp() {
        // The write the fix actually performs, on an in-memory EKReminder: setting
        // isCompleted makes EventKit stamp "now"; the recorded instant must win.
        let reminder = EKReminder(eventStore: EKEventStore())
        ReminderCompletionWrite(isCompleted: true, completionDate: Self.recordedCompletion).apply(to: reminder)
        XCTAssertTrue(reminder.isCompleted)
        XCTAssertEqual(reminder.completionDate, Self.recordedCompletion)
        ReminderCompletionWrite(isCompleted: false, completionDate: nil).apply(to: reminder)
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertNil(reminder.completionDate)
    }

    func testReminderSnapshotCapturesTheCompletionInstant() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)   // in-memory; the snapshot reads calendar.title
        reminder.title = "Edited later"
        reminder.completionDate = Self.recordedCompletion
        XCTAssertEqual(ReminderSnapshot(from: reminder).completionDate, Self.recordedCompletion)
    }
}
