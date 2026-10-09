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

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0, aligned: true))
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

        let report = ReminderDateSync.sync(reminder, from: oldDue, to: newDue, oldDueIsDateOnly: true, dueDayShift: 4)

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

    /// The identifier EventKit gives an alarm (`UUID`, not public API). `EKAlarm.copy()` keeps it.
    private func alarmUUID(_ alarm: EKAlarm?) throws -> String? {
        guard let alarm else { return nil }
        try XCTSkipUnless(alarm.responds(to: NSSelectorFromString("UUID")), "EKAlarm no longer exposes UUID")
        return alarm.value(forKey: "UUID") as? String
    }

    /// #235, on device 2026-10-05: an alarm moved as a `copy()` keeps the original's UUID. When the
    /// start date is written in the same save and the due date is not changed (realign alone, or the
    /// same due re-sent), the Reminders store kept both rows, and Reminders.app went on displaying
    /// the old alarm while EventKit read back only the new one. A new alarm is removed and inserted
    /// cleanly, so a moved alarm must not share the original's UUID.
    func testAMovedAlarmIsANewAlarmNotACopyOfTheOldOne() throws {
        let due = date(2026, 10, 8, 10, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(date(2026, 10, 4, 10, in: taipei), in: taipei)
        let alarm = EKAlarm(absoluteDate: date(2026, 10, 4, 10, in: taipei))
        reminder.addAlarm(alarm)
        reminder.dueDateComponents = components(due, in: taipei)
        let originalUUID = try alarmUUID(alarm)
        XCTAssertNotNil(originalUUID)

        _ = ReminderDateSync.realign(reminder)

        XCTAssertEqual(absoluteDates(reminder), [due])
        XCTAssertNotEqual(try alarmUUID(reminder.alarms?.first), originalUUID)
    }

    func testAnAlarmShiftedWithTheDueIsANewAlarmToo() throws {
        let oldDue = date(2026, 10, 4, 10, in: taipei)
        let reminder = makeReminder()
        let alarm = EKAlarm(absoluteDate: oldDue)
        reminder.addAlarm(alarm)
        let originalUUID = try alarmUUID(alarm)

        _ = ReminderDateSync.sync(reminder, from: oldDue, to: date(2026, 10, 8, 10, in: taipei))

        XCTAssertNotEqual(try alarmUUID(reminder.alarms?.first), originalUUID)
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

        snapshot.apply(to: reminder, now: Date())
        XCTAssertEqual(startComponents(reminder), components(oldDue, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [oldDue])
        XCTAssertEqual((reminder.alarms ?? []).filter { $0.absoluteDate == nil }.map(\.relativeOffset), [-900])
    }

    // MARK: - Verify round 2 (PR #232)

    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        date(y, m, d, h, in: .current)
    }

    /// The date-only detection in setDue (hour == nil, confirmed on device) is exercised.
    func testSetDueFromADateOnlyDueMovesAlarmsByCalendarDays() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 4)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 4, 9)))

        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))

        XCTAssertEqual(report.absoluteAlarmsShifted, 1)
        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 8, 9)])
    }

    /// Days are counted from the stored year/month/day, not from instants in one zone: 22:00 on
    /// Oct 4 in New York is already Oct 5 in Taipei, but the due date moved two calendar days.
    func testDayShiftCountsStoredCalendarDaysAcrossZones() {
        let old = components(date(2026, 10, 4, 22, in: newYork), in: newYork)
        let new = components(date(2026, 10, 6, 10, in: taipei), in: taipei)
        XCTAssertEqual(ReminderDateSync.dayShift(from: old, to: new), 2)
        XCTAssertNil(ReminderDateSync.dayShift(from: nil, to: new))
    }

    func testDateOnlyStartMovesByTheDueDayShift() {
        let reminder = makeReminder()
        reminder.startDateComponents = DateComponents(timeZone: newYork, year: 2026, month: 10, day: 4)

        _ = ReminderDateSync.sync(reminder, from: date(2026, 10, 4, 22, in: newYork),
                                  to: date(2026, 10, 6, 10, in: taipei), dueDayShift: 2)

        XCTAssertEqual(startComponents(reminder), DateComponents(timeZone: newYork, year: 2026, month: 10, day: 6))
    }

    func testAStartThatStaysOnTheSameDayIsReportedUnchanged() {
        let reminder = makeReminder()
        reminder.startDateComponents = DateComponents(timeZone: .current, year: 2026, month: 10, day: 4)

        let report = ReminderDateSync.sync(reminder, from: local(2026, 10, 4, 9), to: local(2026, 10, 4, 15), dueDayShift: 0)

        XCTAssertEqual(report.startDate, .unchanged)
    }

    /// EventKit couples start and due: in memory, writing a date-only start turns the due date
    /// date-only. setDue therefore moves the start first and writes the due date last.
    func testSetDueKeepsTheNewTimeWhenTheStartIsDateOnly() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 4)   // start becomes date-only Oct 4

        _ = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))

        XCTAssertEqual(reminder.dueDateComponents?.hour, 10, "the due time must survive the start shift")
        XCTAssertEqual(reminder.dueDateComponents?.day, 8)
        XCTAssertEqual(reminder.startDateComponents?.day, 8)
    }

    /// Date-only to timed on the same day: the calendar day did not change, so nothing moves.
    func testDateOnlyDueGivenATimeOnTheSameDayMovesNothing() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 4)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 4, 9)))

        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 4, 10))

        XCTAssertNotEqual(report.startDate, .shifted)
        XCTAssertEqual(report.absoluteAlarmsShifted, 0)
        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 4, 9)])
    }

    func testSetDueToNilWithoutADueDateKeepsStartAndAlarms() {
        let reminder = makeReminder()
        reminder.startDateComponents = components(local(2026, 10, 1, 9), in: .current)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 1, 9)))

        let report = ReminderDateSync.setDue(reminder, to: nil)

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0))
        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 1, 9)])
    }

    /// The clear guard keys on whether a due date existed, not on whether it parsed. (EventKit
    /// rejects due components without year/month/day, so the guard is driven directly.)
    func testClearKeysOnWhetherADueDateExistedNotOnParsing() {
        let reminder = makeReminder()
        reminder.startDateComponents = components(local(2026, 10, 1, 9), in: .current)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 1, 9)))

        let report = ReminderDateSync.sync(reminder, from: nil, to: nil, hadDueDate: true)

        XCTAssertEqual(report, .init(startDate: .cleared, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 1))
        XCTAssertNil(reminder.startDateComponents)
    }

    // MARK: - #237: a floating reminder gets the due date's zone

    private func zonedComponents(_ c: DateComponents?) -> DateComponents? {
        guard var c else { return nil }
        c.calendar = nil
        return c
    }

    /// The store hands a date-only reminder back with a `00:00` floating start. Writing a zoned
    /// due onto such an item used to drop the zone (#134's iCloud Web shift came back).
    func testSetDueOnAFloatingItemGivesTheDueAnExplicitZone() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 7)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 7, hour: 0, minute: 0)
        XCTAssertNil(reminder.timeZone, "precondition: a floating item")

        _ = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))

        XCTAssertEqual(reminder.dueDateComponents?.hour, 10)
        XCTAssertEqual(reminder.dueDateComponents?.timeZone, .current, "#237: the due carries an explicit zone")
        XCTAssertEqual(reminder.timeZone, .current)
        XCTAssertEqual(zonedComponents(reminder.startDateComponents),
                       DateComponents(timeZone: .current, year: 2026, month: 10, day: 8, hour: 0, minute: 0),
                       "the start keeps its wall clock, now in the same zone")
    }

    /// Hazard 1: in memory, giving the item a zone while the start has no hour turns the due
    /// date date-only. The start gets a 00:00 time first.
    func testSetDueOnAFloatingItemWithADateOnlyStartKeepsTheTimeAndGetsAZone() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 4)   // start becomes date-only
        XCTAssertNil(reminder.startDateComponents?.hour, "precondition: a start with no hour")

        _ = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))

        XCTAssertEqual(reminder.dueDateComponents?.hour, 10)
        XCTAssertEqual(reminder.dueDateComponents?.day, 8)
        XCTAssertEqual(reminder.dueDateComponents?.timeZone, .current)
        XCTAssertEqual(safeDateFromComponents(reminder.dueDateComponents), local(2026, 10, 8, 10))
    }

    /// Hazard 2: assigning a zone to an item that already has one moves its instants. A zoned
    /// item keeps its zone and the due lands on the requested instant (regression guard).
    func testSetDueLeavesTheZoneOfAZonedItemAlone() {
        let reminder = makeReminder()
        let start = date(2026, 10, 7, 9, in: newYork)
        reminder.startDateComponents = components(start, in: newYork)
        reminder.dueDateComponents = components(start, in: newYork)
        let newDue = date(2026, 10, 8, 10, in: taipei)

        _ = ReminderDateSync.setDue(reminder, to: newDue)

        XCTAssertEqual(reminder.timeZone, newYork)
        XCTAssertEqual(safeDateFromComponents(reminder.dueDateComponents), newDue)
        XCTAssertNotNil(reminder.dueDateComponents?.timeZone)
    }

    /// Clearing the due date writes no zone (regression guard).
    func testSetDueToNilLeavesAFloatingItemFloating() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 7)

        _ = ReminderDateSync.setDue(reminder, to: nil)

        XCTAssertNil(reminder.timeZone)
        XCTAssertNil(reminder.dueDateComponents)
    }

    /// The fallback when the zone did not stick: clear the start, write the due, put the start
    /// back timed and zoned. This order kept both zoned on device (diagnosis matrix).
    func testWritingTheDueAroundAClearedStartZonesBoth() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 7)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 8, hour: 0, minute: 0)
        var due = DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 0)
        due.timeZone = .current

        ReminderDateSync.writeDueAroundStart(reminder, due: due)

        XCTAssertEqual(zonedComponents(reminder.dueDateComponents), due)
        XCTAssertEqual(zonedComponents(reminder.startDateComponents),
                       DateComponents(timeZone: .current, year: 2026, month: 10, day: 8, hour: 0, minute: 0))
    }

    func testTheFallbackRunsOnlyWhenTheDueLostItsTimeOrZone() {
        var zoned = DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 0)
        zoned.timeZone = .current
        XCTAssertFalse(ReminderDateSync.dueLostTimeOrZone(zoned))
        XCTAssertTrue(ReminderDateSync.dueLostTimeOrZone(DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 0)))
        var dateOnly = DateComponents(year: 2026, month: 10, day: 8)
        dateOnly.timeZone = .current
        XCTAssertTrue(ReminderDateSync.dueLostTimeOrZone(dateOnly))
        XCTAssertTrue(ReminderDateSync.dueLostTimeOrZone(nil))
    }

    // MARK: - #235: realigning a reminder whose alarm or start already diverged

    /// Reminders.app displays the earliest absolute-date alarm (on device 2026-10-05), so that is
    /// the anchor `realign_to_due` puts on the due date.
    private func divergedReminder() -> EKReminder {
        // As v1.17/v1.18 left it: due moved to Oct 8, start and alarm still on Oct 4.
        let reminder = makeReminder()
        reminder.dueDateComponents = components(date(2026, 10, 8, 10, in: taipei), in: taipei)
        reminder.startDateComponents = components(date(2026, 10, 4, 10, in: taipei), in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 4, 10, in: taipei)))
        return reminder
    }

    /// Case 1: the same due date re-sent moves nothing, and the response now says so.
    func testSameDueReSentOnADivergedReminderReportsNotAligned() {
        let reminder = divergedReminder()

        let report = ReminderDateSync.setDue(reminder, to: date(2026, 10, 8, 10, in: taipei))

        XCTAssertEqual(report.aligned, false)
        XCTAssertEqual(report.absoluteAlarmsShifted, 0)
        XCTAssertEqual(absoluteDates(reminder), [date(2026, 10, 4, 10, in: taipei)])
    }

    func testRealignPutsTheStartAndAlarmOfADivergedReminderOnTheDueDate() {
        let reminder = divergedReminder()
        let due = date(2026, 10, 8, 10, in: taipei)

        let report = ReminderDateSync.setDue(reminder, to: due, realignToDue: true)

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0, aligned: true))
        XCTAssertEqual(absoluteDates(reminder), [due])
        // The new due is written in the host zone (#134), and the start is put on it in that
        // zone. Compare with what was written, not a fixed zone: the test then holds on any host
        // (CI runs in GMT, where a fixed Asia/Taipei expectation failed).
        XCTAssertEqual(safeDateFromComponents(reminder.startDateComponents), due)
        XCTAssertNotNil(report.writtenDue?.timeZone)
        XCTAssertEqual(startComponents(reminder)?.timeZone, report.writtenDue?.timeZone)
        XCTAssertEqual(startComponents(reminder)?.hour, report.writtenDue?.hour)
    }

    /// `realign_to_due` without `due_date` aligns to the current due date and leaves it as it is.
    func testRealignToTheCurrentDueLeavesTheDueDateAlone() {
        let reminder = divergedReminder()
        let due = date(2026, 10, 8, 10, in: taipei)

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0, aligned: true))
        XCTAssertEqual(safeDateFromComponents(reminder.dueDateComponents), due)
        XCTAssertEqual(absoluteDates(reminder), [due])
    }

    /// Case 2: no previous due date. EventKit creates start = due while the due is written; the
    /// report describes that start (`set`), not the state before the write (`absent`).
    func testNoPreviousDueReportsTheStartEventKitCreatesAndNotAligned() {
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 1, 9, in: taipei)))

        let report = ReminderDateSync.setDue(reminder, to: date(2026, 10, 8, 10, in: taipei))

        XCTAssertEqual(report.startDate, .set)
        XCTAssertEqual(report.aligned, false)
        XCTAssertEqual(absoluteDates(reminder), [date(2026, 10, 1, 9, in: taipei)])
    }

    func testRealignWithNoPreviousDueMovesTheAlarmOntoTheNewDue() {
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 1, 9, in: taipei)))
        let due = date(2026, 10, 8, 10, in: taipei)

        let report = ReminderDateSync.setDue(reminder, to: due, realignToDue: true)

        XCTAssertEqual(report, .init(startDate: .set, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0, aligned: true))
        XCTAssertEqual(absoluteDates(reminder), [due])
    }

    /// Case 3: a date-only due given a time on the same day.
    private func dateOnlyReminderWithMorningAlarm() -> EKReminder {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 4)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 4, 9)))
        return reminder
    }

    func testDateOnlyDueGivenATimeOnTheSameDayReportsNotAligned() {
        let reminder = dateOnlyReminderWithMorningAlarm()

        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 4, 10))

        XCTAssertEqual(report.aligned, false)
        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 4, 9)])
    }

    /// The date-only start EventKit made on the due's day is a start `aligned` accepts, so realign
    /// leaves it on that day (verify round 1); #237 gives it `00:00`.
    func testRealignMovesTheMorningAlarmToTheNewDueTimeAndKeepsTheStartsDay() {
        let reminder = dateOnlyReminderWithMorningAlarm()

        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 4, 10), realignToDue: true)

        XCTAssertEqual(report.aligned, true)
        XCTAssertEqual(report.absoluteAlarmsShifted, 1)
        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 4, 10)])
        XCTAssertEqual(safeDateFromComponents(reminder.startDateComponents), local(2026, 10, 4, 0))
        XCTAssertEqual(reminder.dueDateComponents?.hour, 10, "the due time survives the start write")
        XCTAssertNotNil(reminder.dueDateComponents?.timeZone, "#237 still applies")
    }

    /// The earliest alarm lands on the due date; the later ones keep their spacing after it.
    func testRealignAnchorsTheEarliestAlarmAndKeepsTheSpacingOfTheOthers() {
        let reminder = divergedReminder()
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 3, 9, in: taipei)))   // 25 h before the other
        let due = date(2026, 10, 8, 10, in: taipei)

        let report = ReminderDateSync.setDue(reminder, to: due, realignToDue: true)

        XCTAssertEqual(report.absoluteAlarmsShifted, 2)
        XCTAssertEqual(absoluteDates(reminder), [due, due.addingTimeInterval(25 * 3600)])
        XCTAssertEqual(report.aligned, true)
    }

    /// With a date-only due the alarms move by whole calendar days and keep their time of day.
    func testRealignToADateOnlyDueKeepsTheAlarmsTimeOfDay() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 4, 9)))

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 8, 9)])
        XCTAssertEqual(reminder.startDateComponents?.day, 8)
        XCTAssertNil(reminder.dueDateComponents?.hour, "the due stays date-only")
        XCTAssertEqual(report.aligned, true)
    }

    func testRealignLeavesRelativeAndLocationAlarmsAlone() {
        let reminder = divergedReminder()
        reminder.addAlarm(EKAlarm(relativeOffset: -900))

        _ = ReminderDateSync.realign(reminder)

        XCTAssertEqual((reminder.alarms ?? []).filter { $0.absoluteDate == nil }.map(\.relativeOffset), [-900])
    }

    /// Undo through the `.updateReminder` snapshot (start date and absolute alarms, #227) brings a
    /// realigned reminder back to its diverged state.
    func testUndoSnapshotTakenBeforeRealignRestoresTheDivergedDates() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        let oldDue = date(2026, 10, 8, 10, in: taipei)
        let oldStart = date(2026, 10, 4, 10, in: taipei)
        reminder.dueDateComponents = components(oldDue, in: taipei)
        reminder.startDateComponents = components(oldStart, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldStart))
        reminder.addAlarm(EKAlarm(absoluteDate: oldStart.addingTimeInterval(-3600)))
        let snapshot = ReminderSnapshot(from: reminder)

        _ = ReminderDateSync.setDue(reminder, to: date(2026, 10, 9, 10, in: taipei), realignToDue: true)
        XCTAssertEqual(absoluteDates(reminder), [date(2026, 10, 9, 10, in: taipei), date(2026, 10, 9, 11, in: taipei)])

        reminder.dueDateComponents = snapshot.dueDateComponents
        snapshot.apply(to: reminder, now: Date())
        XCTAssertEqual(startComponents(reminder), components(oldStart, in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [oldStart.addingTimeInterval(-3600), oldStart])
        XCTAssertEqual(safeDateFromComponents(reminder.dueDateComponents), oldDue)
    }

    // MARK: - #235: alignment check

    func testAReminderWithoutAnAbsoluteAlarmIsAlignedWhenItsStartIsOnTheDue() {
        let reminder = makeReminder()
        let due = date(2026, 10, 8, 10, in: taipei)
        reminder.dueDateComponents = components(due, in: taipei)
        reminder.startDateComponents = components(due, in: taipei)
        reminder.addAlarm(EKAlarm(relativeOffset: -900))

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), true)
    }

    /// The displayed date follows the earliest alarm even when it is after the due date.
    func testAnAlarmAfterTheDueDateIsNotAligned() {
        let reminder = makeReminder()
        let due = date(2026, 10, 8, 10, in: taipei)
        reminder.dueDateComponents = components(due, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(86400)))

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), false)
    }

    func testAStartOnAnotherInstantIsNotAligned() {
        let reminder = makeReminder()
        reminder.dueDateComponents = components(date(2026, 10, 8, 10, in: taipei), in: taipei)
        reminder.startDateComponents = components(date(2026, 10, 8, 9, in: taipei), in: taipei)

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), false)
    }

    /// On device (2026-10-05) the store hands a date-only start back as `00:00`, and after #237 a
    /// date-only reminder given a time keeps that start as `00:00` in the due's zone. It is a
    /// date-only start on the due's day (`startChange` already treats midnight that way), so a
    /// reminder made in Reminders.app and rescheduled with a time must not read as diverged.
    func testAMidnightStartOnTheDuesDayCountsAsADateOnlyStart() {
        let reminder = makeReminder()
        reminder.dueDateComponents = components(date(2026, 10, 8, 10, in: taipei), in: taipei)
        reminder.startDateComponents = components(date(2026, 10, 8, 0, in: taipei), in: taipei)

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), true)
    }

    func testAMidnightStartOnAnotherDayIsNotAligned() {
        let reminder = makeReminder()
        reminder.dueDateComponents = components(date(2026, 10, 8, 10, in: taipei), in: taipei)
        reminder.startDateComponents = components(date(2026, 10, 7, 0, in: taipei), in: taipei)

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), false)
    }

    func testAlignmentIsUnknownWithoutADueDate() {
        XCTAssertNil(ReminderDateSync.isAligned(makeReminder()))
    }

    func testClearingTheDueDateReportsNoAlignment() {
        let report = ReminderDateSync.setDue(divergedReminder(), to: nil)

        XCTAssertNil(report.aligned)
        XCTAssertNil(report.dictionary["aligned"])
    }

    // MARK: - Response shape

    func testReportDictionaryUsesSnakeCaseKeys() {
        let report = ReminderDateSync.Report(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0)

        XCTAssertEqual(report.dictionary["start_date"] as? String, "shifted")
        XCTAssertEqual(report.dictionary["absolute_alarms_shifted"] as? Int, 1)
        XCTAssertEqual(report.dictionary["absolute_alarms_removed"] as? Int, 0)
        XCTAssertNil(report.dictionary["aligned"], "omitted when unknown")
    }

    func testReportDictionaryCarriesAlignedAndTheSetStart() {
        let report = ReminderDateSync.Report(startDate: .set, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0, aligned: false)

        XCTAssertEqual(report.dictionary["start_date"] as? String, "set")
        XCTAssertEqual(report.dictionary["aligned"] as? Bool, false)
    }

    // MARK: - PR #256 verify round 1

    /// A floating reminder whose stored due drops its zone on save, the way #237's store did:
    /// `reload` stands in for re-reading the reminder after the save.
    private func dropZone(_ reminder: EKReminder) {
        guard var due = reminder.dueDateComponents else { return }
        due.calendar = nil
        due.timeZone = nil
        reminder.timeZone = nil
        reminder.dueDateComponents = due
    }

    private func dropTime(_ reminder: EKReminder) {
        guard let due = reminder.dueDateComponents else { return }
        reminder.dueDateComponents = DateComponents(year: due.year, month: due.month, day: due.day)
    }

    private func floatingDateOnlyReminder() -> EKReminder {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 7)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 7, hour: 0, minute: 0)
        return reminder
    }

    /// Verify 1: the #237 check runs on the saved reminder. If the due read back after the save has
    /// lost its zone, the fallback runs and the reminder is saved again.
    func testConfirmSavedRunsTheFallbackWhenTheSavedDueLostItsZone() throws {
        let reminder = floatingDateOnlyReminder()
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var saves = 0
        var reloads = 0

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report,
                                                      save: { saves += 1 },
                                                      reload: { reloads += 1; if reloads == 1 { self.dropZone(reminder) }; return true },
                                                      rollback: { XCTFail("nothing to roll back") })

        XCTAssertEqual(saves, 1, "the fallback is saved")
        XCTAssertEqual(reloads, 2, "and read back again")
        XCTAssertEqual(reminder.dueDateComponents?.hour, 10)
        XCTAssertNotNil(reminder.dueDateComponents?.timeZone)
        XCTAssertEqual(confirmed.aligned, true)
    }

    /// Verify 1: `aligned` is judged on the reminder as read back, not on the in-memory state.
    func testConfirmSavedJudgesAlignmentOnTheReminderAsReadBack() {
        let reminder = divergedReminder()
        let report = ReminderDateSync.realign(reminder)
        XCTAssertEqual(report.aligned, true, "in memory")

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: {},
                                                      reload: { reminder.startDateComponents = self.components(self.date(2026, 10, 4, 10, in: self.taipei), in: self.taipei); return true },
                                                      rollback: {})

        XCTAssertEqual(confirmed.aligned, false)
        XCTAssertEqual(confirmed.startDate, report.startDate)
        XCTAssertEqual(confirmed.absoluteAlarmsShifted, report.absoluteAlarmsShifted)
    }

    /// Verify 2: a timed due that still reads back date-only after the fallback is not aligned,
    /// even though the start and alarm are on its day.
    func testConfirmSavedReportsNotAlignedWhenTheSavedDueKeepsLosingItsTime() {
        let reminder = floatingDateOnlyReminder()
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var saves = 0

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: { saves += 1 },
                                                      reload: { self.dropTime(reminder); return true }, rollback: {})

        XCTAssertEqual(saves, 1, "the fallback is tried once")
        XCTAssertNil(reminder.dueDateComponents?.hour)
        XCTAssertEqual(confirmed.aligned, false)
    }

    func testConfirmSavedRollsBackAFallbackWhoseSaveFails() {
        let reminder = floatingDateOnlyReminder()
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var rolledBack = false

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report,
                                                      save: { throw NSError(domain: "test", code: 1) },
                                                      reload: { self.dropTime(reminder); return true },
                                                      rollback: { rolledBack = true })

        XCTAssertTrue(rolledBack)
        XCTAssertEqual(confirmed.aligned, false)
    }

    func testConfirmSavedLeavesAClearedDueUnjudged() {
        let reminder = divergedReminder()
        let report = ReminderDateSync.setDue(reminder, to: nil)
        var reloads = 0

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: { XCTFail("no fallback") },
                                                      reload: { reloads += 1; return true }, rollback: {})

        XCTAssertNil(confirmed.aligned)
        XCTAssertEqual(confirmed, report)
    }

    /// Verify 2: the requested precision decides. A timed due that is held date-only is not aligned.
    func testATimedDueRequestedButHeldDateOnlyIsNotAligned() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 8, 23)))

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), true, "a date-only due on its own")
        XCTAssertEqual(ReminderDateSync.isAligned(reminder, requestedTime: true), false)
    }

    /// Verify 3: `aligned` counts a midnight start on the due's day as aligned, so realign leaves
    /// it alone; an aligned reminder is a fixed point of realign.
    func testRealignLeavesAMidnightStartOnTheDuesDayAlone() {
        let reminder = makeReminder()
        let due = date(2026, 10, 8, 10, in: taipei)
        reminder.dueDateComponents = components(due, in: taipei)
        reminder.startDateComponents = components(date(2026, 10, 8, 0, in: taipei), in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 4, 10, in: taipei)))

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(report.startDate, .unchanged)
        XCTAssertEqual(startComponents(reminder), components(date(2026, 10, 8, 0, in: taipei), in: taipei))
        XCTAssertEqual(absoluteDates(reminder), [due])
        XCTAssertEqual(report.aligned, true)
    }

    func testRealigningAnAlignedReminderChangesNothing() {
        let reminder = makeReminder()
        let due = date(2026, 10, 8, 10, in: taipei)
        reminder.dueDateComponents = components(due, in: taipei)
        reminder.startDateComponents = components(date(2026, 10, 8, 0, in: taipei), in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        XCTAssertEqual(ReminderDateSync.isAligned(reminder), true)

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0, aligned: true))
    }

    /// Verify 5: realign alone zones a floating timed due the way `due_date` does (#237).
    func testRealignAloneGivesAFloatingTimedDueAZone() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 0)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 4, hour: 10, minute: 0)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 4, 10)))

        _ = ReminderDateSync.realign(reminder)

        XCTAssertEqual(reminder.dueDateComponents?.hour, 10)
        XCTAssertNotNil(reminder.dueDateComponents?.timeZone)
        XCTAssertNotNil(reminder.timeZone)
        XCTAssertEqual(absoluteDates(reminder), [local(2026, 10, 8, 10)])
    }

    /// Verify 6, the documented cost of the earliest-alarm anchor: a stale alarm earlier than a
    /// correct "day before" alarm becomes the anchor, so the day-before alarm ends up after the due.
    func testAStaleEarlierAlarmPushesABeforeDueAlarmPastTheDue() {
        let reminder = makeReminder()
        let due = date(2026, 10, 8, 10, in: taipei)
        reminder.dueDateComponents = components(due, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 7, 10, in: taipei)))   // a day before, intended
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 1, 10, in: taipei)))   // stale

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(absoluteDates(reminder), [due, date(2026, 10, 14, 10, in: taipei)])
        XCTAssertEqual(report.aligned, true)
    }

    /// Verify 10: undo of an update on a floating reminder returns the item to floating. Writing the
    /// recorded floating due resets the item zone #237 assigned.
    func testUndoSnapshotReturnsAFloatingReminderToFloating() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 7)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 7, hour: 0, minute: 0)
        XCTAssertNil(reminder.timeZone)
        let snapshot = ReminderSnapshot(from: reminder)

        _ = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        XCTAssertNotNil(reminder.timeZone, "#237 zoned the item")

        reminder.dueDateComponents = snapshot.dueDateComponents
        snapshot.apply(to: reminder, now: Date())

        XCTAssertNil(reminder.timeZone)
        XCTAssertNil(reminder.dueDateComponents?.hour)
        XCTAssertNil(reminder.dueDateComponents?.timeZone)
        XCTAssertEqual(reminder.dueDateComponents?.day, 7)
    }

    // MARK: - PR #256 verify round 2

    /// Round 2, item 1: a due that kept its hour but is still floating after the fallback is the
    /// #237 failure itself, so it is not aligned.
    func testConfirmSavedReportsNotAlignedWhileTheSavedDueStaysFloating() {
        let reminder = floatingDateOnlyReminder()
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var saves = 0

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: { saves += 1 },
                                                      reload: { self.dropZone(reminder); return true },
                                                      rollback: {}, log: { _ in })

        XCTAssertEqual(saves, 1, "the fallback is tried once")
        XCTAssertEqual(reminder.dueDateComponents?.hour, 10)
        XCTAssertNil(reminder.dueDateComponents?.timeZone)
        XCTAssertEqual(confirmed.aligned, false)
    }

    /// Round 2, items 1 and 4: the zone is lost and the fallback save fails. Not aligned, and the
    /// log line carries a stable code and nothing from the reminder.
    func testConfirmSavedReportsNotAlignedWhenTheZoneIsLostAndTheFallbackSaveFails() {
        let reminder = floatingDateOnlyReminder()
        reminder.title = "Private title"
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var logged: [String] = []
        var rolledBack = false

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report,
                                                      save: { throw NSError(domain: EKErrorDomain, code: 1) },
                                                      reload: { self.dropZone(reminder); return true },
                                                      rollback: { rolledBack = true }, log: { logged.append($0) })

        XCTAssertTrue(rolledBack)
        XCTAssertEqual(confirmed.aligned, false)
        XCTAssertTrue(logged.contains { $0.contains("eventkit_error_1") }, "\(logged)")
        XCTAssertFalse(logged.joined().contains("Private title"))
    }

    /// Round 2, item 2: a reminder that cannot be read back after the save (`refresh()` returned
    /// false: deleted or invalidated) is not confirmed, so it is not aligned, and no fallback is
    /// written on top of state that was not re-read.
    func testConfirmSavedReportsNotAlignedWhenTheReminderCannotBeReadBack() {
        let reminder = divergedReminder()
        let report = ReminderDateSync.realign(reminder)
        XCTAssertEqual(report.aligned, true, "in memory")
        var saves = 0

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: { saves += 1 },
                                                      reload: { false }, rollback: {}, log: { _ in })

        XCTAssertEqual(confirmed.aligned, false)
        XCTAssertEqual(saves, 0)
    }

    /// Round 2, item 4: the second save is visible in the log, with constant text.
    func testConfirmSavedLogsTheSecondSave() {
        let reminder = floatingDateOnlyReminder()
        reminder.title = "Private title"
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var reloads = 0
        var logged: [String] = []

        _ = ReminderDateSync.confirmSaved(reminder, report: report, save: {},
                                          reload: { reloads += 1; if reloads == 1 { self.dropZone(reminder) }; return true },
                                          rollback: {}, log: { logged.append($0) })

        XCTAssertEqual(logged.count, 1, "\(logged)")
        XCTAssertTrue(logged.first?.contains("saving again") ?? false, "\(logged)")
        XCTAssertFalse(logged.joined().contains("Private title"))
    }

    func testATimedDueRequestedButHeldFloatingIsNotAligned() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 0)

        XCTAssertEqual(ReminderDateSync.isAligned(reminder), true, "a floating timed due on its own")
        XCTAssertEqual(ReminderDateSync.isAligned(reminder, requestedTime: true), false)
    }

    /// Round 2, item 3: one predicate for `aligned` and realign. For a date-only due any start on
    /// its day agrees, so realign leaves it, and the reminder is a fixed point of realign.
    func testRealignLeavesAnyStartOnADateOnlyDuesDayAlone() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 8, hour: 15, minute: 0)
        reminder.addAlarm(EKAlarm(absoluteDate: local(2026, 10, 8, 9)))
        XCTAssertEqual(ReminderDateSync.isAligned(reminder), true)

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0, aligned: true))
        XCTAssertEqual(reminder.startDateComponents?.hour, 15)
    }

    func testRealignMovesAStartOnAnotherDayOntoADateOnlyDue() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 10, day: 8)
        reminder.startDateComponents = DateComponents(year: 2026, month: 10, day: 4, hour: 15, minute: 0)

        let report = ReminderDateSync.realign(reminder)

        XCTAssertEqual(report.startDate, .shifted)
        XCTAssertEqual(reminder.startDateComponents?.day, 8)
        XCTAssertEqual(report.aligned, true)
    }

    // MARK: - PR #256 verify round 3

    /// The second read-back, after the fallback save, can fail too: not confirmed, not aligned.
    func testConfirmSavedReportsNotAlignedWhenTheReadBackAfterTheFallbackFails() {
        let reminder = floatingDateOnlyReminder()
        let report = ReminderDateSync.setDue(reminder, to: local(2026, 10, 8, 10))
        var reloads = 0
        var saves = 0

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: { saves += 1 },
                                                      reload: {
                                                          reloads += 1
                                                          if reloads == 1 { self.dropZone(reminder); return true }
                                                          return false
                                                      },
                                                      rollback: {}, log: { _ in })

        XCTAssertEqual(saves, 1, "the fallback was saved")
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(confirmed.aligned, false)
    }

    // MARK: - #251: restoring recorded dates (undo)

    /// Written with an explicit zone, not the host's, so the expectations hold in any host zone.
    private func taipeiComponents(day: Int, hour: Int) -> DateComponents {
        DateComponents(timeZone: taipei, year: 2026, month: 10, day: day, hour: hour, minute: 0)
    }

    private let dateOnlyStart = DateComponents(year: 2026, month: 10, day: 9)

    /// The date a set of components holds. A due written beside a start makes EventKit derive both
    /// again and add era, second and weekday fields that hold nothing new.
    private func dateValue(_ c: DateComponents?) -> DateComponents? {
        guard let c else { return nil }
        return DateComponents(timeZone: c.timeZone, year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
    }

    /// A date-only start beside a zoned timed due. Written due first (undo before #251), the start
    /// turned the due date-only; written start first with a plain due write, the due lost its zone
    /// and, in memory, took the host's wall clock. `restore` writes the due as `setDue` does:
    /// `writeZonedDue` stamps the date-only start 00:00 on the floating item and zones the item
    /// from the due, so the start comes back as 00:00 of its day in the due's zone (in memory).
    func testRestoreKeepsTheTimeAndZoneOfADueBesideADateOnlyStart() {
        let reminder = makeReminder()

        ReminderDateSync.restore(reminder, start: dateOnlyStart, due: taipeiComponents(day: 10, hour: 15))

        XCTAssertEqual(dateValue(reminder.dueDateComponents), taipeiComponents(day: 10, hour: 15))
        XCTAssertEqual(reminder.timeZone, taipei)
        XCTAssertEqual(dateValue(reminder.startDateComponents), taipeiComponents(day: 9, hour: 0))
    }

    /// The same on a reminder that an update zoned and moved (update-undo): in memory, writing the
    /// date-only start leaves the item floating again, so the same path applies. Checked in PR
    /// #277 verify round 2: with neither the 00:00 stamp in `writeZonedDue` nor its fallback
    /// (`writeDueAroundStart`), this test and the one above fail; with either one, both pass.
    func testRestoreOnAZonedReminderKeepsTheTimeAndZoneOfADueBesideADateOnlyStart() {
        let reminder = makeReminder()
        reminder.startDateComponents = taipeiComponents(day: 12, hour: 0)
        reminder.dueDateComponents = taipeiComponents(day: 12, hour: 9)
        reminder.timeZone = taipei

        ReminderDateSync.restore(reminder, start: dateOnlyStart, due: taipeiComponents(day: 10, hour: 15))

        XCTAssertEqual(dateValue(reminder.dueDateComponents), taipeiComponents(day: 10, hour: 15))
        XCTAssertEqual(dateValue(reminder.startDateComponents), taipeiComponents(day: 9, hour: 0))
    }

    /// A timed start beside a zoned due, the state a stored reminder has since #237, comes back as
    /// recorded.
    func testRestoreWritesATimedStartAndDueAsRecorded() {
        let reminder = makeReminder()
        reminder.startDateComponents = taipeiComponents(day: 12, hour: 0)
        reminder.dueDateComponents = taipeiComponents(day: 12, hour: 9)
        reminder.timeZone = taipei

        ReminderDateSync.restore(reminder, start: taipeiComponents(day: 9, hour: 8), due: taipeiComponents(day: 10, hour: 15))

        XCTAssertEqual(dateValue(reminder.startDateComponents), taipeiComponents(day: 9, hour: 8))
        XCTAssertEqual(dateValue(reminder.dueDateComponents), taipeiComponents(day: 10, hour: 15))
        XCTAssertEqual(reminder.timeZone, taipei)
    }

    /// EventKit gives a reminder without a start one equal to a due written to it (#235), in memory
    /// too. A recorded absent start stays absent, for a zoned and for a floating due. This pins the
    /// clearing in `restore`: checked in PR #277 verify round 2, without it both cases fail, each
    /// reading back a start equal to the due (the zoned one with the due's zone).
    func testRestoreLeavesARecordedAbsentStartAbsent() {
        for due in [taipeiComponents(day: 10, hour: 15), DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 0)] {
            let reminder = makeReminder()

            ReminderDateSync.restore(reminder, start: nil, due: due)

            XCTAssertNil(reminder.startDateComponents)
            XCTAssertEqual(reminder.dueDateComponents?.hour, 15)
            XCTAssertEqual(reminder.dueDateComponents?.timeZone, due.timeZone)
        }
    }

    // MARK: - Date-only due (#267)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
        DateComponents(year: y, month: m, day: d)
    }

    private func ymd(_ c: DateComponents?) -> [Int?] {
        [c?.year, c?.month, c?.day]
    }

    // A timed reminder made date-only: due and start become the day with no time, the absolute
    // alarm is removed (on device it kept the display on its old date and time), and relative and
    // location alarms stay.
    func testADayOnATimedReminderWritesADateOnlyDueAndStartAndRemovesAbsoluteAlarms() {
        let oldDue = date(2026, 10, 18, 17, in: taipei)
        let reminder = makeReminder()
        reminder.startDateComponents = components(oldDue, in: taipei)
        reminder.dueDateComponents = components(oldDue, in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: oldDue))
        reminder.addAlarm(EKAlarm(relativeOffset: -600))
        let place = EKAlarm()
        place.structuredLocation = EKStructuredLocation(title: "Office")
        reminder.addAlarm(place)

        let report = ReminderDateSync.setDueDay(reminder, to: day(2026, 10, 19))

        XCTAssertEqual(report, .init(startDate: .shifted, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 1, aligned: true))
        XCTAssertEqual(report.writtenDue, day(2026, 10, 19))
        XCTAssertEqual(ymd(reminder.dueDateComponents), [2026, 10, 19])
        XCTAssertNil(reminder.dueDateComponents?.hour)
        XCTAssertNil(reminder.dueDateComponents?.timeZone)
        XCTAssertEqual(ymd(reminder.startDateComponents), [2026, 10, 19])
        XCTAssertNil(reminder.startDateComponents?.hour)
        XCTAssertEqual(absoluteDates(reminder), [])
        XCTAssertEqual((reminder.alarms ?? []).map(\.relativeOffset).filter { $0 != 0 }, [-600])
        XCTAssertEqual((reminder.alarms ?? []).compactMap(\.structuredLocation?.title), ["Office"])
    }

    func testADayOnAnUndatedReminderSetsTheStart() {
        let reminder = makeReminder()

        let report = ReminderDateSync.setDueDay(reminder, to: day(2026, 10, 18))

        XCTAssertEqual(report, .init(startDate: .set, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0, aligned: true))
        XCTAssertEqual(ymd(reminder.dueDateComponents), [2026, 10, 18])
        XCTAssertNil(reminder.dueDateComponents?.hour)
    }

    // The same day again: nothing moves, and the start reads unchanged.
    func testTheSameDayOnADateOnlyReminderLeavesItUnchanged() {
        let reminder = makeReminder()
        reminder.dueDateComponents = day(2026, 10, 18)
        reminder.startDateComponents = day(2026, 10, 18)

        let report = ReminderDateSync.setDueDay(reminder, to: day(2026, 10, 18))

        XCTAssertEqual(report, .init(startDate: .unchanged, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0, aligned: true))
    }

    // Every absolute alarm goes, not only the one at the due: the app displays the earliest.
    func testADayRemovesEveryAbsoluteAlarm() {
        let reminder = makeReminder()
        reminder.dueDateComponents = components(date(2026, 10, 18, 17, in: taipei), in: taipei)
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 18, 9, in: taipei)))
        reminder.addAlarm(EKAlarm(absoluteDate: date(2026, 10, 18, 17, in: taipei)))

        let report = ReminderDateSync.setDueDay(reminder, to: day(2026, 10, 18))

        XCTAssertEqual(report.absoluteAlarmsRemoved, 2)
        XCTAssertEqual(absoluteDates(reminder), [])
    }

    // Verify round 1 (PR #298): a date-only write whose due reads back with a time is not aligned,
    // whatever the start and alarms say. Only iCloud was checked on device; another store could
    // hand the day back timed.
    func testADayThatReadsBackWithATimeIsNotAligned() {
        let reminder = makeReminder()
        let report = ReminderDateSync.setDueDay(reminder, to: day(2026, 10, 18))

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: {}, reload: {
            var timed = DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 0)
            timed.timeZone = self.taipei
            reminder.startDateComponents = nil
            reminder.dueDateComponents = timed
            return true
        }, rollback: {}, log: { _ in })

        XCTAssertEqual(confirmed.aligned, false)
    }

    func testADayThatReadsBackDateOnlyIsAligned() {
        let reminder = makeReminder()
        let report = ReminderDateSync.setDueDay(reminder, to: day(2026, 10, 18))

        let confirmed = ReminderDateSync.confirmSaved(reminder, report: report, save: {}, reload: { true },
                                                      rollback: {}, log: { _ in })

        XCTAssertEqual(confirmed.aligned, true)
    }
}
