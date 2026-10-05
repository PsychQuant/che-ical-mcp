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

    // MARK: - Response shape

    func testReportDictionaryUsesSnakeCaseKeys() {
        let report = ReminderDateSync.Report(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0)

        XCTAssertEqual(report.dictionary["start_date"] as? String, "shifted")
        XCTAssertEqual(report.dictionary["absolute_alarms_shifted"] as? Int, 1)
        XCTAssertEqual(report.dictionary["absolute_alarms_removed"] as? Int, 0)
    }
}
