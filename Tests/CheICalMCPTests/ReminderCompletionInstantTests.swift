import EventKit
import XCTest
@testable import CheICalMCP

final class ReminderCompletionInstantTests: XCTestCase {
    func testRepeatedCompletionKeepsOriginalInstant() {
        let reminder = EKReminder(eventStore: EKEventStore())
        let original = Date(timeIntervalSince1970: 100)
        reminder.isCompleted = true
        reminder.completionDate = original
        ReminderCompletionWrite.applyRequest(to: reminder, completed: true, now: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(reminder.isCompleted)
        XCTAssertEqual(reminder.completionDate, original)
    }
    func testCompletionTransitionUsesNowAndReopeningClearsIt() {
        let reminder = EKReminder(eventStore: EKEventStore())
        let now = Date(timeIntervalSince1970: 200)
        ReminderCompletionWrite.applyRequest(to: reminder, completed: true, now: now)
        XCTAssertEqual(reminder.completionDate, now)
        ReminderCompletionWrite.applyRequest(to: reminder, completed: false, now: now)
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertNil(reminder.completionDate)
        ReminderCompletionWrite.applyRequest(to: reminder, completed: false, now: now)
        XCTAssertNil(reminder.completionDate)
    }
}
