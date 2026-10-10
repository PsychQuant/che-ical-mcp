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
    // #297: an explicit zone, so the date-only due of 1970-01-01 is a day that has ended at `now`
    // whatever zone the host is in.
    func testOverdueFilteringAndCounts() {
        let utc = TimeZone(identifier: "UTC")!
        let due = DateComponents(year: 1970, month: 1, day: 1)
        let input = [ReminderReadSnapshot(id: "past", title: "past", dueDateComponents: due),
                     ReminderReadSnapshot(id: "done", title: "done", isCompleted: true, dueDateComponents: due),
                     ReminderReadSnapshot(id: "none", title: "none")]
        let page = ReminderPageQuery(overdueOnly: true, now: Date(timeIntervalSince1970: 86400), zone: utc).page(input) { $0 }
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

    // MARK: - #297: a date-only due is a day

    // The table `ReminderDueReadingTests` judges `isOverdue` with drives the filter too.
    func testTheOverdueFilterFollowsTheDateOnlyRule() {
        for zone in [ReminderDueReadingTests.taipei, ReminderDueReadingTests.losAngeles] {
            for c in ReminderDueReadingTests.overdueCases {
                let input = [ReminderReadSnapshot(id: "day", title: "day", dueDateComponents: ReminderDueReadingTests.dateOnlyDue)]
                let now = ReminderDueReadingTests.now(of: c, in: zone)
                let page = ReminderPageQuery(overdueOnly: true, now: now, zone: zone).page(input) { $0 }
                XCTAssertEqual(page.totalAfterFilter == 1, c.overdue, "\(c.label) in \(zone.identifier)")
                XCTAssertEqual(page.zone, zone)
            }
        }
    }

    func testTheDueDateSortPutsADateOnlyDueAtTheHeadOfItsDay() {
        let taipei = ReminderDueReadingTests.taipei
        func timed(_ d: Int, _ h: Int, _ min: Int = 0) -> DateComponents {
            DateComponents(timeZone: taipei, year: 2026, month: 10, day: d, hour: h, minute: min)
        }
        let input = [ReminderReadSnapshot(id: "none", title: "none"),
                     ReminderReadSnapshot(id: "nine", title: "nine", dueDateComponents: timed(9, 9)),
                     ReminderReadSnapshot(id: "midnight", title: "midnight", dueDateComponents: timed(9, 0)),
                     ReminderReadSnapshot(id: "day", title: "day", dueDateComponents: DateComponents(year: 2026, month: 10, day: 9)),
                     ReminderReadSnapshot(id: "eve", title: "eve", dueDateComponents: timed(8, 23, 59))]
        for order in [input, Array(input.reversed())] {
            let page = ReminderPageQuery(sort: "due_date", zone: taipei).page(order) { $0 }
            XCTAssertEqual(page.reminders.map(\.calendarItemIdentifier), ["eve", "day", "midnight", "nine", "none"])
        }
    }
}
