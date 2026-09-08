import EventKit
import XCTest
@testable import CheICalMCP

final class ReminderPageTests: XCTestCase {
    func testOnlySelectedPageIsMaterialized() {
        let store = EKEventStore()
        let input = (0..<2000).map { index in
            let reminder = EKReminder(eventStore: store)
            reminder.title = String(index)
            reminder.priority = index % 10
            return reminder
        }
        var count = 0
        let page = ReminderPageQuery(sort: "priority", limit: 10).page(input) { value in
            count += 1
            return ReminderReadSnapshot(from: value)
        }
        XCTAssertEqual(count, 10)
        XCTAssertEqual(page.totalFetched, 2000)
        XCTAssertEqual(page.totalAfterFilter, 2000)
        XCTAssertTrue(page.reminders.allSatisfy { $0.priority == 1 })
    }
    func testOverdueFilteringAndCounts() {
        let due = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: 0))
        let input = [ReminderReadSnapshot(id: "past", title: "past", dueDateComponents: due),
                     ReminderReadSnapshot(id: "done", title: "done", isCompleted: true, dueDateComponents: due),
                     ReminderReadSnapshot(id: "none", title: "none")]
        let page = ReminderPageQuery(overdueOnly: true, now: Date(timeIntervalSince1970: 86400)).page(input) { $0 }
        XCTAssertEqual(page.totalFetched, 3)
        XCTAssertEqual(page.totalAfterFilter, 1)
        XCTAssertEqual(page.reminders.map(\.calendarItemIdentifier), ["past"])
    }
    func testTagFilterBeforeLimitPreservesSearchOrder() {
        let values = [ReminderReadSnapshot(id: "a", title: "a", notes: "#Other"),
                      ReminderReadSnapshot(id: "b", title: "b", notes: "#Work"),
                      ReminderReadSnapshot(id: "c", title: "c", notes: "#work")]
        let page = ReminderPageQuery(tag: "#WORK", limit: 1).page(values) { $0 }
        XCTAssertEqual(page.totalAfterFilter, 2)
        XCTAssertEqual(page.reminders.map(\.calendarItemIdentifier), ["b"])
    }
    func testNilCalendarSnapshotIsSafe() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "orphan"
        XCTAssertNil(reminder.calendar)
        XCTAssertEqual(ReminderReadSnapshot(from: reminder).calendar.title, "")
    }
}
