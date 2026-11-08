import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #248: a batch undo is refused before any write when a member's calendar or list is gone or
/// read-only (B), and a failure part-way keeps only the members not yet restored (A). The
/// snapshots are built in memory by `UndoSnapshotFixtures` on its one shared in-memory store,
/// which is never fetched from or saved to, and the batch runs through `UndoBatchRunner`'s
/// closures, so no store with the user's data is read or written.
final class UndoBatchRestoreTests: XCTestCase {
    // Static, so each fixture is built once per class when first used: instance properties are
    // built for every test when XCTest assembles the suite (#283).
    private static let eventFixture = UndoSnapshotFixtures.event(title: "Standup")
    private static let reminderFixture = UndoSnapshotFixtures.reminder(title: "Pay rent")
    /// A weekly series, so its delete-undo recreates it from its rules (#278, #285). Built by
    /// `UndoSnapshotFixtures` like the others (PR #282 round 5, finding 13).
    private static let seriesFixture = UndoSnapshotFixtures.event(title: "Weekly", weeklyOccurrences: 3)
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
        XCTAssertTrue(message.contains("The other item's calendar or list is in place"), message)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("discard_id drops all 3 items of this entry, including the 1 whose calendar or list is in place"), message)
    }

    /// PR #282 round 4, finding 8: "the other 2 is in place" for more than one.
    func testTheRefusalCountsSeveralItemsInPlaceInThePlural() {
        let gone = UndoSnapshotFixtures.event(title: "Gone")
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: gone), .deleteEvent(snapshot: event),
                                                      .deleteReminder(snapshot: reminder)], verb: .undo)
        let found = problems(destinations, eventCalendars: [(event.calendarIdentifier, "Work", true)],
                             reminderLists: [(reminder.calendarIdentifier, "Reminders", true)])
        XCTAssertEqual(found.map(\.destination.itemTitle), ["Gone"])
        let message = refusal(found, total: 3)
        XCTAssertTrue(message.contains("The other 2 items' calendars or lists are in place"), message)
        XCTAssertTrue(message.contains("including the 2 whose calendars or lists are in place"), message)
        XCTAssertFalse(message.contains("other 2 is"), message)
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

    /// PR #282 round 5, finding 8 (#37): the refusal is a trusted message beside the discard_id
    /// directive, so it names no calendar or list (a shared or subscribed one's title is set
    /// remotely) and no account (often an e-mail address). It says what kind of container, why,
    /// and which of the user's own items it holds.
    func testTheRefusalNamesNoCalendarListOrAccount() {
        let shared = UndoSnapshotFixtures.event(title: "Standup", calendarTitle: "Team Calendar (shared)")
        XCTAssertEqual(shared.calendarTitle, "Team Calendar (shared)", "precondition: the fixture records its calendar's title")
        let destinations = UndoRestoreDestination.of([.deleteEvent(snapshot: shared), .deleteReminder(snapshot: reminder)], verb: .undo)
        let found = problems(destinations, reminderLists: [(reminder.calendarIdentifier, "Reminders", false)])
        let message = refusal(found, total: 2)
        XCTAssertFalse(message.contains("Team Calendar"), message)
        XCTAssertTrue(message.contains("1 event in a calendar that is not available: 'Standup'"), message)
        XCTAssertTrue(message.contains("1 reminder in a list that is read-only: 'Pay rent'"), message)
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
            case .deleteReminder(let snapshot): return "rem:" + snapshot.title
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

    /// What the delete-undo arms return for `member` when nothing is held or recorded otherwise
    /// (#323): an occurrence comes back as a one-off, a series from its rules (with its exceptions
    /// applied, counting none, when it recorded them).
    private static func simulatedEvents(_ member: UndoOperation) -> [UndoEventOutcome] {
        switch member {
        case .deleteOccurrence(_, let notCarriedOver): return [.occurrenceOneOff(notCarriedOver: notCarriedOver)]
        case .deleteEvent(let snapshot):
            guard snapshot.restoresFromRules else { return [] }
            return snapshot.exceptions == nil ? [.seriesFromRules] : [.seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0))]
        case .batch(let members): return members.reversed().flatMap(simulatedEvents)
        default: return []
        }
    }

    /// The text of a retry that restores `remaining` as `simulatedEvents` says.
    private func retryText(_ remaining: [UndoOperation]) -> String {
        UndoOperation.batchUndoneMessage(count: remaining.count, events: remaining.flatMap(Self.simulatedEvents))
    }

    /// Undoes `members` through the production helper, as `executeUndo(.batch)` does, with
    /// `failsOn` deciding which member writes fail; returns what it throws, or nil.
    private func undoBatch(_ members: [UndoOperation], log: ExecutionLog,
                           failsOn: @escaping (String) -> Bool) async -> Error? {
        do {
            _ = try await UndoBatchExecution.run(members, verb: .undo, check: { _ in }, restore: { member in
                let title = self.titles([member])[0]
                if failsOn(title) { throw SaveFailed.failed }
                log.executed.append(title)
                return UndoMemberOutcome(text: title, differing: [], events: Self.simulatedEvents(member))
            }, describe: { _ in "eventkit_error_1" })
            return nil
        } catch {
            return error
        }
    }

    /// #292 item 3: the only member left fails before anything is restored. The record is put back
    /// as it was, and the error, like every part-way error, says that the member's save may have
    /// written it, so a retry can add a second copy, and gives the member's own error last. It used
    /// to be the member error alone, which says nothing of the second copy.
    func testAFailureOfTheOnlyMemberAsksToCheckFirstAndEndsWithTheMemberError() throws {
        let failure = UndoOperation.batchUndoFailure(members: [deleted("A")],
                                                     interrupted: .init(completed: 0, underlying: SaveFailed.failed),
                                                     describe: { _ in "eventkit_error_1" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(titles(partial.remaining), ["A"], "the record as it was")
        XCTAssertEqual(partial.restoredCount, 0)
        XCTAssertEqual(partial.failing, .runsLast)
        XCTAssertTrue(partial.message.hasPrefix("Undo of this batch stopped with no item confirmed restored:"), partial.message)
        XCTAssertTrue(partial.message.contains("running undo again can add a second copy: check first."), partial.message)
        XCTAssertTrue(partial.message.hasSuffix(": eventkit_error_1"), partial.message)
        XCTAssertFalse(partial.message.contains("0 item") || partial.message.contains("the other"), partial.message)
        XCTAssertFalse(partial.message.contains("not only the one that failed"), "one item left: \(partial.message)")
    }

    // MARK: - #407: a failed member that shares its title says which one it is

    private func partialError(_ members: [UndoOperation], completed: Int, _ error: Error = SaveFailed.failed) throws
        -> UndoBatchPartiallyUndoneError {
        let failure = UndoOperation.batchUndoFailure(members: members, interrupted: .init(completed: completed, underlying: error),
                                                     describe: { _ in "eventkit_error_1" })
        return try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
    }

    private func standupOccurrence(_ start: String, allDay: Bool = false) -> UndoOperation {
        let formatter = ISO8601DateFormatter()
        return .deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Standup", startDate: formatter.date(from: start), allDay: allDay),
                          notCarriedOver: [])
    }

    /// The issue's example: the Mon, Tue and Wed occurrences of "Standup"; undo restores Wed, then
    /// Tue fails. The text names Tue by its start, in the host zone with its offset.
    func testAFailedOccurrenceSharingItsTitleIsNamedByItsStart() throws {
        let members = ["2026-11-02T01:00:00Z", "2026-11-03T01:00:00Z", "2026-11-04T01:00:00Z"].map { standupOccurrence($0) }
        let partial = try partialError(members, completed: 1)
        let tue = DateFormatter.machineReadable("yyyy-MM-dd'T'HH:mm:ssXXXXX", zone: .current)
            .string(from: ISO8601DateFormatter().date(from: "2026-11-03T01:00:00Z")!)
        XCTAssertTrue(partial.message.contains("The restore of 'Standup' (starting \(tue)) may have left something written"), partial.message)
        XCTAssertFalse(partial.message.contains("2026-11-04T"), "the restored Wed is not named: \(partial.message)")

        let lookup = try partialError(members, completed: 1, EventKitError.undoCalendarMissing(event: "Standup", hasIdentifier: true, kind: .recreateDeletedOccurrence))
        XCTAssertTrue(lookup.message.contains("'Standup' (starting \(tue)) failed before anything of it was written"), lookup.message)
    }

    /// An all-day member is named by its day only.
    func testAnAllDayMemberSharingItsTitleIsNamedByItsDay() throws {
        let start = DateFormatter.machineReadable("yyyy-MM-dd", zone: .current).date(from: "2026-11-03")!
        let members: [UndoOperation] = [
            .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Offsite", startDate: start, allDay: true)),
            .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Offsite", startDate: start.addingTimeInterval(86_400), allDay: true)),
        ]
        let partial = try partialError(members, completed: 1)
        XCTAssertTrue(partial.message.contains("The restore of 'Offsite' (starting 2026-11-03) may have left"), partial.message)
    }

    /// Reminders sharing a title are named by their due date (as recorded: a date, or a date and
    /// time); one without a due date keeps the title alone.
    func testAFailedReminderSharingItsTitleIsNamedByItsDueDate() throws {
        let dated = DateComponents(year: 2026, month: 11, day: 3)
        let timed = DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 30)
        let partial = try partialError([.deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent", due: dated)),
                                        .deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent", due: timed))],
                                       completed: 1)
        XCTAssertTrue(partial.message.contains("The restore of 'Pay rent' (due 2026-11-03) may have left"), partial.message)
        let timedFails = try partialError([.deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent", due: timed)),
                                           .deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent", due: dated))],
                                          completed: 1)
        XCTAssertTrue(timedFails.message.contains("The restore of 'Pay rent' (due 2026-11-04T09:30) may have left"), timedFails.message)
        let undated = try partialError([.deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent")),
                                        .deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: "Pay rent", due: dated))],
                                       completed: 1)
        XCTAssertTrue(undated.message.contains("The restore of 'Pay rent' may have left"), undated.message)
    }

    /// Distinct titles keep today's text, and the title sharing is counted across nested members.
    func testOnlyASharedTitleAddsTheStart() throws {
        let distinct = try partialError([standupOccurrence("2026-11-02T01:00:00Z"), deleted("Review")], completed: 0)
        XCTAssertTrue(distinct.message.contains("The restore of 'Review' may have left"), distinct.message)
        XCTAssertFalse(distinct.message.contains("(starting"), distinct.message)
        let nestedShare = try partialError([.batch([standupOccurrence("2026-11-02T01:00:00Z")]), standupOccurrence("2026-11-03T01:00:00Z")],
                                           completed: 0)
        XCTAssertTrue(nestedShare.message.contains("The restore of 'Standup' (starting "), nestedShare.message)
    }

    /// PR #390 round 1: the check-first sentence names the item that failed (its title shown
    /// through `undoShownTitle`), and a failure the restore raises before it writes anything (its
    /// calendar or list not found) says no second copy can come of it instead.
    func testThePartialErrorNamesTheFailedItemAndWhetherItCanHaveBeenWritten() throws {
        func partial(_ members: [UndoOperation], _ error: Error) throws -> UndoBatchPartiallyUndoneError {
            let failure = UndoOperation.batchUndoFailure(members: members, interrupted: .init(completed: 0, underlying: error),
                                                         describe: { _ in "eventkit_error_1" })
            return try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        }
        let saved = try partial([deleted("Bob's lunch")], SaveFailed.failed)
        XCTAssertTrue(saved.message.contains("The restore of 'Bob\u{2019}s lunch' may have left something written"), saved.message)
        XCTAssertTrue(saved.message.contains("running undo again can add a second copy: check first."), saved.message)

        let lookups: [Error] = [EventKitError.calendarNotFound(identifier: "cal-1"),
                                EventKitError.calendarNotFoundWithSource(name: "Work", source: "iCloud"),
                                EventKitError.undoListMissing(reminder: "R", hasIdentifier: true,
                                                              kind: .recreateDeleted)]
        for error in lookups {
            for members in [[reminderDeleted("R")], [deleted("A"), reminderDeleted("R")]] {
                let lookup = try partial(members, error)
                XCTAssertTrue(lookup.message.contains("'R' failed before anything of it was written"), "\(error): \(lookup.message)")
                XCTAssertFalse(lookup.message.contains("second copy") || lookup.message.contains("check first"), "\(error): \(lookup.message)")
            }
        }
        // #269: an event's recorded calendar not found (`undoCalendarMissing`) comes before any
        // write too, with and without a recorded identifier.
        for hasIdentifier in [true, false] {
            let error = EventKitError.undoCalendarMissing(event: "E", hasIdentifier: hasIdentifier, kind: .recreateDeleted)
            for members in [[deleted("E")], [deleted("A"), deleted("E")]] {
                let lookup = try partial(members, error)
                XCTAssertTrue(lookup.message.contains("'E' failed before anything of it was written"), "\(error): \(lookup.message)")
                XCTAssertFalse(lookup.message.contains("second copy") || lookup.message.contains("check first"), "\(error): \(lookup.message)")
            }
        }

        // #323 (PR #406): the part-way text names what the restored members did, from their outcomes,
        // next to the failed item and whether it can have been written.
        for (error, written) in [(SaveFailed.failed as Error, true),
                                 (EventKitError.undoCalendarMissing(event: "E", hasIdentifier: true, kind: .recreateDeleted), false)] {
            let failure = UndoOperation.batchUndoFailure(members: [deleted("E"), occurrence("O")],
                                                         interrupted: .init(completed: 1, underlying: error),
                                                         events: [.occurrenceOneOff(notCarriedOver: ["absolute_alarms"])],
                                                         describe: { _ in "eventkit_error_1" })
            let composed = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
            XCTAssertTrue(composed.message.contains("For the items restored: Not carried over: absolute_alarms"), composed.message)
            XCTAssertEqual(composed.message.contains("The restore of 'E' may have left something written"), written, composed.message)
            XCTAssertEqual(composed.message.contains("'E' failed before anything of it was written"), !written, composed.message)
            XCTAssertTrue(composed.message.hasSuffix(": eventkit_error_1"), composed.message)
        }

        // PR #390 round 2: a one-member batch whose series restore failed and was rolled back
        // (#285/#405) is an after-write failure, but neither a save that the store took nor a
        // reminder left pending: the sentence names no such cause.
        let series = try partial([deleted("S")], EventKitError.seriesExceptionsRestoreFailed(reason: "x"))
        XCTAssertTrue(series.message.contains("The restore of 'S' may have left something written, so running undo again can add a second copy: check first."), series.message)
        XCTAssertFalse(series.message.contains("the store took it") || series.message.contains("removal after a failed save"), series.message)

        // A nested batch's remainder has no one title: the sentence stays general.
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Y")], restoredCount: 0, memberError: "eventkit_error_1")
        let nested = try partial([.batch([deleted("Y")])], inner)
        XCTAssertTrue(nested.message.contains("Its restore may have left something written"), nested.message)
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
        XCTAssertTrue(partial.message.contains("no item confirmed restored") && !partial.message.contains("wrote nothing"), partial.message)
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

        let retry = retryText(partial.remaining)
        XCTAssertFalse(retry.contains(absoluteAlarmsNote), "reported once, in the partial error: \(retry)")
    }

    func testALossRestoredOnTheRetryIsReportedThenAndNotBefore() async throws {
        let log = ExecutionLog()
        let first = await undoBatch([moved("M"), deleted("B"), deleted("A")], log: log, failsOn: { $0 == "B" })
        let partial = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))")
        XCTAssertEqual(log.executed, ["A"])
        XCTAssertFalse(partial.message.contains(absoluteAlarmsNote), partial.message)

        let retry = retryText(partial.remaining)
        XCTAssertTrue(retry.contains(absoluteAlarmsNote), retry)
    }

    /// PR #282 round 3, finding 3: after #278, a whole-series delete recreated from its rules is
    /// disclosed too (`seriesRulesRestoreNote`, since #323 from the outcome the member returned), and the same once-only rule
    /// holds: a series restored before the failure is named in the partial error, not in the retry.
    func testASeriesRestoredBeforeAFailureIsDisclosedOnceAcrossTheRetry() async throws {
        let log = ExecutionLog()
        let series = UndoOperation.deleteEvent(snapshot: Self.seriesFixture)
        let first = await undoBatch([deleted("A"), series], log: log, failsOn: { $0 == "A" })
        let partial = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))")
        XCTAssertEqual(log.executed, ["Weekly"], "undo runs in reverse: the series, then A, which fails")
        XCTAssertTrue(partial.message.contains(UndoOperation.seriesRulesRestoreNote), partial.message)

        let retry = retryText(partial.remaining)
        XCTAssertFalse(retry.contains(UndoOperation.seriesRulesRestoreNote), "disclosed once, in the partial error: \(retry)")
    }

    func testASeriesRestoredOnTheRetryIsDisclosedThenAndNotBefore() async throws {
        let log = ExecutionLog()
        let series = UndoOperation.deleteEvent(snapshot: Self.seriesFixture)
        let first = await undoBatch([series, deleted("B"), deleted("A")], log: log, failsOn: { $0 == "B" })
        let partial = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))")
        XCTAssertEqual(log.executed, ["A"])
        XCTAssertFalse(partial.message.contains(UndoOperation.seriesRulesRestoreNote), partial.message)

        let retry = retryText(partial.remaining)
        XCTAssertTrue(retry.contains(UndoOperation.seriesRulesRestoreNote), retry)
    }

    /// A nested batch that stopped part-way carries its own restored members up.
    func testANestedBatchCarriesItsRestoredMembersLossUp() throws {
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Y")], restoredCount: 1, memberError: "eventkit_error_1",
                                                  restored: [moved("Z")], restoredEvents: [.occurrenceOneOff(notCarriedOver: ["absolute_alarms"])])
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
        // Round 7, finding 5: the failing member may have been written, so the text does not say
        // "wrote nothing"; it says no item is confirmed restored.
        XCTAssertTrue(nothing.message.contains("no item confirmed restored") && nothing.message.contains("tries the other item first"),
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

    /// PR #282 round 4, findings 9 and 18: with only the failing item left, there are no "others"
    /// for it to run after, and giving up drops only that item.
    func testThePartialErrorWithOnlyTheFailingItemLeftSpeaksOfThatItemAlone() async throws {
        let log = ExecutionLog()
        let error = await undoBatch(["A", "B"].map(deleted), log: log, failsOn: { $0 == "A" })
        let partial = try XCTUnwrap(error as? UndoBatchPartiallyUndoneError, "\(String(describing: error))")
        XCTAssertEqual(titles(partial.remaining), ["A"])
        XCTAssertTrue(partial.message.contains("kept with only the item that failed"), partial.message)
        XCTAssertFalse(partial.message.contains("after them"), partial.message)
        XCTAssertFalse(partial.message.contains("not only the one that failed"), partial.message)
        XCTAssertFalse(partial.message.contains("the whole batch"), partial.message)
    }

    // MARK: - A: which members may run last (PR #282 round 4, finding 2)

    private func edited(_ id: String) -> UndoOperation {
        .updateEvent(id: id, oldSnapshot: UndoSnapshotFixtures.event(title: id), saved: UndoSnapshotFixtures.event(title: id))
    }

    private func ids(_ operations: [UndoOperation]) -> [String] {
        operations.map { operation -> String in
            if case .updateEvent(let id, _, _) = operation { return id }
            return titles([operation])[0]
        }
    }

    /// Exhaustive, so a new record kind has to say whether a failed one may be moved to run last
    /// before it compiles. Every kind a batch builder records may (each restores one new item and
    /// reads no other member; the #244 marker never runs), and so may a batch of them. The kinds no
    /// batch records may not: two of them can write to one item, where the order matters.
    func testEveryKindABatchRecordsMayRunLastAndNoOtherKindMay() {
        let recorded: [UndoOperation] = [
            .deleteEvent(snapshot: event), .deleteOccurrence(snapshot: event, notCarriedOver: []),
            .deleteFollowingOccurrences(title: "Standup"), .deleteReminder(snapshot: reminder),
            .batch([.deleteEvent(snapshot: event), .deleteReminder(snapshot: reminder)]),
        ]
        for operation in recorded { XCTAssertTrue(operation.mayRunLastAfterAFailure, operation.description) }
        let others: [UndoOperation] = [
            .createEvent(id: "e", title: "Standup", created: event),
            edited("e"),
            .updateRecurringEvent(id: "e", title: "Standup", kind: .series),
            .moveEvent(id: "e", fromCalendarIdentifier: "a", toCalendarIdentifier: "b", title: "Standup", isSeries: false),
            .createReminder(id: "r", title: "Pay rent", created: reminder),
            .updateReminder(id: "r", oldSnapshot: reminder, saved: reminder),
            .completeReminder(id: "r", wasCompleted: false, requestedCompleted: true, completionDate: nil,
                              title: "Pay rent", redoCompletionDate: nil, wasRecurring: false),
            .completeRecurringReminder(before: ReminderCompletionSnapshot(id: "r", title: "Pay rent", calendarID: "c", sourceID: "s",
                                                                         isCompleted: false, hasRecurrence: true, due: nil,
                                                                         rules: [], completionDate: nil),
                                       requestedCompleted: true, redoCompletionDate: nil),
            .moveByCopy(original: event, isSplit: true, notCarriedOver: [], copyID: "c", copy: event),
            .batch([.deleteEvent(snapshot: event), edited("e")]),
        ]
        for operation in others { XCTAssertFalse(operation.mayRunLastAfterAFailure, operation.description) }
    }

    /// A batch holding a member that may not run last keeps the recorded order: after a write the
    /// failing member stays in its place and runs first again; with nothing written the record is put
    /// back whole, and the error says no item is confirmed restored and asks to check first (#292
    /// items 2 and 3).
    func testMembersThatMayNotRunLastKeepTheirRecordedOrder() throws {
        let members = ["A", "B", "C"].map(edited)
        let failure = UndoOperation.batchUndoFailure(members: members,
                                                     interrupted: .init(completed: 1, underlying: SaveFailed.failed),
                                                     describe: { _ in "eventkit_error_1" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(partial.failing, .inRecordedOrder)
        XCTAssertEqual(ids(partial.remaining), ["A", "B"], "C was restored; B failed and stays in its place")
        XCTAssertTrue(partial.message.contains("in their recorded order"), partial.message)

        let nothing = UndoOperation.batchUndoFailure(members: members,
                                                     interrupted: .init(completed: 0, underlying: SaveFailed.failed),
                                                     describe: { _ in "eventkit_error_1" })
        let whole = try XCTUnwrap(nothing as? UndoBatchPartiallyUndoneError, "\(nothing)")
        XCTAssertEqual(whole.failing, .inRecordedOrder)
        XCTAssertEqual(ids(whole.remaining), ["A", "B", "C"], "the record as it was")
        XCTAssertTrue(whole.message.hasPrefix("Undo of this batch stopped with no item confirmed restored:"), whole.message)
        XCTAssertTrue(whole.message.contains("check first"), whole.message)
    }

    /// #292 item 2: with no item restored, neither shape counts "0 items" or speaks of restored
    /// ones. Both are reached only through a nested batch whose own partial error restored nothing
    /// (no tool records one today): kept in recorded order, and run last as the only member left.
    func testANestedFailureWithNothingRestoredSaysNoItemIsConfirmedRestored() throws {
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Z"), deleted("Y")], restoredCount: 0,
                                                  memberError: "eventkit_error_1")
        let nested = UndoOperation.batch([deleted("Y"), deleted("Z")])
        let shapes: [(members: [UndoOperation], failing: UndoBatchPartiallyUndoneError.FailingMember)] = [
            ([edited("A"), nested], .inRecordedOrder),
            ([nested], .runsLast),
        ]
        for (members, failing) in shapes {
            let failure = UndoOperation.batchUndoFailure(members: members, interrupted: .init(completed: 0, underlying: inner),
                                                         describe: { _ in "unused" })
            let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
            XCTAssertEqual(partial.failing, failing)
            XCTAssertEqual(partial.restoredCount, 0)
            XCTAssertTrue(partial.message.hasPrefix("Undo of this batch stopped with no item confirmed restored:"), partial.message)
            for wrong in ["0 items", "0 item", "the other", "part-way", "restored ones"] {
                XCTAssertFalse(partial.message.contains(wrong), "\(failing): \(wrong): \(partial.message)")
            }
            XCTAssertTrue(partial.message.contains("check first"), partial.message)
            XCTAssertTrue(partial.message.hasSuffix(": eventkit_error_1"), partial.message)
        }
    }

    /// The reminder batch builder records only reminder deletes (#243).
    func testTheReminderBatchBuilderRecordsOnlyReminderDeletes() throws {
        let record = try XCTUnwrap(UndoOperation.reminderBatchDelete([reminder, UndoSnapshotFixtures.reminder(title: "Milk")]))
        guard case .batch(let members) = record else { return XCTFail("\(record)") }
        XCTAssertEqual(members.count, 2)
        for member in members {
            guard case .deleteReminder = member else { return XCTFail("\(member)") }
            XCTAssertTrue(member.mayRunLastAfterAFailure)
        }
    }

    /// PR #282 round 5, findings 1, 6, 9: a failed save may have written the item (an event that
    /// committed and then threw; a reminder whose removal after the failure failed), so the text
    /// says a retry can add a second copy. A reminder that a new store finds counts as restored
    /// (#280 round 7), so it is not one of them. Since PR #390 round 2 the text names no cause, so it
    /// also holds for a series restore that was rolled back (#285).
    func testThePartialErrorSaysARetryCanAddASecondCopy() {
        for restoredCount in [0, 2] {
            let error = UndoBatchPartiallyUndoneError(remaining: [deleted("A"), deleted("B")], restoredCount: restoredCount,
                                                      memberError: "eventkit_error_1")
            XCTAssertTrue(error.message.contains("running undo again can add a second copy"), error.message)
            XCTAssertTrue(error.message.contains("Its restore may have left something written"), error.message)
            XCTAssertFalse(error.message.contains("differs"), error.message)
        }
    }

    // MARK: - A: what a restored reminder's store holds differently (PR #282 round 5, finding 1)

    /// Undoes `members` through the outcome form of the helper, as `executeUndo(.batch)` does with
    /// `undoBatchMember`: `differs` maps a member's title to the field names its restore returns
    /// (#280: a recreated reminder whose save threw but which a new store finds with those fields
    /// differing counts as restored); `failsOn` decides which member writes fail.
    private func undoBatchReturningDifferences(_ members: [UndoOperation], differs: [String: [String]],
                                               nestedDiffering: [String: [UndoRestoredDifference]] = [:],
                                               failsOn: @escaping (String) -> Bool) async -> Result<[UndoRestoredDifference], Error> {
        do {
            let outcome = try await UndoBatchExecution.run(members, verb: .undo, check: { _ in }, restore: { member in
                let title = self.titles([member])[0]
                if failsOn(title) { throw SaveFailed.failed }
                if let nested = nestedDiffering[title] { return UndoMemberOutcome(text: title, differing: nested) }
                guard case .deleteReminder(let snapshot) = member else { return UndoMemberOutcome(text: title, differing: []) }
                return UndoMemberOutcome(text: title, differing: [UndoRestoredDifference(title: snapshot.title,
                                                                                        storeDiffers: differs[title] ?? [])])
            }, describe: { _ in "eventkit_error_1" })
            return .success(outcome.differing)
        } catch {
            return .failure(error)
        }
    }

    private func reminderDeleted(_ title: String) -> UndoOperation {
        .deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: title))
    }

    /// (a) A reminder restored as saved, and (b) one whose store holds fields differently: both
    /// count as restored (neither stays in the record); the batch text names the second, in #280's
    /// words (`NewObjectSave.differingFieldsNote`), joined by `UndoRestoredDifference.sentences`.
    func testAFinishedBatchNamesWhatARestoredReminderStoreHoldsDifferently() async throws {
        let members = [reminderDeleted("Differs"), reminderDeleted("AsSaved"), deleted("B")]
        let differing = try await undoBatchReturningDifferences(members, differs: ["rem:Differs": ["due", "title"]],
                                                                failsOn: { _ in false }).get()
        let text = UndoOperation.batchUndoneMessage(count: 3, differing: differing)
        XCTAssertEqual(text, "Undone batch (3 operations). Restored reminder 'Differs' — the store holds a different due, title; check it.")
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: 3), "Undone batch (3 operations)")
    }

    /// Pairing: only the members whose store holds fields differently are named, each with its own
    /// fields, in the order they ran; one restored as saved is not named.
    func testEachDifferingReminderIsNamedWithItsOwnFields() async throws {
        let members = [reminderDeleted("First"), reminderDeleted("Plain"), reminderDeleted("Second")]
        let differing = try await undoBatchReturningDifferences(members, differs: ["rem:First": ["notes"], "rem:Second": ["due", "priority"]],
                                                                failsOn: { _ in false }).get()
        let text = UndoOperation.batchUndoneMessage(count: 3, differing: differing)
        XCTAssertEqual(text, "Undone batch (3 operations)."
                       + " Restored reminder 'Second' — the store holds a different due, priority; check it."
                       + " Restored reminder 'First' — the store holds a different notes; check it.")
        XCTAssertFalse(text.contains("'Plain'"), text)
    }

    /// A batch that stops part-way names what the stores of the reminders it restored hold
    /// differently, once: the reminder is not in the narrowed record, and the retry's text covers
    /// only the members left.
    func testAReminderRestoredWithDifferingFieldsBeforeAFailureIsNamedInThePartialErrorOnly() async throws {
        let members = [deleted("A"), reminderDeleted("Differs")]
        let result = await undoBatchReturningDifferences(members, differs: ["rem:Differs": ["title"]], failsOn: { $0 == "A" })
        guard case .failure(let error) = result, let partial = error as? UndoBatchPartiallyUndoneError else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(partial.restoredDiffering, [UndoRestoredDifference(title: "Differs", storeDiffers: ["title"])])
        XCTAssertTrue(partial.message.contains("Restored reminder 'Differs' — the store holds a different title; check it."), partial.message)
        XCTAssertEqual(titles(partial.remaining), ["A"], "the reminder was restored and left the record")
        let retry = retryText(partial.remaining)
        XCTAssertFalse(retry.contains("the store holds"), retry)
    }

    /// A crafted title cannot add an entry outside its own quotes: the entries come from the names
    /// each member returned, and the title passes `undoShownTitle`, which turns its ASCII quotes
    /// into curly ones, so the title cannot close its entry's quote. Text that reads like another
    /// entry can still appear inside the quoted title (PR #282 round 6, finding 12); it does not
    /// become an entry. A member WITH differences and such a title yields exactly one entry, with
    /// its own fields; a member with none and a note-like title yields none (success text and
    /// part-way error alike).
    func testACraftedTitleYieldsOnlyTheEntryItsOwnNamesGive() async throws {
        let crafted = "x' — the store holds a different title; check it. Restored reminder 'y' — the store holds a different notes; check it"
        let entry = "Restored reminder '"
        let withDifferences = [reminderDeleted(crafted), deleted("B")]
        let differing = try await undoBatchReturningDifferences(withDifferences, differs: ["rem:" + crafted: ["due"]], failsOn: { _ in false }).get()
        let text = UndoOperation.batchUndoneMessage(count: 2, differing: differing)
        XCTAssertEqual(text.components(separatedBy: entry).count - 1, 1, text)
        XCTAssertEqual(text.components(separatedBy: "' — ").count - 1, 1, "one quote closes, before the entry's own note: \(text)")
        XCTAssertTrue(text.hasSuffix("— the store holds a different due; check it."), text)
        let partial = UndoBatchPartiallyUndoneError(remaining: [deleted("C")], restoredCount: 1, memberError: "eventkit_error_1",
                                                    restored: [withDifferences[0]], restoredDiffering: differing)
        XCTAssertEqual(partial.message.components(separatedBy: entry).count - 1, 1, partial.message)

        let withoutDifferences = [reminderDeleted(crafted), deleted("B")]
        let none = try await undoBatchReturningDifferences(withoutDifferences, differs: [:], failsOn: { _ in false }).get()
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: 2, differing: none), "Undone batch (2 operations)")
        let quiet = UndoBatchPartiallyUndoneError(remaining: [deleted("C")], restoredCount: 1, memberError: "eventkit_error_1",
                                                  restored: [withoutDifferences[0]], restoredDiffering: none)
        XCTAssertEqual(quiet.message.components(separatedBy: entry).count - 1, 0, quiet.message)
    }

    /// PR #282 round 6, findings 13, 16: the entries are capped like the refusal's titles, so a
    /// cleanup of many reminders cannot grow the text without bound: the first five, then a count.
    func testTheDifferingEntriesAreCappedAtFiveThenCounted() {
        func differences(_ count: Int) -> [UndoRestoredDifference] {
            (1...count).map { UndoRestoredDifference(title: "R\($0)", storeDiffers: ["due"]) }
        }
        let entry = "Restored reminder '"
        let five = UndoRestoredDifference.sentences(differences(5))
        XCTAssertEqual(five.components(separatedBy: entry).count - 1, 5, five)
        XCTAssertFalse(five.contains("more restored"), five)
        let six = UndoRestoredDifference.sentences(differences(6))
        XCTAssertEqual(six.components(separatedBy: entry).count - 1, 5, six)
        XCTAssertFalse(six.contains("'R6'"), six)
        XCTAssertTrue(six.hasSuffix(" And 1 more restored reminder whose store holds some fields differently, not named here; check the reminders this batch restored."), six)
        let seven = UndoRestoredDifference.sentences(differences(7))
        XCTAssertTrue(seven.hasSuffix(" And 2 more restored reminders whose store holds some fields differently, not named here; check the reminders this batch restored."), seven)
        // Members restored as saved are not counted.
        let mixed = UndoRestoredDifference.sentences(differences(5) + [UndoRestoredDifference(title: "Plain", storeDiffers: [])])
        XCTAssertFalse(mixed.contains("more restored"), mixed)
    }

    /// PR #282 round 6, finding 18: every way a batch stops part-way names the differences of the
    /// reminders it restored: a member dropped for a permanent error, and members kept in their
    /// recorded order, as well as the usual failing member run last.
    func testEveryPartWayBranchNamesTheRestoredRemindersDifferences() throws {
        let difference = UndoRestoredDifference(title: "R", storeDiffers: ["notes"])
        let sentence = "Restored reminder 'R' — the store holds a different notes; check it."
        let dropped = UndoOperation.batchUndoFailure(members: [deleted("A"), deleted("B"), reminderDeleted("R")],
                                                     interrupted: .init(completed: 1, underlying: UnrecoverableUndoError(message: "x")),
                                                     differing: [difference], describe: { _ in "x" })
        let droppedPartial = try XCTUnwrap(dropped as? UndoBatchPartiallyUndoneError, "\(dropped)")
        XCTAssertEqual(droppedPartial.failing, .dropped)
        XCTAssertEqual(droppedPartial.restoredDiffering, [difference])
        XCTAssertTrue(droppedPartial.message.contains(sentence), droppedPartial.message)

        let ordered = UndoOperation.batchUndoFailure(members: [edited("A"), edited("B"), reminderDeleted("R")],
                                                     interrupted: .init(completed: 1, underlying: SaveFailed.failed),
                                                     differing: [difference], describe: { _ in "eventkit_error_1" })
        let orderedPartial = try XCTUnwrap(ordered as? UndoBatchPartiallyUndoneError, "\(ordered)")
        XCTAssertEqual(orderedPartial.failing, .inRecordedOrder)
        XCTAssertEqual(orderedPartial.restoredDiffering, [difference])
        XCTAssertTrue(orderedPartial.message.contains(sentence), orderedPartial.message)
    }

    /// PR #282 round 7, findings 9, 10: the title is shown by `UndoRestoredDifference` itself, so a
    /// caller cannot hand it a raw title: its ASCII quotes turn curly and its line breaks go.
    func testARestoredDifferenceShowsItsTitleItself() {
        let raw = "a'b\nc"
        let difference = UndoRestoredDifference(title: raw, storeDiffers: ["due"])
        XCTAssertEqual(difference.shownTitle, undoShownTitle(raw))
        XCTAssertFalse(difference.shownTitle.contains("'") || difference.shownTitle.contains("\n"), difference.shownTitle)
    }

    /// #280 round 8 made its batch note line-based; a title cannot start a line here either:
    /// `undoShownTitle` drops control characters, a line break among them, so a crafted title with
    /// a line break and a fake entry stays inside its own quoted entry.
    func testALineBreakInATitleCannotStartAnEntry() {
        let crafted = "x\nRestored reminder 'y' — the store holds a different notes; check it.\n"
        let shown = undoShownTitle(crafted)
        XCTAssertFalse(shown.contains("\n") || shown.contains("\r"), shown)
        let text = UndoRestoredDifference.sentences([UndoRestoredDifference(title: crafted, storeDiffers: ["due"])])
        XCTAssertFalse(text.contains("\n"), text)
        XCTAssertEqual(text.components(separatedBy: "Restored reminder '").count - 1, 1, text)
        XCTAssertTrue(text.hasSuffix("' — the store holds a different due; check it."), text)
    }

    /// PR #282 round 6, findings 2, 9: a nested batch member that finishes carries all of its
    /// restored reminders' differences up as data (`undoBatchMember` → `undoBatch(inner)`), as one
    /// that stops part-way does.
    func testAFinishedNestedBatchMemberCarriesItsDifferencesUp() async throws {
        let inner: UndoOperation = .batch([reminderDeleted("Y"), reminderDeleted("Z")])
        let nested = [UndoRestoredDifference(title: "Z", storeDiffers: ["due"]),
                      UndoRestoredDifference(title: "Y", storeDiffers: ["notes"])]
        let members = [deleted("X"), inner]
        let differing = try await undoBatchReturningDifferences(members, differs: [:], nestedDiffering: ["[rem:Y,rem:Z]": nested],
                                                                failsOn: { _ in false }).get()
        XCTAssertEqual(differing, nested)
        let text = UndoOperation.batchUndoneMessage(count: 2, differing: differing)
        XCTAssertTrue(text.contains("Restored reminder 'Z' — the store holds a different due; check it.")
                      && text.contains("Restored reminder 'Y' — the store holds a different notes; check it."), text)
    }

    /// PR #282 round 7, finding 2: when the failing member is a nested batch that stopped part-way,
    /// the outer members restored before it and the nested batch's own restored members are both
    /// named, outer first, and the cap counts them together.
    func testANestedFailureNamesTheOuterAndTheInnerRestoredDifferences() throws {
        // #292 item 4a: four outer reminders restored (`completed: 4`), each with its difference.
        let outer = (1...4).map { UndoRestoredDifference(title: "O\($0)", storeDiffers: ["due"]) }
        let innerDiffering = (1...3).map { UndoRestoredDifference(title: "I\($0)", storeDiffers: ["notes"]) }
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Y")], restoredCount: 3, memberError: "eventkit_error_1",
                                                  restoredDiffering: innerDiffering)
        let members: [UndoOperation] = [deleted("X"), .batch([deleted("Y")])] + (1...4).map { reminderDeleted("O\($0)") }
        let failure = UndoOperation.batchUndoFailure(members: members, interrupted: .init(completed: 4, underlying: inner),
                                                     differing: outer, describe: { _ in "unused" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(partial.restoredDiffering, outer + innerDiffering, "outer first, then the nested batch's")
        XCTAssertTrue(partial.message.contains("Restored reminder 'O1'"), partial.message)
        XCTAssertTrue(partial.message.contains("Restored reminder 'I1'"), partial.message)
        XCTAssertFalse(partial.message.contains("'I2'"), "the sixth and seventh are counted, not named: \(partial.message)")
        XCTAssertTrue(partial.message.contains("And 2 more restored reminders"), partial.message)
    }

    /// A nested batch that stopped part-way carries its restored reminders' differences up.
    func testANestedBatchCarriesItsRestoredDifferencesUp() throws {
        let difference = UndoRestoredDifference(title: "Z", storeDiffers: ["notes"])
        let inner = UndoBatchPartiallyUndoneError(remaining: [deleted("Y")], restoredCount: 1, memberError: "eventkit_error_1",
                                                  restoredDiffering: [difference])
        let failure = UndoOperation.batchUndoFailure(members: [deleted("X"), .batch([deleted("Y"), reminderDeleted("Z")])],
                                                     interrupted: .init(completed: 0, underlying: inner),
                                                     describe: { _ in "unused" })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(partial.restoredDiffering, [difference])
        XCTAssertTrue(partial.message.contains("Restored reminder 'Z' — the store holds a different notes; check it."), partial.message)
    }

    // MARK: - A: batch texts for one member (PR #282 round 5, findings 4, 12)

    /// Narrowing makes a batch of one usual, so its texts are in the singular.
    func testTheBatchTextsOfOneMemberAreSingular() async throws {
        let log = ExecutionLog()
        let first = await undoBatch(["A", "B"].map(deleted), log: log, failsOn: { $0 == "A" })
        let partial = try XCTUnwrap(first as? UndoBatchPartiallyUndoneError, "\(String(describing: first))")
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: partial.remaining.count),
                       "Undone batch (1 operation)")
        XCTAssertEqual(UndoOperation.batchUndoneMessage(count: 2), "Undone batch (2 operations)")
        XCTAssertEqual(UndoOperation.batchRedoneMessage(count: 1), "Redone batch (1 operation)")
        XCTAssertEqual(UndoOperation.batchRedoneMessage(count: 3), "Redone batch (3 operations)")
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
        XCTAssertEqual(after.entries.first?.description, "Batch (1 operation)", "#278 round 6: a batch of one in the singular")
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

    // MARK: - #322: a member that restores a series' exceptions

    private let exceptionsDay: TimeInterval = 86_400
    private var exceptionsStart: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private func exceptionsSlot(_ week: Int) -> Date { exceptionsStart.addingTimeInterval(Double(week) * 7 * exceptionsDay) }

    /// A series recorded with its exceptions (weeks 0 and 1 kept, week 2 edited, week 3 deleted).
    private func seriesWithExceptions() -> UndoOperation {
        let edited = UndoSnapshotFixtures.event(title: "Standup moved", startDate: exceptionsSlot(2).addingTimeInterval(1800))
        let exceptions = SeriesExceptions(
            window: DateInterval(start: exceptionsStart.addingTimeInterval(-exceptionsDay), end: exceptionsSlot(3).addingTimeInterval(exceptionsDay)),
            keptSlots: [exceptionsSlot(0), exceptionsSlot(1)], detached: [DetachedOccurrence(slot: exceptionsSlot(2), snapshot: edited)])
        return .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: exceptionsStart)
            .withExceptions(exceptions))
    }

    /// Each member through the real arms (`SeriesExceptionsUndo.undoDeleteEvent` /
    /// `undoDeleteOccurrence`) on `store`, carrying each arm's outcome up as `undoBatchMember` does
    /// (#323). Returns the member texts, which no batch text reads, and the outcomes.
    private func runOnStore(_ members: [UndoOperation], _ store: FakeSeriesExceptionsStore) async throws
        -> (texts: [String], events: [UndoEventOutcome]) {
        let outcome = try await UndoBatchExecution.run(members, verb: .undo, check: { _ in }, restore: { member in
            let undone: (text: String, outcome: UndoEventOutcome?)
            switch member {
            case .deleteEvent(let snapshot):
                undone = try SeriesExceptionsUndo.undoDeleteEvent(snapshot, calendar: snapshot.calendarIdentifier, in: store)
            case .deleteOccurrence(let snapshot, let notCarriedOver):
                undone = try SeriesExceptionsUndo.undoDeleteOccurrence(snapshot, notCarriedOver: notCarriedOver,
                                                                      calendar: snapshot.calendarIdentifier, in: store)
            default: throw SaveFailed.failed
            }
            return UndoMemberOutcome(text: undone.text, differing: [], events: undone.outcome.map { [$0] } ?? [])
        }, describe: { EventKitErrorSanitizer.sanitizeForResponse($0).code })
        return (outcome.texts, outcome.events)
    }

    /// #322: a batch with a member that restores a series' exceptions restores them (the series
    /// keeps its kept slots, the edited occurrence is a one-off) and its text carries the
    /// exceptions note once, beside a one-off member.
    func testABatchMemberRestoresTheSeriesExceptionsAndTheBatchTextSaysSo() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(exceptionsSlot)
        let members = [deleted("Review"), seriesWithExceptions()]

        let (texts, events) = try await runOnStore(members, store)

        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(store.events.filter { $0.title == "Standup" }.map(\.start).sorted(), [exceptionsSlot(0), exceptionsSlot(1)])
        XCTAssertEqual(store.events.filter { $0.title == "Standup moved" }.count, 1)
        let message = UndoOperation.batchUndoneMessage(count: texts.count, events: events)
        XCTAssertEqual(message, "Undone batch (2 operations). 1 series was restored from its rules with its exceptions inside the checked window: 1 occurrence(s) deleted on their own earlier stayed deleted, 1 occurrence(s) edited on their own came back as separate one-off events that no longer belong to their series. Exceptions outside the checked window (at most four years, from a year before the delete, or from the first occurrence when that is later, moved earlier for a rule that ends sooner) are not restored; those occurrences come back from the rules, and an occurrence edited on its own that was moved more than a year outside the window is neither restored nor listed, so its slot counts as deleted")
    }

    /// #321 (PR #318 round 3, finding 22): `delete_events_batch` with the series' identifier and an
    /// edited occurrence's own identifier records the occurrence as a rule-less `.deleteEvent`
    /// beside the series. Undo runs the members newest-first, so the series comes back from its rules
    /// first; the occurrence's record then finds its slot held by the recreated series and writes
    /// nothing. Before #321 it wrote a one-off there, so the occurrence was there twice.
    func testAnEditedOccurrenceDeletedBesideItsSeriesIsNotRestoredTwice() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(exceptionsSlot)
        let calendar = UndoSnapshotFixtures.newCalendar()
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: "S", externalIdentifier: "X-S")
        let occurrence = UndoSnapshotFixtures.event(title: "Standup moved", startDate: exceptionsSlot(2).addingTimeInterval(1800), calendar: calendar)
            .withOccurrenceOrigin(OccurrenceOrigin(series: seriesIDs, slot: exceptionsSlot(2)))
        let series = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4, startDate: exceptionsStart, calendar: calendar)
            .withSeriesIdentity(seriesIDs)

        let (_, events) = try await runOnStore([.deleteEvent(snapshot: occurrence), .deleteEvent(snapshot: series)], store)

        XCTAssertEqual(events, [.seriesFromRules, .occurrenceAlreadyHeld])
        XCTAssertEqual(store.events.filter { $0.title == "Standup moved" }.count, 0, "no second copy of the occurrence")
        XCTAssertEqual(store.events.filter { $0.title == "Standup" }.count, 4)
    }

    // MARK: - #323: the batch text from what the members did

    /// A series recorded with exceptions that the recreated series does not generate (a kept slot
    /// half an hour off the rule): none is applied.
    private func seriesWithUnmatchedExceptions(_ title: String) -> UndoOperation {
        let exceptions = SeriesExceptions(
            window: DateInterval(start: exceptionsStart.addingTimeInterval(-exceptionsDay), end: exceptionsSlot(3).addingTimeInterval(exceptionsDay)),
            keptSlots: [exceptionsSlot(0), exceptionsSlot(1).addingTimeInterval(1800)], detached: [])
        return .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 4, startDate: exceptionsStart)
            .withExceptions(exceptions))
    }

    /// A series whose first occurrence was deleted on its own: it is kept from the rule.
    private func seriesWithFirstDeleted(_ title: String) -> UndoOperation {
        let exceptions = SeriesExceptions(
            window: DateInterval(start: exceptionsStart.addingTimeInterval(-exceptionsDay), end: exceptionsSlot(3).addingTimeInterval(exceptionsDay)),
            keptSlots: [exceptionsSlot(1), exceptionsSlot(2), exceptionsSlot(3)], detached: [])
        return .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 4, startDate: exceptionsStart)
            .withExceptions(exceptions))
    }

    /// Three series through the real arm: one with its exceptions applied, one whose first
    /// occurrence is kept from the rule, one whose record did not match. The text sums what they
    /// returned, says per kind what happened, and no longer says it cannot.
    func testTheBatchTextSumsWhatEachSeriesMemberDid() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(exceptionsSlot)

        let (_, events) = try await runOnStore([seriesWithExceptions(), seriesWithFirstDeleted("Retro"), seriesWithUnmatchedExceptions("Sync")], store)
        let message = UndoOperation.batchUndoneMessage(count: 3, events: events)

        XCTAssertTrue(message.contains("2 series were restored from their rules with their exceptions inside the checked window: 1 occurrence(s) deleted on their own earlier stayed deleted, 1 occurrence(s) edited on their own came back"), message)
        XCTAssertTrue(message.contains("In 1 of them the first occurrence was edited or deleted on its own; it is kept from the rule"), message)
        XCTAssertTrue(message.contains("1 series was restored from its rules alone: its recorded exceptions did not match"), message)
        XCTAssertFalse(message.contains("cannot say"), message)
        XCTAssertFalse(message.contains(UndoOperation.seriesRulesRestoreNote), "no series came back without a record: \(message)")
    }

    /// An occurrence whose slot its series already holds wrote nothing: the batch text counts it as
    /// already restored and does not claim its absolute-date alarm moved; an occurrence that came
    /// back as a one-off with that loss is still named.
    func testAGuardSkippedOccurrenceIsCountedAndMakesNoAlarmClaim() async throws {
        let store = FakeSeriesExceptionsStore()
        let held = UndoSnapshotFixtures.event(title: "Standup", startDate: exceptionsSlot(1))
            .withOccurrenceOrigin(OccurrenceOrigin(series: .init(eventIdentifier: "S", externalIdentifier: "X-S"), slot: exceptionsSlot(1)))
        store.addSeries(id: "S", calendar: held.calendarIdentifier, title: "Standup", slots: [exceptionsSlot(0), exceptionsSlot(1)])
        let skipped = UndoOperation.deleteOccurrence(snapshot: held, notCarriedOver: ["absolute_alarms"])

        let (_, alone) = try await runOnStore([skipped], store)
        XCTAssertEqual(alone, [.occurrenceAlreadyHeld])
        let quiet = UndoOperation.batchUndoneMessage(count: 1, events: alone)
        XCTAssertEqual(quiet, "Undone batch (1 operation). 1 deleted occurrence was already restored by its series, so nothing was written for it")

        let free = UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Review", startDate: exceptionsSlot(2)),
                                                  notCarriedOver: ["absolute_alarms"])
        let (_, both) = try await runOnStore([skipped, free], store)
        let message = UndoOperation.batchUndoneMessage(count: 2, events: both)
        XCTAssertTrue(message.contains("Not carried over: absolute_alarms"), message)
        XCTAssertTrue(message.contains("1 deleted occurrence was already restored by its series"), message)
    }

    /// A batch stopped part-way names what the members it restored did, from their outcomes.
    func testAPartWayErrorNamesWhatTheRestoredSeriesDid() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(exceptionsSlot)
        store.failingSaveTitles = ["Fails"]
        do {
            // Undo runs in reverse: the series first (restored), then "Fails", whose save fails.
            _ = try await runOnStore([deleted("Never"), deleted("Fails"), seriesWithExceptions()], store)
            XCTFail("the failure must surface")
        } catch {
            let partial = try XCTUnwrap(error as? UndoBatchPartiallyUndoneError, "\(error)")
            XCTAssertEqual(partial.restoredEvents.count, 1)
            XCTAssertTrue(partial.message.contains("For the items restored: 1 series was restored from its rules with its exceptions inside the checked window: 1 occurrence(s) deleted on their own earlier stayed deleted"), partial.message)
        }
    }

    /// #322: the member's compensating delete fails (permanent, `UnrecoverableUndoError` from
    /// `SeriesExceptionsUndo.restoreFailure`): that member is dropped and the member never attempted
    /// is kept, as for any permanent member error (#248).
    func testAMemberWhoseCompensatingDeleteFailsIsDroppedAndTheRestKept() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(exceptionsSlot)
        store.failingSaveTitles = ["Standup moved"]
        store.seriesRemovalFails = true

        do {
            _ = try await runOnStore([deleted("Review"), seriesWithExceptions()], store)
            XCTFail("the failure must surface")
        } catch {
            let partial = try XCTUnwrap(error as? UndoBatchPartiallyUndoneError, "\(error)")
            XCTAssertEqual(titles(partial.remaining), ["Review"], "the series ran first (newest) and was dropped; Review never ran")
            XCTAssertEqual(partial.restoredCount, 0)
            XCTAssertTrue(partial.message.contains("dropped from this history entry"), partial.message)
        }
    }

    /// #322: alone, the same failure stands as the permanent error, and the record is discarded.
    func testAnOnlyMemberWhoseCompensatingDeleteFailsDiscardsTheRecord() async throws {
        let store = FakeSeriesExceptionsStore()
        store.seriesSlots = (0...3).map(exceptionsSlot)
        store.failingSaveTitles = ["Standup moved"]
        store.seriesRemovalFails = true

        do {
            _ = try await runOnStore([seriesWithExceptions()], store)
            XCTFail("the failure must surface")
        } catch {
            XCTAssertTrue(error is UnrecoverableUndoError, "\(error)")
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard)
        }
    }
}
