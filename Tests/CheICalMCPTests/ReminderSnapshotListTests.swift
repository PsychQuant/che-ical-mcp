import EventKit
import XCTest
@testable import CheICalMCP

/// #242: undo of `update_reminder` / `delete_reminder` picked the list by title, so with two
/// same-named lists in different accounts the reminder went to whichever came first, and a
/// renamed or deleted list left it where it was (update-undo) or without a list (delete-undo,
/// a raw EventKit error). The list is now looked up by its recorded identifier only, as event
/// undo looks up the calendar (#208), and a missing list is refused with a message naming it.
final class ReminderSnapshotListTests: XCTestCase {
    /// The snapshot reads the list from the reminder, so the store lives as long as the test.
    private let store = EKEventStore()
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func list(_ title: String) -> EKCalendar {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        return list
    }

    private func reminder(in list: EKCalendar, title: String) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        return reminder
    }

    private func snapshot(listTitle: String = "Reminders", reminderTitle: String = "Water plants") -> ReminderSnapshot {
        ReminderSnapshot(from: reminder(in: list(listTitle), title: reminderTitle))
    }

    private func missingListError(_ body: () throws -> Any) -> EventKitError? {
        do {
            _ = try body()
            XCTFail("expected the missing list to be refused")
            return nil
        } catch let error as EventKitError {
            guard case .undoListMissing = error else {
                XCTFail("unexpected error: \(error)")
                return nil
            }
            return error
        } catch {
            XCTFail("unexpected error: \(error)")
            return nil
        }
    }

    private func message(list: String = "Reminders", account: String? = "iCloud", reminder: String = "Water plants",
                         hasIdentifier: Bool = true, kind: ReminderRestoreKind) throws -> String {
        try XCTUnwrap(EventKitError.undoListMissing(list: list, account: account, reminder: reminder,
                                                    hasIdentifier: hasIdentifier, kind: kind).errorDescription)
    }

    // MARK: - Lookup by identifier

    func testTheRecordedIdentifierWinsOverASameNamedListInAnotherAccount() throws {
        let saved = snapshot()
        let lists = [(id: "other-account", title: "Reminders"), (id: saved.calendarIdentifier, title: "Reminders")]

        let resolved = try saved.resolveList(in: lists, identifier: { $0.id }, for: .revertUpdate)

        XCTAssertEqual(resolved.id, saved.calendarIdentifier)
    }

    func testARenamedListIsFoundByItsIdentifier() throws {
        let saved = snapshot(listTitle: "Groceries")
        let lists = [(id: "other", title: "Groceries"), (id: saved.calendarIdentifier, title: "Shopping")]

        let resolved = try saved.resolveList(in: lists, identifier: { $0.id }, for: .recreateDeleted)

        XCTAssertEqual(resolved.title, "Shopping")
    }

    /// Never falls back to a list with the recorded title.
    func testAMissingListIsRefusedEvenBesideAListWithItsTitle() {
        let saved = snapshot(listTitle: "Groceries")
        let lists = [(id: "other-account", title: "Groceries")]

        XCTAssertNotNil(missingListError { try saved.resolveList(in: lists, identifier: { $0.id }, for: .revertUpdate) })
    }

    /// The match itself, on any recorded identifier (closure seam): an empty one never matches,
    /// not even a list whose identifier is empty too.
    func testAnEmptyRecordedIdentifierMatchesNoList() {
        struct Missing: Error {}
        XCTAssertThrowsError(try ReminderSnapshot.list(recorded: "", in: [(id: "", title: "Reminders")], identifier: { $0.id },
                                                       orThrow: { Missing() })) { XCTAssertTrue($0 is Missing) }
        XCTAssertEqual(try ReminderSnapshot.list(recorded: "b", in: [(id: "a", title: "x"), (id: "b", title: "y")],
                                                 identifier: { $0.id }, orThrow: { Missing() }).title, "y")
    }

    // MARK: - Resolve, then write (the restore of one reminder)

    /// A refusal writes nothing: the update-undo target keeps its list, title and due.
    func testARefusalLeavesTheReminderAsItWas() throws {
        let saved = snapshot(listTitle: "Groceries", reminderTitle: "Before")
        let current = list("Inbox")
        let target = reminder(in: current, title: "Now")
        let due = DateComponents(year: 2026, month: 10, day: 12)
        target.dueDateComponents = due

        XCTAssertNotNil(missingListError {
            try saved.apply(to: target, lists: [current, list("Groceries")], for: .revertUpdate, now: now)
        })

        XCTAssertTrue(target.calendar === current)
        XCTAssertEqual(target.title, "Now")
        XCTAssertEqual(target.dueDateComponents?.day, 12)
    }

    /// The reminder goes back to the recorded list, found by identifier, with its recorded fields.
    func testTheRestoreWritesTheRecordedListAndFields() throws {
        let recorded = list("Groceries")
        let saved = ReminderSnapshot(from: reminder(in: recorded, title: "Before"))
        let current = list("Inbox")
        let target = reminder(in: current, title: "Now")
        recorded.title = "Shopping"   // renamed since

        try saved.apply(to: target, lists: [current, list("Groceries"), recorded], for: .revertUpdate, now: now)

        XCTAssertTrue(target.calendar === recorded)
        XCTAssertEqual(target.title, "Before")
    }

    // MARK: - The refusal

    /// The message names the list and the reminder as `undoShownTitle` shows them: a shared list's
    /// title is set by someone else (#37 F1), so a quote cannot close the quotes and hidden
    /// characters are dropped.
    func testTheRefusalNamesTheListAndTheReminder() throws {
        let saved = snapshot(listTitle: "Shop'ping\u{7}", reminderTitle: "Buy\u{202E} milk")

        let error = try XCTUnwrap(missingListError {
            try saved.resolveList(in: [(id: "x", title: "y")], identifier: { $0.id }, for: .recreateDeleted)
        })
        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message.contains("list 'Shop\u{2019}ping'"), message)
        XCTAssertTrue(message.contains("reminder 'Buy milk'"), message)
        XCTAssertFalse(message.contains("\u{7}"))
        XCTAssertFalse(message.contains("\u{202E}"))
    }

    /// The record is kept, and the claim is about this reminder only: in a batch undo, other
    /// members may already have been written (M3).
    func testTheRefusalKeepsTheRecordAndSpeaksForThisReminderOnly() throws {
        let saved = snapshot()

        let error = try XCTUnwrap(missingListError {
            try saved.resolveList(in: [(id: "x", title: "Reminders")], identifier: { $0.id }, for: .revertUpdate)
        })
        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue(message.contains("Nothing was written for this reminder"), message)
        XCTAssertFalse(message.contains("Nothing was written."), message)
        XCTAssertTrue(message.contains("the history entry was kept"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
    }

    /// Giving up cannot be reversed. For a delete-undo that loses the deleted reminder; for an
    /// update-undo the reminder simply stays as it is now (M1).
    func testTheRefusalSaysWhatGivingUpLoses() throws {
        let delete = try message(kind: .recreateDeleted)
        XCTAssertTrue(delete.contains("cannot be reversed"), delete)
        XCTAssertTrue(delete.contains("cannot recover the deleted reminder"), delete)

        let update = try message(kind: .revertUpdate)
        XCTAssertTrue(update.contains("cannot be reversed"), update)
        XCTAssertTrue(update.contains("the reminder stays as it is now"), update)
        XCTAssertFalse(update.contains("deleted reminder"), update)
    }

    /// A list recorded without an identifier cannot be found: no retry is offered.
    func testARecordWithoutAnIdentifierOffersNoRetry() throws {
        let withID = try message(kind: .revertUpdate)
        XCTAssertTrue(withID.contains("Run undo again"), withID)

        let without = try message(hasIdentifier: false, kind: .revertUpdate)
        XCTAssertTrue(without.contains("recorded without an identifier"), without)
        XCTAssertFalse(without.contains("again"), without)
    }

    /// The account is named too, shown the same way (an account title can be set by a server);
    /// a title that shows as nothing is left out rather than shown as ''.
    func testTheRefusalNamesTheAccountAndLeavesOutEmptyTitles() throws {
        XCTAssertTrue(try message(account: "Ex'change\u{200B}", kind: .revertUpdate).contains("account 'Ex\u{2019}change'"))

        let bare = try message(list: "\u{200B}", account: nil, reminder: "", kind: .revertUpdate)
        XCTAssertFalse(bare.contains("''"), bare)
        XCTAssertFalse(bare.contains("account '"), bare)
    }
}
