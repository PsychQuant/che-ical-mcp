import EventKit
import XCTest
@testable import CheICalMCP

/// #227: undo of `update_reminder` / `delete_reminder` restores a reminder from
/// `ReminderSnapshot`. Once `update_reminder` moves start dates and absolute-date alarms,
/// the snapshot has to carry them, or undo rebuilds an absolute alarm as a relative one
/// (its `relativeOffset` is 0) and drops the start date.
final class ReminderSnapshotTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func components(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> DateComponents {
        DateComponents(timeZone: taipei, year: y, month: m, day: d, hour: h, minute: 0)
    }

    private func instant(_ c: DateComponents) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = taipei
        return cal.date(from: c)!
    }

    /// The snapshot reads `calendar.title`, so the in-memory reminder needs a calendar
    /// (same setup as `ReminderCompletionUndoTests`).
    private func makeReminder() -> EKReminder {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        return reminder
    }

    private func startComponents(_ reminder: EKReminder) -> DateComponents? {
        guard var c = reminder.startDateComponents else { return nil }
        c.calendar = nil
        return c
    }

    func testSnapshotCapturesStartDateAndAbsoluteAlarmsSeparately() {
        let reminder = makeReminder()
        let start = components(2026, 10, 4, 10)
        reminder.startDateComponents = start
        reminder.addAlarm(EKAlarm(absoluteDate: instant(start)))
        reminder.addAlarm(EKAlarm(relativeOffset: -900))

        let snapshot = ReminderSnapshot(from: reminder)

        var captured = snapshot.startDateComponents
        captured?.calendar = nil
        XCTAssertEqual(captured, start)
        XCTAssertEqual(snapshot.absoluteAlarmDates, [instant(start)])
        XCTAssertEqual(snapshot.alarmOffsets, [-900], "an absolute alarm must not be recorded as offset 0")
    }

    func testApplyingTheSnapshotRestoresStartDateAndBothKindsOfAlarm() {
        let original = makeReminder()
        let start = components(2026, 10, 4, 10)
        original.startDateComponents = start
        original.addAlarm(EKAlarm(absoluteDate: instant(start)))
        original.addAlarm(EKAlarm(relativeOffset: -900))
        let snapshot = ReminderSnapshot(from: original)

        // The state after an update moved everything to Oct 8.
        let moved = makeReminder()
        moved.startDateComponents = components(2026, 10, 8, 10)
        moved.addAlarm(EKAlarm(absoluteDate: instant(components(2026, 10, 8, 10))))

        snapshot.applyDates(to: moved)

        XCTAssertEqual(startComponents(moved), start)
        let alarms = moved.alarms ?? []
        XCTAssertEqual(alarms.compactMap(\.absoluteDate), [instant(start)])
        XCTAssertEqual(alarms.filter { $0.absoluteDate == nil }.map(\.relativeOffset), [-900])
    }

    func testApplyingASnapshotWithoutStartDateClearsIt() {
        let snapshot = ReminderSnapshot(from: makeReminder())
        let moved = makeReminder()
        moved.startDateComponents = components(2026, 10, 8, 10)

        snapshot.applyDates(to: moved)

        XCTAssertNil(moved.startDateComponents)
        XCTAssertEqual(moved.alarms ?? [], [])
    }
}
