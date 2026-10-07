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
        // #244 (PR #278): a deleted occurrence is recreated as a one-off event in its calendar.
        guard case .eventCalendar(let occurrenceSnapshot)? = UndoOperation.deleteOccurrence(snapshot: event, notCarriedOver: [])
            .restoreDestination(verb: .undo) else {
            return XCTFail("a delete-occurrence undo recreates the occurrence in its recorded calendar")
        }
        XCTAssertEqual(occurrenceSnapshot.title, "Standup")

        let others: [UndoOperation] = [
            .deleteFollowingOccurrences(title: "Standup"),   // never restored: its undo is refused
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
        XCTAssertNil(UndoOperation.deleteOccurrence(snapshot: event, notCarriedOver: []).restoreDestination(verb: .redo))
        XCTAssertNil(UndoOperation.deleteReminder(snapshot: reminder).restoreDestination(verb: .redo))
    }

    // MARK: - B: the refusal (PR #282 round 2, findings 1 and 5)

    /// A calendar or list as the pre-check sees it: the store's lists, read once per batch.
    private typealias Container = (id: String, title: String, writable: Bool)

    private func problems(_ destinations: [UndoRestoreDestination], eventCalendars: [Container] = [],
                          reminderLists: [Container] = []) -> [UndoRestoreFinding] {
        UndoRestoreDestination.problems(among: destinations, eventCalendars: eventCalendars, reminderLists: reminderLists,
                                        identifier: { $0.id }, allowsModifications: { $0.writable })
    }

    private func refusal(_ findings: [UndoRestoreFinding], total: Int) -> String {
        UndoRestoreDestinationMissingError(findings: findings, total: total).message
    }

    /// The refusal says how many items could have been restored and which lists or calendars stop
    /// the rest, and that giving up drops every item of the entry, so the choice is informed.
    func testTheRefusalCountsWhatCouldBeRestoredAndNamesWhatIsMissing() {
        let rent = UndoSnapshotFixtures.reminder(title: "Pay rent")
        let milk = UndoSnapshotFixtures.reminder(title: "Milk")
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event), .deleteReminder(snapshot: rent),
                                                      .deleteReminder(snapshot: milk)], verb: .undo)
        let found = problems(destinations, eventCalendars: [(event.calendarIdentifier, "Work", true)])
        XCTAssertEqual(found.map(\.problem), [.missing, .missing])

        let message = refusal(found, total: 3)
        XCTAssertTrue(message.contains("2 of its 3 deleted items cannot be restored"), message)
        XCTAssertTrue(message.contains("is not available") && message.contains("'Pay rent'") && message.contains("'Milk'"), message)
        XCTAssertTrue(message.contains("The other 1 could be restored"), message)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("discard_id drops all 3 items of this entry, including the 1 that could be restored"), message)
    }

    func testARefusalOfEveryItemSaysNoneCouldBeRestored() {
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event)], verb: .undo)
        let message = refusal(problems(destinations), total: 1)
        XCTAssertTrue(message.contains("1 of its 1 deleted items cannot be restored"), message)
        XCTAssertFalse(message.contains("The other"), message)
        XCTAssertTrue(message.contains("discard_id drops all 1 items of this entry"), message)
    }

    /// Finding 5: a calendar or list that is found but does not allow changes (a read-only shared
    /// or subscribed one) would fail at save, part-way through the batch; the pre-check refuses it.
    func testAReadOnlyDestinationIsRefusedBeforeAnyWrite() {
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event), .deleteReminder(snapshot: reminder)], verb: .undo)
        let found = problems(destinations, eventCalendars: [(event.calendarIdentifier, "Holidays", false)],
                             reminderLists: [(reminder.calendarIdentifier, "Reminders", true)])
        XCTAssertEqual(found.map(\.problem), [.readOnly])
        XCTAssertEqual(found.first?.destination.itemTitle, "Standup")
        let message = refusal(found, total: 2)
        XCTAssertTrue(message.contains("is read-only"), message)
        XCTAssertTrue(message.contains("1 of its 2 deleted items cannot be restored"), message)
    }

    /// The titles come from the store (a shared calendar's title is set by someone else), so they
    /// pass `undoShownTitle` like every other undo error.
    func testTheRefusalShowsTitlesLikeTheOtherUndoErrors() {
        let hidden = UndoSnapshotFixtures.event(title: "Stand\u{202E}up 'x'")
        let message = refusal(problems(UndoRestoreDestination.of([.deleteEvent(snapshot: hidden)], verb: .undo)), total: 1)
        XCTAssertTrue(message.contains("'Standup \u{2019}x\u{2019}'"), message)
        XCTAssertFalse(message.unicodeScalars.contains { $0.value == 0x202E }, message)
    }

    /// Kept like a not-found (#191, #236 D2): the user can recreate the calendar or give up.
    func testTheRefusalKeepsTheRecordAndReachesTheClientVerbatim() {
        let findings = problems(UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo))
        let error: Error = UndoRestoreDestinationMissingError(findings: findings, total: 1)
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

    func testEveryDestinationWithAProblemIsReportedInRecordOrder() {
        let gone = UndoSnapshotFixtures.event(title: "Gone")
        XCTAssertNotEqual(event.calendarIdentifier, gone.calendarIdentifier, "precondition: fixtures have distinct calendars")
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event), .deleteEvent(snapshot: gone),
                                                      .deleteReminder(snapshot: reminder)], verb: .undo)
        let calendar: Container = (event.calendarIdentifier, event.calendarTitle, true)
        let list: Container = (reminder.calendarIdentifier, reminder.calendarTitle, true)

        XCTAssertEqual(problems(destinations, eventCalendars: [calendar]).map(\.destination.itemTitle), ["Gone", "Pay rent"])
        XCTAssertTrue(problems(destinations, eventCalendars: [calendar, (gone.calendarIdentifier, "", true)],
                               reminderLists: [list]).isEmpty)
    }

    /// PR #282 round 1, finding 1 (HIGH): the pre-check matched the list by title, so a list with the
    /// recorded title in another account passed it. It now makes the lookup the restore makes
    /// (`ReminderSnapshot.resolveList`, by recorded identifier), so that batch is refused before its
    /// first write, as the restore would refuse that member.
    func testAListWithTheRecordedTitleButAnotherIdentifierDoesNotPassThePreCheck() {
        XCTAssertFalse(reminder.calendarIdentifier.isEmpty)
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)

        XCTAssertEqual(problems(destinations, reminderLists: [("other-account", reminder.calendarTitle, true)]).map(\.problem),
                       [.missing], "a same-titled list in another account must not pass the pre-check")
        XCTAssertTrue(problems(destinations, reminderLists: [("other-account", reminder.calendarTitle, true),
                                                             (reminder.calendarIdentifier, "Renamed", true)]).isEmpty,
                      "the list with the recorded identifier passes, whatever its title is now")
    }

    /// The same for an event's calendar (`EventSnapshot.resolveCalendar`, #208).
    func testACalendarWithTheRecordedTitleButAnotherIdentifierDoesNotPassThePreCheck() {
        XCTAssertFalse(event.calendarIdentifier.isEmpty)
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event)], verb: .undo)

        XCTAssertEqual(problems(destinations, eventCalendars: [("other-account", event.calendarTitle, true)]).map(\.problem),
                       [.missing], "a same-titled calendar in another account must not pass the pre-check")
        XCTAssertTrue(problems(destinations, eventCalendars: [(event.calendarIdentifier, "Renamed", true)]).isEmpty)
    }

    // MARK: - B: refresh before refusing (PR #282 round 2, finding 2)

    /// A refusal writes nothing, so it set no refresh: a list missing only from a stale view of the
    /// store was refused on every retry. On a miss the pre-check invalidates the view and reads once
    /// more before it refuses.
    private final class Reads {
        var count = 0
        var invalidations = 0
    }

    private func verify(_ destinations: [UndoRestoreDestination], reads: Reads,
                        lists: @escaping (Int) -> (eventCalendars: [Container], reminderLists: [Container])) async throws {
        try await UndoRestoreDestination.verify(destinations, identifier: { $0.id }, allowsModifications: { $0.writable },
                                                read: { reads.count += 1; return lists(reads.count) },
                                                invalidate: { reads.invalidations += 1 })
    }

    func testAListMissingFromAStaleViewIsFoundOnTheSecondRead() async throws {
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)
        let reads = Reads()
        try await verify(destinations, reads: reads) { read in
            ([], read == 1 ? [] : [(self.reminder.calendarIdentifier, "Reminders", true)])
        }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.invalidations, 1, "the view is invalidated before the second read")
    }

    func testAListStillMissingAfterTheSecondReadIsRefused() async {
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)
        let reads = Reads()
        do {
            try await verify(destinations, reads: reads) { _ in ([], []) }
            XCTFail("expected a refusal")
        } catch let refusal as UndoRestoreDestinationMissingError {
            XCTAssertTrue(refusal.message.contains("1 of its 1"), refusal.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(reads.count, 2, "read once more, and only once")
        XCTAssertEqual(reads.invalidations, 1)
    }

    func testEveryDestinationFoundOnTheFirstReadNeedsNoSecondRead() async throws {
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)
        let reads = Reads()
        try await verify(destinations, reads: reads) { _ in ([], [(self.reminder.calendarIdentifier, "Reminders", true)]) }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.invalidations, 0)
    }

    /// A read-only destination is not a stale view: no second read, refused at once.
    func testAReadOnlyDestinationIsRefusedWithoutASecondRead() async {
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)
        let reads = Reads()
        do {
            try await verify(destinations, reads: reads) { _ in ([], [(self.reminder.calendarIdentifier, "Shared", false)]) }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error is UndoRestoreDestinationMissingError, "\(error)")
        }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.invalidations, 0)
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
