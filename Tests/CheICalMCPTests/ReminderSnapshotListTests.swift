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

    private func snapshot(listTitle: String = "Reminders", reminderTitle: String = "Water plants") -> ReminderSnapshot {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listTitle
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = reminderTitle
        return ReminderSnapshot(from: reminder)
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

    func testTheRecordedIdentifierWinsOverASameNamedListInAnotherAccount() throws {
        let saved = snapshot()
        let lists = [(id: "other-account", title: "Reminders"), (id: saved.calendarIdentifier, title: "Reminders")]

        let resolved = try saved.resolveList(in: lists, identifier: { $0.id })

        XCTAssertEqual(resolved.id, saved.calendarIdentifier)
    }

    func testARenamedListIsFoundByItsIdentifier() throws {
        let saved = snapshot(listTitle: "Groceries")
        let lists = [(id: "other", title: "Groceries"), (id: saved.calendarIdentifier, title: "Shopping")]

        let resolved = try saved.resolveList(in: lists, identifier: { $0.id })

        XCTAssertEqual(resolved.title, "Shopping")
    }

    /// Never falls back to a list with the recorded title.
    func testAMissingListIsRefusedEvenBesideAListWithItsTitle() {
        let saved = snapshot(listTitle: "Groceries")
        let lists = [(id: "other-account", title: "Groceries")]

        XCTAssertNotNil(missingListError { try saved.resolveList(in: lists, identifier: { $0.id }) })
    }

    /// The message names the list and the reminder as `undoShownTitle` shows them: a shared list's
    /// title is set by someone else (#37 F1), so a quote cannot close the quotes and hidden
    /// characters are dropped.
    func testTheRefusalNamesTheListAndTheReminder() throws {
        let saved = snapshot(listTitle: "Shop'ping\u{7}", reminderTitle: "Buy\u{202E} milk")

        let error = try XCTUnwrap(missingListError { try saved.resolveList(in: [(id: "x", title: "y")], identifier: { $0.id }) })
        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message.contains("the list 'Shop\u{2019}ping'"), message)
        XCTAssertTrue(message.contains("the reminder 'Buy milk'"), message)
        XCTAssertFalse(message.contains("\u{7}"))
        XCTAssertFalse(message.contains("\u{202E}"))
    }

    /// Nothing is written, the record is kept, and the message says how to give the undo up.
    func testTheRefusalKeepsTheRecordAndNamesDiscardID() throws {
        let saved = snapshot()

        let error = try XCTUnwrap(missingListError { try saved.resolveList(in: [(id: "x", title: "Reminders")], identifier: { $0.id }) })
        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("this history entry was kept"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
    }

    /// A list recorded without an identifier cannot be found, even next to a list whose identifier
    /// is empty too; the message does not offer a retry.
    func testAnEmptyRecordedIdentifierIsRefused() throws {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = "Reminders"
        list.setValue("", forKey: "calendarIdentifier")   // no public setter; an empty identifier is otherwise unreachable here
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        let saved = ReminderSnapshot(from: reminder)
        XCTAssertEqual(saved.calendarIdentifier, "", "precondition")

        let error = try XCTUnwrap(missingListError { try saved.resolveList(in: [(id: "", title: "Reminders")], identifier: { $0.id }) })
        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message.contains("recorded without an identifier"), message)
        XCTAssertFalse(message.contains("again"), message)
    }

    /// The account the list belongs to is named too, shown the same way (an account title can be
    /// set by a server).
    func testTheRefusalNamesTheAccount() throws {
        let error = EventKitError.undoListMissing(list: "Reminders", account: "Ex'change\u{200B}", reminder: "Water plants", hasIdentifier: true)
        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message.contains("in the account 'Ex\u{2019}change'"), message)

        let withoutAccount = try XCTUnwrap(EventKitError.undoListMissing(list: "Reminders", account: nil, reminder: "Water plants", hasIdentifier: true).errorDescription)
        XCTAssertFalse(withoutAccount.contains("account '"), withoutAccount)
    }
}
