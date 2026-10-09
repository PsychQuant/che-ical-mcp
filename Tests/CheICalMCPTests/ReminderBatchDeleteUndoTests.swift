import XCTest
@testable import CheICalMCP

/// #243: `delete_reminders_batch` and `cleanup_completed_reminders` record one undo entry for the
/// reminders the call removed, a `.batch` of `.deleteReminder` members, as `delete_events_batch`
/// does (#185). Pure: the snapshots are built in memory, so no TCC prompt.
final class ReminderBatchDeleteUndoTests: XCTestCase {
    private func memberTitles(_ operation: UndoOperation?) -> [String]? {
        guard case .batch(let members)? = operation else { return nil }
        return members.map { member -> String in
            guard case .deleteReminder(let snapshot) = member else { return "<not a reminder delete>" }
            return snapshot.title
        }
    }

    func testNothingRemovedRecordsNothing() {
        XCTAssertNil(UndoOperation.reminderBatchDelete([]),
                     "a call that removed nothing must not push an entry that undo would pop first")
    }

    func testOneRemovedReminderIsABatchOfOne() {
        let operation = UndoOperation.reminderBatchDelete([UndoSnapshotFixtures.reminder(title: "Pay rent")])
        XCTAssertEqual(memberTitles(operation), ["Pay rent"])
    }

    func testMembersKeepTheOrderTheRemindersWereRemovedIn() {
        let titles = ["A", "B", "C"]
        let operation = UndoOperation.reminderBatchDelete(titles.map { UndoSnapshotFixtures.reminder(title: $0) })
        XCTAssertEqual(memberTitles(operation), titles)
    }

    /// The entry reads like the event batch in `undo_history`, and its redo names the batch tool
    /// (#247), since redo does not delete the restored reminders again.
    func testTheEntryIsListedAsABatchAndItsRedoNamesTheBatchTool() throws {
        let operation = try XCTUnwrap(UndoOperation.reminderBatchDelete(
            [UndoSnapshotFixtures.reminder(title: "A"), UndoSnapshotFixtures.reminder(title: "B")]))
        XCTAssertEqual(operation.description, "Batch (2 operations)")
        let redo = try XCTUnwrap(operation.redoInstruction)
        XCTAssertTrue(redo.contains("2 reminders") && redo.contains("delete_reminders_batch"), redo)
    }
}
