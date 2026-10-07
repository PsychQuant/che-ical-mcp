import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #248: a batch undo restores every member or writes nothing when a member's calendar or list
/// is gone (B), and a failure part-way keeps only the members not yet restored (A). Pure: the
/// snapshots are built in memory and the batch runs through `UndoBatchRunner`'s closures, so no
/// EventKit store is read or written.
final class UndoBatchRestoreTests: XCTestCase {
    // Static, so each fixture (and its EKEventStore) is built once per class when first used:
    // instance properties are built for every test when XCTest assembles the suite, and too
    // many stores in one process make EventKit refuse the real one other tests use.
    private static let eventFixture = UndoSnapshotFixtures.event(title: "Standup")
    private static let reminderFixture = UndoSnapshotFixtures.reminder(title: "Pay rent")
    private var event: EventSnapshot { Self.eventFixture }
    private var reminder: ReminderSnapshot { Self.reminderFixture }

    // MARK: - B: where an undo recreates the item

    func testOnlyDeleteUndosRecreateAnItem() throws {
        guard case .eventCalendar(let eventSnapshot)? = UndoOperation.deleteEvent(snapshot: event).restoreDestination(verb: .undo) else {
            return XCTFail("a delete-event undo recreates the event in its recorded calendar")
        }
        XCTAssertEqual(eventSnapshot.title, "Standup")
        guard case .reminderList(let reminderSnapshot)? = UndoOperation.deleteReminder(snapshot: reminder).restoreDestination(verb: .undo) else {
            return XCTFail("a delete-reminder undo recreates the reminder in a list")
        }
        XCTAssertEqual(reminderSnapshot.title, "Pay rent")

        let others: [UndoOperation] = [
            .createEvent(id: "e", title: "Standup", created: event),
            .updateEvent(id: "e", oldSnapshot: event, saved: event),
            .updateRecurringEvent(id: "e", title: "Standup", kind: .series),
            .moveEvent(id: "e", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "Standup", isSeries: false),
            .createReminder(id: "r", title: "Pay rent", created: reminder),
            .updateReminder(id: "r", oldSnapshot: reminder, saved: reminder),
            .completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                              title: "Pay rent", redoCompletionDate: nil, wasRecurring: false),
            .batch([.deleteEvent(snapshot: event)]),
        ]
        for operation in others {
            XCTAssertNil(operation.restoreDestination(verb: .undo), operation.description)
        }
    }

    /// Redo of a delete writes nothing (#247), so it has nothing to check.
    func testRedoHasNoDestinationToCheck() {
        XCTAssertNil(UndoOperation.deleteEvent(snapshot: event).restoreDestination(verb: .redo))
        XCTAssertNil(UndoOperation.deleteReminder(snapshot: reminder).restoreDestination(verb: .redo))
    }

    func testTheRefusalSaysNothingWasWrittenAndHowToGiveUp() {
        let eventError = UndoRestoreDestination.eventCalendar(event).missingError
        XCTAssertTrue(eventError.message.contains("event 'Standup'"), eventError.message)
        XCTAssertTrue(eventError.message.contains("calendar"), eventError.message)
        let reminderError = UndoRestoreDestination.reminderList(reminder).missingError
        XCTAssertTrue(reminderError.message.contains("reminder 'Pay rent'"), reminderError.message)
        XCTAssertTrue(reminderError.message.contains("list"), reminderError.message)
        for message in [eventError.message, reminderError.message] {
            XCTAssertTrue(message.contains("Nothing in this batch was written"), message)
            XCTAssertTrue(message.contains("discard_id"), message)
        }
    }

    /// The titles come from the store (a shared calendar's title is set by someone else), so they
    /// pass `undoShownTitle` like every other undo error.
    func testTheRefusalShowsTitlesLikeTheOtherUndoErrors() {
        let error = UndoRestoreDestination.eventCalendar(UndoSnapshotFixtures.event(title: "Stand\u{202E}up 'x'")).missingError
        XCTAssertTrue(error.message.contains("'Standup \u{2019}x\u{2019}'"), error.message)
        XCTAssertFalse(error.message.unicodeScalars.contains { $0.value == 0x202E }, error.message)
    }

    /// Kept like a not-found (#191, #236 D2): the user can recreate the calendar or give up.
    func testTheRefusalKeepsTheRecordAndReachesTheClientVerbatim() {
        let error: Error = UndoRestoreDestination.reminderList(reminder).missingError
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue(error is TrustedErrorMessage)
    }

    /// The pre-check is part of the batch check, which runs on every member before the first
    /// write: a member whose calendar is gone stops the batch with nothing restored.
    func testAMissingDestinationStopsTheBatchBeforeItsFirstWrite() async {
        let gone = UndoSnapshotFixtures.event(title: "Gone")
        let members: [UndoOperation] = [.deleteEvent(snapshot: gone), .deleteEvent(snapshot: event)]
        var executed: [String] = []
        do {
            _ = try await UndoBatchRunner.run(
                Array(members.reversed()),
                check: { member in
                    if case .eventCalendar(let snapshot)? = member.restoreDestination(verb: .undo), snapshot.title == "Gone" {
                        throw UndoRestoreDestination.eventCalendar(snapshot).missingError
                    }
                },
                execute: { member in executed.append(member.description); return "restored" })
            XCTFail("the refusal must surface")
        } catch {
            XCTAssertTrue(error is UndoRestoreDestinationMissingError, "\(error)")
        }
        XCTAssertEqual(executed, [])
    }

    // MARK: - A: a write fails part-way

    private enum SaveFailed: Error { case failed }

    private func deleted(_ title: String) -> UndoOperation {
        .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: title))
    }

    private func titles(_ operations: [UndoOperation]) -> [String] {
        operations.map { operation -> String in
            switch operation {
            case .deleteEvent(let snapshot): return snapshot.title
            case .batch(let members): return "[" + titles(members).joined(separator: ",") + "]"
            default: return operation.description
            }
        }
    }

    func testTheRunnerReportsHowManyWritesSucceededBeforeAFailure() async {
        var executed: [Int] = []
        do {
            _ = try await UndoBatchRunner.run([4, 3, 2, 1], check: { _ in },
                                              execute: { value in
                                                  if value == 2 { throw SaveFailed.failed }
                                                  executed.append(value)
                                                  return "\(value)"
                                              })
            XCTFail("the failure must surface")
        } catch let interrupted as UndoBatchRunner.Interrupted {
            XCTAssertEqual(interrupted.completed, 2)
            XCTAssertTrue(interrupted.underlying is SaveFailed)
        } catch {
            XCTFail("expected Interrupted, got \(error)")
        }
        XCTAssertEqual(executed, [4, 3], "nothing after the failing write runs")
    }

    func testAFailureOfTheFirstWriteRethrowsTheMemberErrorUnchanged() {
        let members = [deleted("A"), deleted("B")]
        let failure = UndoOperation.batchUndoFailure(members: members,
                                                     interrupted: .init(completed: 0, underlying: SaveFailed.failed),
                                                     describe: { _ in XCTFail("nothing to describe"); return "" })
        XCTAssertTrue(failure is SaveFailed, "nothing was written, so the record is kept whole as before: \(failure)")
    }

    /// Undo runs the members in reverse; the record keeps the members not yet restored, the
    /// failing one included, in record order.
    func testTheRecordKeepsOnlyTheMembersNotYetRestoredInRecordOrder() throws {
        let members = ["A", "B", "C", "D"].map(deleted)
        let failure = UndoOperation.batchUndoFailure(members: members,
                                                     interrupted: .init(completed: 2, underlying: SaveFailed.failed),
                                                     describe: { _ in "eventkit_error_1" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(titles(partial.remaining), ["A", "B"], "D and C were restored; B failed; A never ran")
        XCTAssertEqual(partial.restoredCount, 2)
    }

    /// The retry of the narrowed record executes none of the members restored before the failure.
    func testARetryOfTheNarrowedRecordDoesNotRestoreTheFirstMembersAgain() async throws {
        let members = ["A", "B", "C", "D"].map(deleted)
        var executed: [String] = []
        var failB = true
        let execute: (UndoOperation) async throws -> String = { member in
            let title = self.titles([member])[0]
            if title == "B", failB { failB = false; throw SaveFailed.failed }
            executed.append(title)
            return title
        }
        var remaining = members
        do {
            _ = try await UndoBatchRunner.run(Array(remaining.reversed()), check: { _ in }, execute: execute)
            XCTFail("the first attempt fails at B")
        } catch let interrupted as UndoBatchRunner.Interrupted {
            let failure = UndoOperation.batchUndoFailure(members: remaining, interrupted: interrupted, describe: { _ in "x" })
            remaining = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError).remaining
        }
        _ = try await UndoBatchRunner.run(Array(remaining.reversed()), check: { _ in }, execute: execute)

        XCTAssertEqual(executed, ["D", "C", "B", "A"], "each member restored exactly once")
    }

    /// No nested batch is recorded today; if one were, its own remainder replaces it, so its
    /// restored members are not recreated either.
    func testANestedBatchThatStoppedPartWayKeepsOnlyItsOwnRemainder() throws {
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Y")], restoredCount: 1, memberError: "eventkit_error_1")
        let members: [UndoOperation] = [deleted("X"), .batch([deleted("Y"), deleted("Z")])]
        let failure = UndoOperation.batchUndoFailure(members: members,
                                                     interrupted: .init(completed: 0, underlying: inner),
                                                     describe: { _ in "unused" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(titles(partial.remaining), ["X", "[Y]"])
    }

    func testThePartialErrorSaysWhatWasRestoredAndKeptAndHowToGiveUp() {
        let error = UndoBatchPartiallyUndoneError(remaining: [deleted("A"), deleted("B")], restoredCount: 3,
                                                  memberError: "eventkit_error_1")
        XCTAssertTrue(error.message.contains("3"), error.message)
        XCTAssertTrue(error.message.contains("2 items not yet restored"), error.message)
        XCTAssertTrue(error.message.contains("eventkit_error_1"), error.message)
        XCTAssertTrue(error.message.contains("same id"), error.message)
        XCTAssertTrue(error.message.contains("discard_id"), error.message)
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue((error as Error) is TrustedErrorMessage)
    }

    // MARK: - A: the history keeps the narrowed record under the same id

    func testANarrowedRecordKeepsItsIdAndTimestamp() async throws {
        let history = CalendarUndoManager()
        await history.record(deleted("Older"))
        await history.record(.batch(["A", "B", "C"].map(deleted)))
        let listed = await history.historySnapshot()
        let started = try await history.beginUndo()
        let record = try XCTUnwrap(started)

        await history.restoreFailedUndo(record, remaining: .batch([deleted("A")]))

        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.id), listed.entries.map(\.id), "same ids, same order")
        XCTAssertEqual(after.entries.first?.description, "Batch (1 operations)")
        XCTAssertEqual(after.entries.first?.timestamp, listed.entries.first?.timestamp)
        XCTAssertEqual(after.redoCount, 0)
        let next = try await history.beginUndo()   // not busy
        guard case .batch(let members)? = next?.operation else { return XCTFail("expected the narrowed batch") }
        XCTAssertEqual(titles(members), ["A"])
    }
}
