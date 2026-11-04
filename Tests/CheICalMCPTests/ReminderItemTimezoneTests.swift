import EventKit
import XCTest
@testable import CheICalMCP

/// #241: the read snapshot carries the reminder's own zone (`EKCalendarItem.timeZone`).
final class ReminderItemTimezoneTests: XCTestCase {
    func testSnapshotDefaultsToFloating() {
        XCTAssertNil(ReminderReadSnapshot(id: "r", title: "R").timeZone)
    }

    /// An unsaved `EKReminder` keeps no item zone without due components (setting
    /// `timeZone` alone reads back nil, 2026-11-04), so the zone comes in with the due.
    func testSnapshotFromReminderCopiesItsZone() {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = DateComponents(year: 2026, month: 12, day: 1, hour: 9)
        reminder.timeZone = TimeZone(identifier: "America/New_York")
        XCTAssertEqual(reminder.timeZone?.identifier, "America/New_York", "precondition")
        XCTAssertEqual(ReminderReadSnapshot(from: reminder).timeZone?.identifier, "America/New_York")
    }

    func testSnapshotFromFloatingReminderHasNoZone() {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = DateComponents(year: 2026, month: 12, day: 1, hour: 9)
        XCTAssertNil(reminder.timeZone, "precondition")
        XCTAssertNil(ReminderReadSnapshot(from: reminder).timeZone)
    }
}
