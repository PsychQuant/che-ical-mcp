import EventKit
import XCTest
@testable import CheICalMCP

final class ReminderWriteSnapshotTests: XCTestCase {
    private func requireSendable<T: Sendable>(_ type: T.Type) {}
    func testManagerSignaturesReturnOnlySnapshots() {
        let get: (String) async throws -> ReminderWriteSnapshot = { try await EventKitManager.shared.getReminder(identifier: $0) }
        let update: (String) async throws -> ReminderWriteSnapshot = { try await EventKitManager.shared.updateReminder(identifier: $0) }
        let create: (String) async throws -> EventKitManager.CreateReminderResult = { try await EventKitManager.shared.createReminder(title: $0) }
        _ = (get, update, create)
    }
    func testWriteResultIsAValueIndependentOfLaterMutation() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "Before"
        reminder.notes = "body\n#tag"
        let value = ReminderWriteSnapshot(from: reminder)
        let result = EventKitManager.CreateReminderResult(reminder: value, isDuplicate: true)
        reminder.title = "After"
        reminder.notes = nil
        XCTAssertEqual(result.reminder.title, "Before")
        XCTAssertEqual(result.reminder.notes, "body\n#tag")
        XCTAssertTrue(result.isDuplicate)
        requireSendable(ReminderWriteSnapshot.self)
        requireSendable(EventKitManager.CreateReminderResult.self)
    }
}
