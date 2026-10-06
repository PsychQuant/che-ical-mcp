import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #231: `list_reminders` / `search_reminders` read their output from
/// `ReminderReadSnapshot`, which copied the due date and the location alarm but
/// not the start date or the time-based alarms. Reminders.app shows both (#227),
/// so a reminder with only a start date or only an alarm looked undated.
final class ReminderReadScheduleTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func makeReminder() -> EKReminder {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        return reminder
    }

    private func locationAlarm() -> EKAlarm {
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        place.radius = 100
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = .enter
        return alarm
    }

    private func withoutCalendar(_ components: DateComponents?) -> DateComponents? {
        guard var components else { return nil }
        components.calendar = nil
        return components
    }

    /// On device a location alarm reads back as `absoluteDate == nil`,
    /// `relativeOffset == 0`. Classifying by the absolute date alone would turn
    /// every geofence into an alarm "0 minutes before".
    func testLocationAlarmStaysOutOfTimeBasedAlarms() {
        let reminder = makeReminder()
        let geofence = locationAlarm()
        XCTAssertNil(geofence.absoluteDate)
        XCTAssertEqual(geofence.relativeOffset, 0)
        reminder.addAlarm(geofence)

        let snapshot = ReminderReadSnapshot(from: reminder)

        XCTAssertEqual(snapshot.alarms, [])
        XCTAssertEqual(snapshot.locationTrigger?.title, "Office")
    }

    func testRelativeAlarmAtTheDueTimeIsStillARelativeAlarm() {
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(relativeOffset: 0))

        XCTAssertEqual(ReminderReadSnapshot(from: reminder).alarms, [.relative(seconds: 0)])
    }

    /// `EKCalendarItem.alarms` is not in insertion order, and its order changes from one
    /// process launch to the next (checked 2026-10-05), so every `--cli` call would list the
    /// alarms differently. The snapshot sorts them: absolute alarms by date, then relative
    /// alarms earliest first. Five alarms make an accidental pass 1 in 120.
    func testAlarmsAreSortedAbsoluteByDateThenRelativeEarliestFirst() {
        let reminder = makeReminder()
        let later = Date(timeIntervalSince1970: 1_791_615_600)     // 2026-10-10T07:00:00Z
        let earlier = Date(timeIntervalSince1970: 1_791_600_000)   // 2026-10-10T02:40:00Z
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        reminder.addAlarm(locationAlarm())
        reminder.addAlarm(EKAlarm(absoluteDate: later))
        reminder.addAlarm(EKAlarm(relativeOffset: 600))
        reminder.addAlarm(EKAlarm(absoluteDate: earlier))
        reminder.addAlarm(EKAlarm(relativeOffset: -3600))

        let snapshot = ReminderReadSnapshot(from: reminder)

        XCTAssertEqual(snapshot.alarms, [.absolute(earlier), .absolute(later),
                                         .relative(seconds: -3600), .relative(seconds: -900), .relative(seconds: 600)])
        XCTAssertNotNil(snapshot.locationTrigger)
    }

    /// JSON cannot encode NaN or infinity, so an alarm whose offset is not finite
    /// is left out rather than handed to the serializer.
    func testNonFiniteRelativeOffsetIsLeftOut() {
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(relativeOffset: .nan))
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        reminder.addAlarm(EKAlarm(relativeOffset: .infinity))
        reminder.addAlarm(EKAlarm(relativeOffset: -.infinity))

        XCTAssertEqual(ReminderReadSnapshot(from: reminder).alarms, [.relative(seconds: -900)])
    }

    func testTimedStartDateIsCopiedWithItsTimeZone() {
        let reminder = makeReminder()
        let start = DateComponents(timeZone: taipei, year: 2026, month: 10, day: 9, hour: 9, minute: 30)
        reminder.startDateComponents = start

        XCTAssertEqual(withoutCalendar(ReminderReadSnapshot(from: reminder).startDateComponents), start)
    }

    /// On device a timed start on a reminder without a due date came back with
    /// `timeZone == nil`. The snapshot keeps that, so the output can show it.
    func testFloatingStartDateIsCopiedWithoutATimeZone() {
        let reminder = makeReminder()
        let start = DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 30)
        reminder.startDateComponents = start

        let copied = ReminderReadSnapshot(from: reminder).startDateComponents
        XCTAssertEqual(withoutCalendar(copied), start)
        XCTAssertNil(copied?.timeZone)
    }

    func testReminderWithoutStartOrAlarmsHasNeither() {
        let snapshot = ReminderReadSnapshot(from: makeReminder())

        XCTAssertNil(snapshot.startDateComponents)
        XCTAssertEqual(snapshot.alarms, [])
    }
}
