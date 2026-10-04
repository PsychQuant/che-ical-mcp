import EventKit
import XCTest
@testable import CheICalMCP

/// #227: when `update_reminder` moves or clears the due date, the start date and every
/// absolute-date alarm must follow. Reminders.app shows the absolute alarm's date
/// (confirmed on device 2026-10-04), so a stale alarm keeps showing the old date.
final class ReminderDateSyncTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, in tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func components(_ date: Date, in tz: TimeZone, time: Bool = true) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = cal.dateComponents(time ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        c.timeZone = tz
        return c
    }

    /// EventKit attaches a `calendar` to components it hands back; compare the values only.
    private func startComponents(_ reminder: EKReminder) -> DateComponents? {
        guard var c = reminder.startDateComponents else { return nil }
        c.calendar = nil
        return c
    }

    private func absoluteDates(_ reminder: EKReminder) -> [Date] {
        (reminder.alarms ?? []).compactMap(\.absoluteDate).sorted()
    }

    private func makeReminder() -> EKReminder {
        EKReminder(eventStore: EKEventStore())
    }

    // MARK: - Shift

    func testShiftMovesStartAndAbsoluteAlarmByTheDueDelta() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))

        let report = ReminderDateSync.sync(reminder, from: oldDue, to: newDue)

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0))
        XCTAssertEqual(startComponents(reminder), components(newDue, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [newDue])
    }

    func testShiftKeepsTheAlarmsOffsetFromTheDueDate() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue.addingTimeInterval(-3600)))

        _ = ReminderDateSync.sync(reminder, from: oldDue, to: newDue)

        XCTAssertEqual(absoluteDates(reminder), [newDue.addingTimeInterval(-3600)])
    }

    func testShiftLeavesRelativeAndLocationAlarmsAlone() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        let location = EKAlarm()
        location.structuredLocation = EKStructuredLocation(title: "Office")
        location.proximity = .enter
        reminder.addAlarm(location)

        let report = ReminderDateSync.sync(reminder, from: oldDue, to: newDue)

        XCTAssertEqual(report, .init(startDate: .absent, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0))
        let alarms = reminder.alarms ?? []
        XCTAssertEqual(alarms.count, 2)
        XCTAssertEqual(alarms.filter { $0.structuredLocation == nil }.map(\.relativeOffset), [-900])
        XCTAssertEqual(alarms.compactMap { $0.structuredLocation?.title }, ["Office"])
    }

    func testShiftKeepsADateOnlyStartDateOnly() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(oldDue, in: taipei, time: false)

        _ = ReminderDateSync.sync(reminder, from: oldDue, to: newDue)

        XCTAssertEqual(startComponents(reminder), components(newDue, in: taipei, time: false))
    }

    func testShiftAcrossADaylightSavingChangeLandsTheAlarmOnTheNewDueDate() {
        // 2026-11-01 02:00 EDT -> EST. Both due dates are 10:00 wall clock.
        let oldDue = date(2026, 10, 30, 10, in: newYork)
        let newDue = date(2026, 11, 3, 10, in: newYork)
        let reminder = makeReminder()
        reminder.startDateComponents = components(oldDue, in: newYork)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))

        _ = ReminderDateSync.sync(reminder, from: oldDue, to: newDue)

        XCTAssertEqual(absoluteDates(reminder), [newDue])
        XCTAssertEqual(startComponents(reminder), components(newDue, in: newYork))
    }

    // MARK: - Nothing to shift

    func testNoPreviousDueDateMovesNothing() {
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let start = date(2026, 10, 1, 9, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(start, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: start))

        let report = ReminderDateSync.sync(reminder, from: nil, to: newDue)

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0))
        XCTAssertEqual(startComponents(reminder), components(start, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [start])
    }

    func testSameDueDateMovesNothing() {
        let due = date(2026, 10, 4, 10, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(due, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: due))

        let report = ReminderDateSync.sync(reminder, from: due, to: due)

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0))
        XCTAssertEqual(absoluteDates(reminder), [due])
    }

    // MARK: - Clear

    func testClearRemovesStartDateAndAbsoluteAlarmsButKeepsRelativeOnes() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue.addingTimeInterval(-3600)))
        reminder.addAlarm(EKAlarm(relativeOffset: -900))

        let report = ReminderDateSync.sync(reminder, from: oldDue, to: nil)

        XCTAssertEqual(report, .init(startDate: .cleared, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 2))
        XCTAssertNil(reminder.startDateComponents)
        XCTAssertEqual(absoluteDates(reminder), [])
        XCTAssertEqual((reminder.alarms ?? []).map(\.relativeOffset), [-900])
    }

    func testClearWithoutStartDateReportsAbsent() {
        let reminder = makeReminder()

        let report = ReminderDateSync.sync(reminder, from: nil, to: nil)

        XCTAssertEqual(report, .init(startDate: .absent, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0))
    }

    // MARK: - setDue (the update_reminder entry point)

    func testSetDueWritesTheDueDateWithAnExplicitTimeZoneAndMovesStartAndAlarm() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.dueDateComponents = components(oldDue, in: taipei)
        reminder.startDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))

        let report = ReminderDateSync.setDue(reminder, to: newDue)

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0))
        XCTAssertNotNil(reminder.dueDateComponents?.timeZone, "#134: due components carry an explicit time zone")
        XCTAssertEqual(safeDateFromComponents(reminder.dueDateComponents), newDue)
        XCTAssertEqual(absoluteDates(reminder), [newDue])
    }

    func testSetDueToNilClearsDueStartAndAbsoluteAlarms() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let reminder = makeReminder()
        reminder.dueDateComponents = components(oldDue, in: taipei)
        reminder.startDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))

        let report = ReminderDateSync.setDue(reminder, to: nil)

        XCTAssertEqual(report, .init(startDate: .cleared, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 1))
        XCTAssertNil(reminder.dueDateComponents)
        XCTAssertNil(reminder.startDateComponents)
        XCTAssertEqual(absoluteDates(reminder), [])
    }

    // MARK: - Verify round 1 (PR #232)

    /// Finding 1: a date-only old due date is midnight, so an instant delta would add the new
    /// due's time of day to every alarm. It must move by calendar days instead.
    func testDateOnlyOldDueMovesAlarmsByCalendarDaysKeepingTheirTime() {
        let oldDue = date(2026, 10, 4, 0, in: taipei)
        let newDue = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 4, 9, in: taipei)))
        reminder.startDateComponents = components(oldDue, in: taipei, time: false)

        let report = ReminderDateSync.sync(reminder, from: oldDue, to: newDue, oldDueIsDateOnly: true, dayTimeZone: taipei)

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0))
        XCTAssertEqual(absoluteDates(reminder), [date(2026, 10, 8, 9, in: taipei)])
        XCTAssertEqual(startComponents(reminder), components(newDue, in: taipei, time: false))
    }

    /// Finding 2: across a spring-forward change a day is 23 h; a date-only start must still
    /// land on the next day.
    func testDateOnlyStartMovesByCalendarDaysAcrossSpringForward() {
        // DST starts 2026-03-08 in New York.
        let oldDue = date(2026, 3, 7, 10, in: newYork)
        let newDue = date(2026, 3, 8, 10, in: newYork)
        let reminder = makeReminder()
        reminder.startDateComponents = components(oldDue, in: newYork, time: false)

        _ = ReminderDateSync.sync(reminder, from: oldDue, to: newDue)

        XCTAssertEqual(startComponents(reminder), components(newDue, in: newYork, time: false))
    }

    /// Finding 3: the due date is stored to the minute; an alarm on the old due must land on the
    /// stored new due, not on the raw input with its seconds.
    func testSetDueShiftsAlarmsOntoTheStoredMinuteNotTheRawInput() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let reminder = makeReminder()
        reminder.dueDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))

        _ = ReminderDateSync.setDue(reminder, to: date(2026, 10, 4, 11, in: taipei).addingTimeInterval(30))

        let storedDue = safeDateFromComponents(reminder.dueDateComponents)
        XCTAssertEqual(storedDue, date(2026, 10, 4, 11, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [storedDue!])
    }

    /// Finding 4: clearing a due date that does not exist is a no-op; it must not take the
    /// start date and alarms with it.
    func testClearWithoutAPreviousDueDateKeepsStartAndAlarms() {
        let start = date(2026, 10, 1, 9, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(start, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: start))

        let report = ReminderDateSync.sync(reminder, from: nil, to: nil)

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0))
        XCTAssertEqual(startComponents(reminder), components(start, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [start])
    }

    /// Finding 6: shifting changes only the alarm's date; its other properties survive.
    func testShiftKeepsTheAlarmsOtherProperties() {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let reminder = makeReminder()
        let alarm = EKAlarm(absoluteDate: oldDue)
        alarm.soundName = "Ping"
        alarm.emailAddress = "owner@example.com"
        reminder.addAlarm(alarm)

        _ = ReminderDateSync.sync(reminder, from: oldDue, to: date(2026, 10, 8, 10, in: taipei))

        XCTAssertEqual(reminder.alarms?.first?.soundName, "Ping", "EKAlarm.copy() alone drops soundName")
        XCTAssertEqual(reminder.alarms?.first?.emailAddress, "owner@example.com")
    }

    /// Finding 7: the whole chain — snapshot, update, undo — returns the reminder to its state.
    func testUndoSnapshotTakenBeforeSetDueRestoresTheOriginalDates() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        reminder.dueDateComponents = components(oldDue, in: taipei)
        reminder.startDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        let snapshot = ReminderSnapshot(from: reminder)

        _ = ReminderDateSync.setDue(reminder, to: date(2026, 10, 8, 10, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [date(2026, 10, 8, 10, in: taipei)])

        snapshot.applyDates(to: reminder)
        XCTAssertEqual(startComponents(reminder), components(oldDue, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [oldDue])
        XCTAssertEqual((reminder.alarms ?? []).filter { $0.absoluteDate == nil }.map(\.relativeOffset), [-900])
    }

    // MARK: - Response shape

    func testReportDictionaryUsesSnakeCaseKeys() {
        let report = ReminderDateSync.Report(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0)

        XCTAssertEqual(report.dictionary["start_date"] as? String, "shifted")
        XCTAssertEqual(report.dictionary["absolute_alarms_shifted"] as? Int, 1)
        XCTAssertEqual(report.dictionary["absolute_alarms_removed"] as? Int, 0)
    }
}
