import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #227 / #228: undo of `update_reminder` / `delete_reminder` restores a reminder from
/// `ReminderSnapshot`. Alarms recorded as offsets came back wrong: an absolute alarm (#227)
/// and a location alarm (#228) both report offset 0, so undo rebuilt them as alarms at the
/// due time. Delete-undo recreates the reminder, so recurrence rules and the URL must be in
/// the snapshot too (#228).
final class ReminderSnapshotTests: XCTestCase {
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    /// An item whose store was deallocated reads back no alarms, so the store lives as long
    /// as the test.
    private let store = EKEventStore()

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
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        return reminder
    }

    private func withoutCalendar(_ c: DateComponents?) -> DateComponents? {
        guard var c else { return nil }
        c.calendar = nil
        return c
    }

    /// The date a set of components holds. A due written beside a start makes EventKit derive both
    /// again and add era, second and weekday fields that hold nothing new (#251 writes the start
    /// first, so the start is derived again too).
    private func dateValue(_ c: DateComponents?) -> DateComponents? {
        guard let c else { return nil }
        return DateComponents(timeZone: c.timeZone, year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
    }

    private func locationAlarm() -> EKAlarm {
        let place = EKStructuredLocation(title: "Probe place")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        place.radius = 150
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = .enter
        return alarm
    }

    private func alarms(_ reminder: EKReminder) -> Set<AlarmSnapshot> {
        Set((reminder.alarms ?? []).map(AlarmSnapshot.init(from:)))
    }

    private func weeklyFourTimes() -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 4))
    }

    // MARK: - Dates and alarms (#227, #228 item 1)

    func testSnapshotCapturesStartDateAndEveryKindOfAlarm() {
        let reminder = makeReminder()
        let start = components(2026, 10, 4, 10)
        reminder.startDateComponents = start
        reminder.addAlarm(EKAlarm(absoluteDate: instant(start)))
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        reminder.addAlarm(locationAlarm())

        let snapshot = ReminderSnapshot(from: reminder)

        XCTAssertEqual(withoutCalendar(snapshot.startDateComponents), start)
        XCTAssertEqual(Set(snapshot.alarms), alarms(reminder))
        XCTAssertEqual(snapshot.alarms.compactMap(\.absoluteDate), [instant(start)])
        XCTAssertEqual(snapshot.alarms.compactMap(\.location?.title), ["Probe place"],
                       "a location alarm must not be recorded as offset 0")
    }

    func testApplyingTheSnapshotRestoresStartDateAndEveryKindOfAlarm() {
        let original = makeReminder()
        let start = components(2026, 10, 4, 10)
        original.startDateComponents = start
        original.addAlarm(EKAlarm(absoluteDate: instant(start)))
        original.addAlarm(EKAlarm(relativeOffset: -900))
        original.addAlarm(locationAlarm())
        let snapshot = ReminderSnapshot(from: original)

        // The state after an update moved everything to Oct 8 and cleared the location trigger.
        let moved = makeReminder()
        moved.startDateComponents = components(2026, 10, 8, 10)
        moved.addAlarm(EKAlarm(absoluteDate: instant(components(2026, 10, 8, 10))))
        moved.addAlarm(EKAlarm(relativeOffset: -900))

        snapshot.apply(to: moved, now: now)

        XCTAssertEqual(withoutCalendar(moved.startDateComponents), start)
        XCTAssertEqual(alarms(moved), alarms(original))
        XCTAssertEqual(moved.alarms?.filter { $0.structuredLocation != nil }.first?.proximity, .enter)
    }

    func testApplyingASnapshotWithoutStartDateOrAlarmsClearsThem() {
        let snapshot = ReminderSnapshot(from: makeReminder())
        let moved = makeReminder()
        moved.startDateComponents = components(2026, 10, 8, 10)
        moved.addAlarm(locationAlarm())

        snapshot.apply(to: moved, now: now)

        XCTAssertNil(moved.startDateComponents)
        XCTAssertEqual(moved.alarms ?? [], [])
    }

    /// #228 item 1: undoing an update that did not touch the alarms (here a title change) used
    /// to rebuild the location alarm as a time alarm at the due time.
    func testUndoOfATitleChangeKeepsTheLocationAlarm() {
        let reminder = makeReminder()
        reminder.title = "Pick up"
        reminder.addAlarm(locationAlarm())
        let snapshot = ReminderSnapshot(from: reminder)
        reminder.title = "Renamed"

        snapshot.apply(to: reminder, now: now)

        XCTAssertEqual(reminder.title, "Pick up")
        XCTAssertEqual(reminder.alarms?.count, 1)
        XCTAssertEqual(reminder.alarms?.first?.structuredLocation?.title, "Probe place")
    }

    // MARK: - Start before due (#251)

    /// A date-only start beside a timed due. Written start first, as `ReminderDateSync` does;
    /// written the other way round, EventKit turns the due date-only in memory. The components
    /// are floating, so nothing depends on the host zone.
    private func dateOnlyStartAndTimedDue() -> ReminderSnapshot {
        let original = makeReminder()
        original.startDateComponents = DateComponents(year: 2026, month: 10, day: 9)
        original.dueDateComponents = DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 0)
        return ReminderSnapshot(from: original)
    }

    /// #251: undo wrote the recorded due before the recorded start, so a date-only start turned
    /// the restored due date-only. Delete-undo, on a new reminder.
    func testApplyingOnANewReminderKeepsTheDueTimeBesideADateOnlyStart() {
        let snapshot = dateOnlyStartAndTimedDue()
        XCTAssertNil(snapshot.startDateComponents?.hour, "precondition: a date-only start")
        XCTAssertEqual(snapshot.dueDateComponents?.hour, 15, "precondition: a timed due")
        let recreated = makeReminder()

        snapshot.apply(to: recreated, now: now)

        XCTAssertEqual(recreated.dueDateComponents?.day, 10)
        XCTAssertEqual(recreated.dueDateComponents?.hour, 15)
        XCTAssertEqual(recreated.dueDateComponents?.minute, 0)
        XCTAssertEqual(recreated.startDateComponents?.day, 9)
        XCTAssertNil(recreated.startDateComponents?.hour)
    }

    /// #251, update-undo: the reminder holds the zoned dates an update left. In memory the recorded
    /// floating dates come back floating and the due keeps its time; whether a saved item that had
    /// a zone stays floating is not checked here (#237 notes, #275).
    func testUndoOnAZonedReminderKeepsTheDueTimeBesideADateOnlyStart() {
        let snapshot = dateOnlyStartAndTimedDue()
        let reminder = makeReminder()
        reminder.startDateComponents = components(2026, 10, 12, 0)
        reminder.dueDateComponents = components(2026, 10, 12, 9)
        reminder.timeZone = taipei

        snapshot.apply(to: reminder, now: now)

        XCTAssertEqual(reminder.dueDateComponents?.day, 10)
        XCTAssertEqual(reminder.dueDateComponents?.hour, 15)
        XCTAssertNil(reminder.dueDateComponents?.timeZone)
        XCTAssertNil(reminder.timeZone)
        XCTAssertEqual(reminder.startDateComponents?.day, 9)
        XCTAssertNil(reminder.startDateComponents?.hour)
    }

    // MARK: - Recurrence and URL (#228 item 3, url)

    func testSnapshotCapturesRecurrenceRules() {
        let reminder = makeReminder()
        reminder.dueDateComponents = components(2026, 10, 6, 9)
        reminder.addRecurrenceRule(weeklyFourTimes())

        let rules = ReminderSnapshot(from: reminder).recurrenceRules

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.frequency, .weekly)
        XCTAssertEqual(rules.first?.occurrenceCount, 4)
    }

    /// Delete-undo of a repeating reminder used to recreate a one-off reminder.
    func testApplyingOnANewReminderRestoresRecurrence() {
        let original = makeReminder()
        original.dueDateComponents = components(2026, 10, 6, 9)
        original.addRecurrenceRule(weeklyFourTimes())
        let snapshot = ReminderSnapshot(from: original)
        let recreated = makeReminder()

        snapshot.apply(to: recreated, now: now)

        XCTAssertEqual(recreated.recurrenceRules?.count, 1)
        XCTAssertEqual(recreated.recurrenceRules?.first?.frequency, .weekly)
        XCTAssertEqual(recreated.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount, 4)
        XCTAssertNotNil(recreated.dueDateComponents, "EventKit refuses a repeating reminder without a due date")
    }

    /// #253 verify #8: delete-undo of an every-other-week reminder whose weeks start on
    /// Sunday came back with weeks starting on Monday, which moves its Sunday occurrences.
    func testApplyingOnANewReminderKeepsTheWeekStart() throws {
        let original = makeReminder()
        original.dueDateComponents = components(2026, 10, 4, 9)
        let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 2,
                                    daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.sunday)],
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: nil)
        try setWeekStart(1, on: rule)
        original.addRecurrenceRule(rule)
        let snapshot = ReminderSnapshot(from: original)
        let recreated = makeReminder()

        snapshot.apply(to: recreated, now: now)

        XCTAssertEqual(recreated.recurrenceRules?.first?.interval, 2)
        XCTAssertEqual(recreated.recurrenceRules?.first?.firstDayOfTheWeek, 1)
    }

    func testASnapshotWithoutRulesClearsThem() {
        let snapshot = ReminderSnapshot(from: makeReminder())
        let target = makeReminder()
        target.dueDateComponents = components(2026, 10, 6, 9)
        target.addRecurrenceRule(weeklyFourTimes())

        snapshot.apply(to: target, now: now)

        XCTAssertEqual(target.recurrenceRules ?? [], [])
    }

    /// Update-undo cannot have changed the rules (`update_reminder` has no recurrence
    /// parameter), so the existing rule stays as it is.
    func testUnchangedRulesAreLeftInPlace() {
        let reminder = makeReminder()
        reminder.dueDateComponents = components(2026, 10, 6, 9)
        reminder.addRecurrenceRule(weeklyFourTimes())
        let rule = reminder.recurrenceRules?.first
        let snapshot = ReminderSnapshot(from: reminder)

        snapshot.apply(to: reminder, now: now)

        XCTAssertTrue(reminder.recurrenceRules?.first === rule)
    }

    func testApplyingRestoresTheURL() {
        let original = makeReminder()
        original.url = URL(string: "https://example.com/ticket/228")
        let snapshot = ReminderSnapshot(from: original)
        let recreated = makeReminder()

        snapshot.apply(to: recreated, now: now)

        XCTAssertEqual(recreated.url, URL(string: "https://example.com/ticket/228"))
    }

    // MARK: - Delete-undo round trip

    /// Delete-undo builds a new reminder from the snapshot; every recorded field comes back.
    func testANewReminderBuiltFromTheSnapshotHasTheSameSnapshot() {
        let original = makeReminder()
        original.title = "Water plants"
        original.notes = "Balcony"
        original.priority = 1
        let due = components(2026, 10, 6, 9)
        original.dueDateComponents = due
        original.startDateComponents = due
        original.url = URL(string: "https://example.com/plants")
        original.addRecurrenceRule(weeklyFourTimes())
        original.addAlarm(EKAlarm(absoluteDate: instant(due).addingTimeInterval(-3600)))
        original.addAlarm(EKAlarm(relativeOffset: -600))
        original.addAlarm(locationAlarm())
        let snapshot = ReminderSnapshot(from: original)

        let recreated = makeReminder()
        snapshot.apply(to: recreated, now: now)
        let again = ReminderSnapshot(from: recreated)

        XCTAssertEqual(again.title, snapshot.title)
        XCTAssertEqual(again.notes, snapshot.notes)
        XCTAssertEqual(again.priority, snapshot.priority)
        XCTAssertEqual(again.isCompleted, snapshot.isCompleted)
        XCTAssertEqual(dateValue(again.dueDateComponents), dateValue(snapshot.dueDateComponents))
        XCTAssertEqual(dateValue(again.startDateComponents), dateValue(snapshot.startDateComponents))
        XCTAssertEqual(again.url, snapshot.url)
        XCTAssertEqual(Set(again.alarms), Set(snapshot.alarms))
        XCTAssertEqual(again.alarms.count, 3)
        XCTAssertEqual(again.recurrenceRules, snapshot.recurrenceRules)
    }
}
