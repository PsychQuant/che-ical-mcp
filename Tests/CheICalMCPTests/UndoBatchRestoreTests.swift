import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #248: a batch undo restores every member or writes nothing when a member's calendar or list
/// is gone (B), and a failure part-way keeps only the members not yet restored (A). Pure: the
/// snapshots are built in memory and the batch runs through `UndoBatchRunner`'s closures, so no
/// EventKit store is read or written.
final class UndoBatchRestoreTests: XCTestCase {
    private let event = UndoSnapshotFixtures.event(title: "Standup")
    private let reminder = UndoSnapshotFixtures.reminder(title: "Pay rent")

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
}
