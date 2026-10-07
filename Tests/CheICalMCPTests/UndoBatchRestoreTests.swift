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
        XCTAssertTrue(message.contains("The calendar or list of the other 1 is in place"), message)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("discard_id drops all 3 items of this entry, including the 1 whose calendar or list is in place"), message)
    }

    /// PR #282 round 3, finding 7: the refusal said a batch undo restores all of its items or none of
    /// them, which a batch that stops part-way contradicts. It is this check that refuses the whole
    /// batch; and an item whose calendar or list is in place may still fail at its save.
    func testTheRefusalSaysItIsThisCheckThatRefusesTheWholeBatch() {
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event), .deleteReminder(snapshot: reminder)], verb: .undo)
        let message = refusal(problems(destinations, eventCalendars: [(event.calendarIdentifier, "Work", true)]), total: 2)
        XCTAssertTrue(message.contains("this check refuses the whole batch when any item's calendar or list is missing or read-only"), message)
        XCTAssertFalse(message.contains("all of its items or none of them"), message)
        XCTAssertFalse(message.contains("could be restored"), message)
    }

    func testARefusalOfEveryItemSaysNoneCouldBeRestored() {
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event)], verb: .undo)
        let message = refusal(problems(destinations), total: 1)
        XCTAssertTrue(message.contains("its 1 deleted item cannot be restored"), message)
        XCTAssertFalse(message.contains("The calendar or list of the other"), message)
        XCTAssertTrue(message.contains("discard_id drops the 1 item of this entry"), message)
        XCTAssertFalse(message.contains("1 items"), message)
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
            XCTAssertTrue(refusal.message.contains("its 1 deleted item cannot be restored"), refusal.message)
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

    /// PR #282 round 3, finding 1: a read-only destination may come from a stale view too (a shared
    /// calendar's or list's write access can change elsewhere), so it is read once more like a
    /// missing one before the refusal.
    func testADestinationReadOnlyOnTheFirstReadAndWritableAfterTheRefreshPasses() async throws {
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)
        let reads = Reads()
        try await verify(destinations, reads: reads) { read in
            ([], [(self.reminder.calendarIdentifier, "Shared", read > 1)])
        }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.invalidations, 1, "the view is invalidated before the second read")
    }

    func testADestinationStillReadOnlyAfterTheSecondReadIsRefused() async {
        let destinations = UndoRestoreDestination.of([.deleteReminder(snapshot: reminder)], verb: .undo)
        let reads = Reads()
        do {
            try await verify(destinations, reads: reads) { _ in ([], [(self.reminder.calendarIdentifier, "Shared", false)]) }
            XCTFail("expected a refusal")
        } catch let refusal as UndoRestoreDestinationMissingError {
            XCTAssertTrue(refusal.message.contains("is read-only"), refusal.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(reads.count, 2, "read once more, and only once")
        XCTAssertEqual(reads.invalidations, 1)
    }

    /// Each refused call marks the view stale again, so a retry refreshes as well: the refresh is
    /// only requested (EventKit syncs in the background), and what the first call's second read
    /// could not see yet, a retry may.
    func testEveryRefusedCallRefreshesAgain() async {
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: event)], verb: .undo)
        let reads = Reads()
        for _ in 0..<2 {
            do {
                try await verify(destinations, reads: reads) { _ in
                    ([(self.event.calendarIdentifier, "Holidays", false)], [])
                }
                XCTFail("expected a refusal")
            } catch {
                XCTAssertTrue(error is UndoRestoreDestinationMissingError, "\(error)")
            }
        }
        XCTAssertEqual(reads.invalidations, 2, "one refresh per refused call, as for a missing one")
        XCTAssertEqual(reads.count, 4)
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
            case .deleteOccurrence(let snapshot, _): return "occ:" + snapshot.title
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

    /// A permanent member error (`UnrecoverableUndoError`) means that member can never be restored.
    /// It is dropped and the members never attempted are kept, whether or not something was written
    /// first (PR #282 round 2, findings 8, 9, 12, 17); before, the first write's permanent error
    /// discarded the members never attempted with it.
    func testAPermanentFailureOfTheFirstWriteDropsOnlyThatMember() throws {
        let failure = UndoOperation.batchUndoFailure(members: [deleted("A"), deleted("B")],
                                                     interrupted: .init(completed: 0, underlying: UnrecoverableUndoError(message: "x")),
                                                     describe: { _ in "x" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(titles(partial.remaining), ["A"], "B ran first and can never be restored; A never ran")
        XCTAssertEqual(partial.restoredCount, 0)
        XCTAssertTrue(partial.message.contains("dropped from this history entry"), partial.message)
    }

    func testAPermanentFailureAfterAWriteDropsOnlyThatMember() throws {
        let failure = UndoOperation.batchUndoFailure(members: ["A", "B", "C"].map(deleted),
                                                     interrupted: .init(completed: 1, underlying: UnrecoverableUndoError(message: "x")),
                                                     describe: { _ in "x" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(titles(partial.remaining), ["A"], "C was restored, B dropped, A kept")
        XCTAssertEqual(partial.restoredCount, 1)
    }

    /// With nothing else waiting, the permanent error stands and discards the record, as for a
    /// single record.
    func testAPermanentFailureOfTheLastMemberStands() {
        let failure = UndoOperation.batchUndoFailure(members: [deleted("A")],
                                                     interrupted: .init(completed: 0, underlying: UnrecoverableUndoError(message: "x")),
                                                     describe: { _ in "x" })
        XCTAssertTrue(failure is UnrecoverableUndoError, "\(failure)")
    }

    /// With nothing else waiting after a write, the record has nothing left: the error still says
    /// what was restored, and `handleUndo` discards the record.
    func testAPermanentFailureAfterWritesWithNothingLeftReportsWhatWasRestored() throws {
        let failure = UndoOperation.batchUndoFailure(members: ["A", "B"].map(deleted),
                                                     interrupted: .init(completed: 1, underlying: UnrecoverableUndoError(message: "x")),
                                                     describe: { _ in "x" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertTrue(partial.remaining.isEmpty)
        XCTAssertEqual(partial.restoredCount, 1)
        XCTAssertTrue(partial.message.contains("1 item was restored") && partial.message.contains("discarded"), partial.message)
    }

    // MARK: - A: what restored occurrences did not carry over (PR #278 round 3, MEDIUM 2)

    private var absoluteAlarmsNote: String { "Not carried over: absolute_alarms" }

    private func moved(_ title: String) -> UndoOperation {
        .deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: title), notCarriedOver: ["absolute_alarms"])
    }

    /// The batch text names what restored occurrences did not carry over, but only for the members
    /// of the call it reports. A member restored before a failure was in neither text: not in the
    /// partial error, and not in the retry's, which holds only the members left. The partial error
    /// now names it, so every restored member's loss is reported exactly once.
    func testALossRestoredBeforeAFailureIsReportedOnceAcrossTheRetry() async throws {
        let log = ExecutionLog()
        let first = await undoBatch([deleted("A"), moved("M"), deleted("B")], log: log, failsOn: { $0 == "A" })
        let partial = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))")
        XCTAssertEqual(log.executed, ["B", "occ:M"])
        XCTAssertTrue(partial.message.contains(absoluteAlarmsNote), partial.message)

        let retry = UndoOperation.batchUndoneMessage(members: partial.remaining, count: partial.remaining.count)
        XCTAssertFalse(retry.contains(absoluteAlarmsNote), "reported once, in the partial error: \(retry)")
    }

    func testALossRestoredOnTheRetryIsReportedThenAndNotBefore() async throws {
        let log = ExecutionLog()
        let first = await undoBatch([moved("M"), deleted("B"), deleted("A")], log: log, failsOn: { $0 == "B" })
        let partial = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))")
        XCTAssertEqual(log.executed, ["A"])
        XCTAssertFalse(partial.message.contains(absoluteAlarmsNote), partial.message)

        let retry = UndoOperation.batchUndoneMessage(members: partial.remaining, count: partial.remaining.count)
        XCTAssertTrue(retry.contains(absoluteAlarmsNote), retry)
    }

    /// A nested batch that stopped part-way carries its own restored members up.
    func testANestedBatchCarriesItsRestoredMembersLossUp() throws {
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Y")], restoredCount: 1, memberError: "eventkit_error_1",
                                                  restored: [moved("Z")])
        let failure = UndoOperation.batchUndoFailure(members: [deleted("X"), .batch([deleted("Y"), moved("Z")])],
                                                     interrupted: .init(completed: 0, underlying: inner),
                                                     describe: { _ in "unused" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertTrue(partial.message.contains(absoluteAlarmsNote), partial.message)
    }

    // MARK: - A: occurrence deletes restore independently (PR #282 round 3, finding 5)

    private func occurrence(_ title: String) -> UndoOperation {
        .deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: title), notCarriedOver: [])
    }

    /// Each deleted occurrence comes back as its own one-off event (#244), reading no other
    /// member's result, so the order the members run in does not change what any of them
    /// restores. Round 2 kept the recorded order for them; round 3 found no dependence, and a
    /// member that kept failing then held back every occurrence behind it. The failing one is now
    /// moved to run last, as for whole-event and reminder deletes.
    func testAFailedOccurrenceIsMovedToRunLastWithNothingWritten() async throws {
        let log = ExecutionLog()
        let error = await undoBatch([occurrence("1"), occurrence("2")], log: log, failsOn: { $0 == "occ:2" })
        let partial = try XCTUnwrap(error as? UndoBatchPartiallyUndoneError, "\(String(describing: error))")
        XCTAssertEqual(titles(partial.remaining), ["occ:2", "occ:1"])
        XCTAssertEqual(partial.restoredCount, 0)
        XCTAssertEqual(log.executed, [])
    }

    func testARetryOfOccurrencesReachesTheOnesNeverAttempted() async throws {
        let log = ExecutionLog()
        let first = await undoBatch([occurrence("1"), occurrence("2"), occurrence("3")], log: log, failsOn: { $0 == "occ:2" })
        let kept = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))").remaining
        XCTAssertEqual(titles(kept), ["occ:2", "occ:1"])
        let second = await undoBatch(kept, log: log, failsOn: { $0 == "occ:2" })

        let partial = try XCTUnwrap(second as? UndoBatchPartiallyUndoneError, "\(String(describing: second))")
        XCTAssertEqual(log.executed, ["occ:3", "occ:1"], "occ:1, never attempted the first time, is restored on the retry")
        XCTAssertEqual(titles(partial.remaining), ["occ:2"])
    }

    /// The text no longer says the order of the members matters.
    func testNoPartialErrorSaysTheOrderMatters() async throws {
        let log = ExecutionLog()
        let error = await undoBatch([deleted("A"), occurrence("1"), occurrence("2")], log: log, failsOn: { $0 == "occ:1" })
        let partial = try XCTUnwrap(error as? UndoBatchPartiallyUndoneError, "\(String(describing: error))")
        XCTAssertEqual(titles(partial.remaining), ["occ:1", "A"])
        XCTAssertFalse(partial.message.contains("order"), partial.message)
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
    /// restored members are not recreated either, and it is moved to run last like any member.
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

    /// PR #282 round 3, findings 2 and 21: moving the failing item last helps only when its failure is
    /// not its calendar or list. If that is now missing or read-only, the next undo's pre-check
    /// refuses the whole batch before any write, so the text no longer gives a deleted calendar as
    /// the example of a failure that running last gets around.
    func testThePartialErrorSaysRunningLastDoesNotGetPastAMissingOrReadOnlyDestination() {
        for restoredCount in [0, 2] {
            let error = UndoBatchPartiallyUndoneError(remaining: [deleted("A"), deleted("B")], restoredCount: restoredCount,
                                                      memberError: "eventkit_error_1")
            XCTAssertTrue(error.message.contains("unless its calendar or list is now missing or read-only"), error.message)
            XCTAssertTrue(error.message.contains("refuses the whole batch before it writes anything"), error.message)
            XCTAssertFalse(error.message.contains("its calendar or list was deleted"), error.message)
            XCTAssertTrue(error.message.contains("drops every item not yet restored, not only the one that failed"), error.message)
        }
    }

    /// PR #282 round 3, finding 15: the `.dropped` branch, driven by a permanent error the undo arms
    /// really throw (the #244 marker's refusal; the batch pre-check refuses that marker first today,
    /// so this is the branch any later permanent member error takes). The member is dropped without
    /// a retry, so the text says its own error, which names it, follows.
    func testAPermanentErrorAtAWriteDropsThatMemberAndTheTextPointsToItsName() async throws {
        let log = ExecutionLog()
        var thrown: Error?
        do {
            _ = try await UndoBatchExecution.run(["A", "B", "C"].map(deleted), verb: .undo, check: { _ in }, execute: { member in
                let title = self.titles([member])[0]
                if title == "B" { throw UndoOperation.followingOccurrencesDeleteRefusal(title: "Standup") }
                log.executed.append(title)
                return title
            }, describe: { EventKitErrorSanitizer.sanitizeForResponse($0).code })
        } catch {
            thrown = error
        }
        let partial = try XCTUnwrap(thrown as? UndoBatchPartiallyUndoneError, "\(String(describing: thrown))")
        XCTAssertEqual(partial.failing, .dropped)
        XCTAssertEqual(titles(partial.remaining), ["A"], "C restored, B dropped, A never attempted and kept")
        XCTAssertEqual(log.executed, ["C"])
        XCTAssertTrue(partial.message.contains("its own error, which names it, follows"), partial.message)
        XCTAssertTrue(partial.message.contains("'Standup'"), partial.message)
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
