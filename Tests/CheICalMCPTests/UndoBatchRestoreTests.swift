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

    /// The destinations are gathered for the whole batch, nested batches included, so the calendars
    /// and lists are read once per batch rather than once per member (PR #282 round 1, 5 and 15).
    func testTheDestinationsOfABatchAreGatheredOnceForAllItsMembers() {
        let gone = UndoSnapshotFixtures.event(title: "Gone")
        let members: [UndoOperation] = [
            .deleteEvent(snapshot: gone),
            .createEvent(id: "e", title: "Standup", created: event),
            .batch([.deleteReminder(snapshot: reminder)]),
        ]
        let destinations = UndoRestoreDestination.of(members, verb: .undo)
        XCTAssertEqual(destinations.map(\.itemTitle), ["Gone", "Pay rent"])
        XCTAssertTrue(UndoRestoreDestination.of(members, verb: .redo).isEmpty)
    }

    func testTheFirstMissingDestinationIsTheOneTheRefusalNames() {
        let gone = UndoSnapshotFixtures.event(title: "Gone")
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event), .deleteEvent(snapshot: gone),
                                                      .deleteReminder(snapshot: reminder)], verb: .undo)
        var asked: [String] = []
        let missing = UndoRestoreDestination.firstMissing(
            among: destinations,
            eventCalendarResolves: { asked.append($0.title); return $0.title != "Gone" },
            reminderListResolves: { asked.append($0.title); return true })
        XCTAssertEqual(missing?.itemTitle, "Gone")
        XCTAssertEqual(asked, ["Standup", "Gone"], "stops at the first destination that is gone")

        let none = UndoRestoreDestination.firstMissing(among: destinations,
                                                       eventCalendarResolves: { _ in true },
                                                       reminderListResolves: { _ in true })
        XCTAssertNil(none)
        guard case .reminderList? = UndoRestoreDestination.firstMissing(among: destinations,
                                                                        eventCalendarResolves: { _ in true },
                                                                        reminderListResolves: { _ in false }) else {
            return XCTFail("a gone list is reported as the reminder's destination")
        }
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

    private final class ExecutionLog { var executed: [String] = [] }

    /// Undoes `members` through the production helper, as `executeUndo(.batch)` does, with
    /// `failsOn` deciding which member writes fail; returns what it throws, or nil.
    private func undoBatch(_ members: [UndoOperation], log: ExecutionLog,
                           failsOn: @escaping (String) -> Bool) async -> Error? {
        do {
            _ = try await UndoBatchExecution.run(members, verb: .undo, check: { _ in }, execute: { member in
                let title = self.titles([member])[0]
                if failsOn(title) { throw SaveFailed.failed }
                log.executed.append(title)
                return title
            }, describe: { _ in "eventkit_error_1" })
            return nil
        } catch {
            return error
        }
    }

    func testAFailureOfTheOnlyMemberRethrowsTheMemberErrorUnchanged() {
        let failure = UndoOperation.batchUndoFailure(members: [deleted("A")],
                                                     interrupted: .init(completed: 0, underlying: SaveFailed.failed),
                                                     describe: { _ in XCTFail("nothing to describe"); return "" })
        XCTAssertTrue(failure is SaveFailed, "nothing was written and nothing else waits: \(failure)")
    }

    /// A permanent member error discards the record, as it does for a single record.
    func testAPermanentFailureOfTheFirstWriteStandsAsBefore() {
        let failure = UndoOperation.batchUndoFailure(members: [deleted("A"), deleted("B")],
                                                     interrupted: .init(completed: 0, underlying: UnrecoverableUndoError(message: "x")),
                                                     describe: { _ in XCTFail("nothing to describe"); return "" })
        XCTAssertTrue(failure is UnrecoverableUndoError, "\(failure)")
    }

    /// Undo runs the members in reverse. The record keeps the failing member first, so it runs last
    /// next time, and then the members never attempted.
    func testTheRecordKeepsTheFailingMemberToRunLastAndTheMembersNeverAttempted() throws {
        let members = ["A", "B", "C", "D"].map(deleted)
        let failure = UndoOperation.batchUndoFailure(members: members,
                                                     interrupted: .init(completed: 2, underlying: SaveFailed.failed),
                                                     describe: { _ in "eventkit_error_1" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(titles(partial.remaining), ["B", "A"], "D and C were restored; B failed; A never ran")
        XCTAssertEqual(partial.restoredCount, 2)
    }

    func testAFailedFirstWriteMovesThatMemberLastWithNothingWritten() async throws {
        let log = ExecutionLog()
        let error = await undoBatch(["A", "B", "C"].map(deleted), log: log, failsOn: { $0 == "C" })
        let partial = try XCTUnwrap(error as? UndoBatchPartiallyUndoneError, "\(String(describing: error))")
        XCTAssertEqual(partial.restoredCount, 0)
        XCTAssertEqual(titles(partial.remaining), ["C", "A", "B"])
        XCTAssertEqual(log.executed, [])
    }

    /// A member that keeps failing no longer stalls the members behind it (PR #282 round 1, 9).
    func testARetryAfterADeterministicFailureReachesTheMembersNeverAttempted() async throws {
        let log = ExecutionLog()
        let first = await undoBatch(["A", "B", "C", "D"].map(deleted), log: log, failsOn: { $0 == "B" })
        let kept = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))").remaining
        let second = await undoBatch(kept, log: log, failsOn: { $0 == "B" })

        let partial = try XCTUnwrap(second as? UndoBatchPartiallyUndoneError, "\(String(describing: second))")
        XCTAssertEqual(log.executed, ["D", "C", "A"], "A, never attempted the first time, is restored on the retry")
        XCTAssertEqual(titles(partial.remaining), ["B"])
        XCTAssertEqual(partial.restoredCount, 1)
    }

    func testARetryAfterATransientFailureRestoresEachMemberOnce() async throws {
        let log = ExecutionLog()
        var failB = true
        let first = await undoBatch(["A", "B", "C", "D"].map(deleted), log: log,
                                    failsOn: { title in
                                        guard title == "B", failB else { return false }
                                        failB = false
                                        return true
                                    })
        let kept = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError).remaining
        let second = await undoBatch(kept, log: log, failsOn: { _ in false })

        XCTAssertNil(second)
        XCTAssertEqual(log.executed, ["D", "C", "A", "B"], "each member restored exactly once")
    }

    /// No batch whose members write on redo is recorded (#247); redo keeps the member error.
    func testRedoReportsTheMemberErrorAsItIs() async {
        do {
            _ = try await UndoBatchExecution.run(["A", "B"].map(deleted), verb: .redo, check: { _ in }, execute: { member in
                if self.titles([member])[0] == "B" { throw SaveFailed.failed }
                return "ok"
            }, describe: { _ in "unused" })
            XCTFail("the failure must surface")
        } catch {
            XCTAssertTrue(error is SaveFailed, "\(error)")
        }
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
        XCTAssertEqual(titles(partial.remaining), ["[Y]", "X"])
    }

    func testThePartialErrorSaysWhatWasRestoredAndKeptAndHowToGiveUp() {
        let error = UndoBatchPartiallyUndoneError(remaining: [deleted("A"), deleted("B")], restoredCount: 3,
                                                  memberError: "eventkit_error_1")
        XCTAssertTrue(error.message.contains("3 items were restored"), error.message)
        XCTAssertTrue(error.message.contains("2 items not yet restored"), error.message)
        XCTAssertTrue(error.message.contains("same id"), error.message)
        XCTAssertTrue(error.message.contains("discard_id"), error.message)
        // The member's own error comes last, after this message's advice (round 1, 16).
        XCTAssertTrue(error.message.hasSuffix("superseded by this message: eventkit_error_1"), error.message)
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue((error as Error) is TrustedErrorMessage)

        let nothing = UndoBatchPartiallyUndoneError(remaining: [deleted("A"), deleted("B")], restoredCount: 0,
                                                    memberError: "eventkit_error_1")
        XCTAssertTrue(nothing.message.contains("wrote nothing") && nothing.message.contains("tries the other item first"),
                      nothing.message)
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

    /// PR #282 round 1, finding 25: the partial error crosses from the EventKit actor to the server
    /// holding `UndoOperation` values, so both must be Sendable; this does not compile otherwise.
    func testThePartialErrorAndTheRecordsItHoldsAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(UndoOperation.self)
        requireSendable(UndoBatchPartiallyUndoneError.self)
    }
}
