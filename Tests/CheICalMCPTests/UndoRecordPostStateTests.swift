import EventKit
import XCTest
@testable import CheICalMCP

/// #236: which state each undo / redo arm checks before it writes. One test per arm of the
/// diagnosis table; the arms that write to no existing item check nothing.
final class UndoRecordPostStateTests: XCTestCase {
    private let store = EKEventStore()
    private lazy var calendar = EKCalendar(for: .event, eventStore: store)
    private lazy var list = EKCalendar(for: .reminder, eventStore: store)
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(title: String) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = instant
        event.endDate = instant.addingTimeInterval(3600)
        return event
    }

    private func makeReminder(title: String) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        return reminder
    }

    private func recurringBefore(completed: Bool) -> ReminderCompletionSnapshot {
        ReminderCompletionSnapshot(id: "recurring", title: "Daily", calendarID: "calendar", sourceID: "source",
                                   isCompleted: completed, hasRecurrence: true, due: nil, rules: [],
                                   completionDate: completed ? instant : nil)
    }

    // MARK: - Events

    func testCreateEventUndoComparesEveryFieldOfTheCreatedEvent() throws {
        let event = makeEvent(title: "Standup")
        let op = UndoOperation.createEvent(id: "e1", title: "Standup", created: EventSnapshot(from: event))

        let expected = try XCTUnwrap(op.undoPostState)
        guard case .event(let id, _, _, let restoring) = expected else { return XCTFail("\(expected)") }
        XCTAssertEqual(id, "e1")
        XCTAssertNil(restoring, "deleting the event destroys every field")
        XCTAssertEqual(expected.changedFields(in: event), [])
        event.notes = "added elsewhere"
        XCTAssertEqual(expected.changedFields(in: event), ["notes"])
    }

    func testUpdateEventUndoComparesTheSavedStateAndRestoresTheOldOne() throws {
        let event = makeEvent(title: "Before")
        let old = EventSnapshot(from: event)
        event.title = "After"
        let op = UndoOperation.updateEvent(id: "post-save-id", oldSnapshot: old, saved: EventSnapshot(from: event))

        let expected = try XCTUnwrap(op.undoPostState)
        guard case .event(let id, let title, let state, let restoring) = expected else { return XCTFail("\(expected)") }
        XCTAssertEqual(id, "post-save-id")
        XCTAssertEqual(title, "After")
        XCTAssertEqual(state.title, "After")
        XCTAssertEqual(restoring?.title, "Before")
        XCTAssertEqual(op.description, "Updated event: Before", "history still names the pre-update title")
        event.title = "Renamed elsewhere"
        XCTAssertEqual(expected.changedFields(in: event), ["title"])
    }

    // MARK: - Occurrence update-undo (PR #259 round 4, device probe)

    private func weeklySeries(title: String) -> EKEvent {
        let event = makeEvent(title: title)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 6)))
        return event
    }

    /// update_event on one occurrence detaches it, and the record targets that occurrence by its
    /// post-save identifier (#246). Its undo writes the occurrence's own values and no rules: with
    /// the series' snapshot it moved the occurrence to the series' first start, and on device the
    /// save failed with EKErrorDomain 39 "The repeat field cannot be changed".
    func testAnOccurrenceUpdateRecordsTheOccurrenceWithoutRules() {
        let series = weeklySeries(title: "Standup")
        let occurrence = makeEvent(title: "Standup")
        occurrence.startDate = instant.addingTimeInterval(7 * 86_400)
        occurrence.endDate = occurrence.startDate.addingTimeInterval(3600)

        let restores = EventKitManager.updateUndoSnapshot(master: series, target: occurrence)
        XCTAssertEqual(restores.startDate, occurrence.startDate, "its own slot, not the series' first start")
        XCTAssertNil(restores.recurrenceRules, "an occurrence's undo writes no rules")

        let wholeSeries = EventKitManager.updateUndoSnapshot(master: series, target: series)
        XCTAssertEqual(wholeSeries.recurrenceRules?.count, 1, "a series update keeps restoring its rules")
    }

    /// The record of an occurrence update expects the occurrence as the update left it (the
    /// record's identifier and `saved` both come from the occurrence after the save), not the
    /// series: against the series' first occurrence the check would refuse on the start.
    func testAnOccurrenceRecordExpectsTheOccurrence() throws {
        let series = weeklySeries(title: "Standup")
        let occurrence = makeEvent(title: "Standup")
        occurrence.startDate = instant.addingTimeInterval(7 * 86_400)
        occurrence.endDate = occurrence.startDate.addingTimeInterval(3600)
        let old = EventKitManager.updateUndoSnapshot(master: series, target: occurrence)
        occurrence.title = "Standup (moved talk)"
        let op = UndoOperation.updateEvent(id: "series/RID=1", oldSnapshot: old, saved: EventSnapshot(from: occurrence))

        let expected = try XCTUnwrap(op.undoPostState)
        XCTAssertEqual(expected.changedFields(in: occurrence), [], "the occurrence as the update left it")
        XCTAssertTrue(expected.changedFields(in: series).contains("start_time"), "the series is not what the record expects")
    }

    /// #262: the undo of a span "all" update writes the series back as a whole. Saved with
    /// .thisEvent on the first occurrence, on device the first occurrence became a detached copy
    /// and the other occurrences were gone; with .futureEvents the whole series came back.
    func testASeriesUpdateIsUndoneForTheWholeSeries() {
        let series = weeklySeries(title: "Standup")
        XCTAssertEqual(EventKitManager.updateUndoSpan(restoring: EventSnapshot(from: series), target: series), .futureEvents)

        let occurrenceRecord = EventSnapshot(from: series, includeRecurrence: false)
        XCTAssertEqual(EventKitManager.updateUndoSpan(restoring: occurrenceRecord, target: series), .thisEvent)

        let oneOff = makeEvent(title: "Review")
        XCTAssertEqual(EventKitManager.updateUndoSpan(restoring: EventSnapshot(from: oneOff), target: oneOff), .thisEvent)
        XCTAssertEqual(EventKitManager.updateUndoSpan(restoring: EventSnapshot(from: series), target: oneOff), .thisEvent,
                       "undo of clear_recurrence: the event has no series yet, the restore adds the rules")
    }

    func testMoveEventUndoComparesOnlyTheCalendarItWasMovedTo() throws {
        let event = makeEvent(title: "Standup")
        let op = UndoOperation.moveEvent(id: "moved", fromCalendarIdentifier: "from",
                                         toCalendarIdentifier: calendar.calendarIdentifier, title: "Standup", isSeries: false)

        let expected = try XCTUnwrap(op.undoPostState)
        guard case .eventCalendar(let id, _, let calendarIdentifier, let restoring) = expected else { return XCTFail("\(expected)") }
        XCTAssertEqual(id, "moved")
        XCTAssertEqual(calendarIdentifier, calendar.calendarIdentifier)
        XCTAssertEqual(restoring, "from")
        event.title = "Edited after the move"
        XCTAssertEqual(expected.changedFields(in: event), [])
        event.calendar = EKCalendar(for: .event, eventStore: store)
        XCTAssertEqual(expected.changedFields(in: event), ["calendar"])
    }

    // MARK: - Reminders

    func testCreateReminderUndoComparesTheCreatedReminder() throws {
        let reminder = makeReminder(title: "Pay rent")
        let op = UndoOperation.createReminder(id: "r1", title: "Pay rent", created: ReminderSnapshot(from: reminder))

        let expected = try XCTUnwrap(op.undoPostState)
        guard case .reminder(let id, _, _, let restoring) = expected else { return XCTFail("\(expected)") }
        XCTAssertEqual(id, "r1")
        XCTAssertNil(restoring, "deleting the reminder has no value to restore")
        XCTAssertEqual(expected.changedFields(in: reminder), [])
        reminder.priority = 1
        XCTAssertEqual(expected.changedFields(in: reminder), ["priority"])
    }

    func testUpdateReminderUndoComparesTheSavedState() throws {
        let reminder = makeReminder(title: "Before")
        let old = ReminderSnapshot(from: reminder)
        reminder.title = "After"
        let op = UndoOperation.updateReminder(id: "r1", oldSnapshot: old, saved: ReminderSnapshot(from: reminder))

        let expected = try XCTUnwrap(op.undoPostState)
        guard case .reminder(_, let title, let state, let restoring) = expected else { return XCTFail("\(expected)") }
        XCTAssertEqual(title, "After")
        XCTAssertEqual(state.title, "After")
        XCTAssertEqual(restoring?.title, "Before")
        XCTAssertEqual(op.description, "Updated reminder: Before")
        reminder.isCompleted = true
        XCTAssertEqual(expected.changedFields(in: reminder), ["completed"],
                       "undo of an update writes the completion state too, so a completion made elsewhere counts")
    }

    // MARK: - Completions

    private func completionStates(_ state: UndoPostState?) -> (expected: UndoPostState.CompletionState, restoring: UndoPostState.CompletionState?)? {
        guard case .reminderCompletion(_, _, let expected, let restoring)? = state else { return nil }
        return (expected, restoring)
    }

    func testCompletionUndoExpectsTheRequestAndRedoExpectsThePriorState() throws {
        let earlier = instant.addingTimeInterval(-86_400)
        let op = UndoOperation.completeReminder(id: "r1", wasCompleted: true, requestedCompleted: false,
                                                completionDate: earlier, title: "Once", redoCompletionDate: nil, wasRecurring: false)

        let undo = try XCTUnwrap(completionStates(op.undoPostState))
        XCTAssertEqual(op.undoPostState?.itemID, "r1")
        XCTAssertEqual(undo.expected, UndoPostState.CompletionState(isCompleted: false, completionDate: nil), "the reopen it undoes")
        XCTAssertEqual(undo.restoring, UndoPostState.CompletionState(isCompleted: true, completionDate: earlier), "what undo writes")
        let redo = try XCTUnwrap(completionStates(op.redoPostState))
        XCTAssertEqual(redo.expected, undo.restoring, "redo expects the state the undo left")
        XCTAssertEqual(redo.restoring, undo.expected, "and writes the request again")
    }

    func testCompletionUndoComparesTheSavedInstant() throws {
        let op = UndoOperation.completeReminder(id: "r1", wasCompleted: false, requestedCompleted: true,
                                                completionDate: nil, title: "Once", redoCompletionDate: instant, wasRecurring: false)
        let reminder = makeReminder(title: "Once")
        reminder.isCompleted = true
        reminder.completionDate = instant.addingTimeInterval(3600)   // re-completed elsewhere

        XCTAssertEqual(try XCTUnwrap(op.undoPostState).changedFields(in: reminder), ["completion_date"])
    }

    func testRecurringCompletionChecksTheCompletionUnderTheIdentityGuard() throws {
        let op = UndoOperation.completeRecurringReminder(before: recurringBefore(completed: false), requestedCompleted: true,
                                                         redoCompletionDate: instant)
        let reminder = makeReminder(title: "Daily")
        reminder.isCompleted = true
        reminder.completionDate = instant

        let undo = try XCTUnwrap(op.undoPostState)
        XCTAssertEqual(undo.itemID, "recurring")
        XCTAssertEqual(undo.changedFields(in: reminder), [])
        let redo = try XCTUnwrap(completionStates(op.redoPostState))
        XCTAssertEqual(redo.expected, UndoPostState.CompletionState(isCompleted: false, completionDate: nil))
        XCTAssertEqual(redo.restoring, UndoPostState.CompletionState(isCompleted: true, completionDate: instant))
    }

    // MARK: - Arms that check nothing

    func testDeleteArmsAndMessageOnlyRedoArmsCheckNothing() {
        let event = UndoSnapshotFixtures.event()
        let reminder = UndoSnapshotFixtures.reminder()
        let unchecked: [UndoOperation] = [.deleteEvent(snapshot: event), .deleteReminder(snapshot: reminder)]
        for op in unchecked {
            XCTAssertNil(op.undoPostState, op.description)
            XCTAssertNil(op.redoPostState, op.description)
        }
        let messageOnlyRedo: [UndoOperation] = [
            .createEvent(id: "e", title: "E", created: event),
            .updateEvent(id: "e", oldSnapshot: event, saved: event),
            .moveEvent(id: "e", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "E", isSeries: false),
            .createReminder(id: "r", title: "R", created: reminder),
            .updateReminder(id: "r", oldSnapshot: reminder, saved: reminder),
        ]
        for op in messageOnlyRedo {
            XCTAssertNil(op.redoPostState, "redo of \(op.description) writes nothing")
        }
        XCTAssertNil(UndoOperation.batch([.deleteEvent(snapshot: event)]).undoPostState, "batches are checked per sub-operation")
    }

    // MARK: - Batch pre-flight (D4)

    func testBatchChecksEverySubOperationBeforeTheFirstWrite() async {
        enum Refused: Error { case changed }
        var executed: [Int] = []
        do {
            _ = try await UndoBatchRunner.run([1, 2, 3], check: { if $0 == 3 { throw Refused.changed } },
                                              execute: { executed.append($0); return "\($0)" })
            XCTFail("the refusal must surface")
        } catch {}
        XCTAssertEqual(executed, [], "a refusal on the last sub-operation must leave the batch untouched")
    }

    func testBatchRunsEverySubOperationInOrderWhenAllChecksPass() async throws {
        var checked: [Int] = []
        var executed: [Int] = []
        let results = try await UndoBatchRunner.run([3, 2, 1], check: { checked.append($0) },
                                                    execute: { executed.append($0); return "\($0)" })
        XCTAssertEqual(checked, [3, 2, 1])
        XCTAssertEqual(executed, [3, 2, 1])
        XCTAssertEqual(results, ["3", "2", "1"])
    }
}
