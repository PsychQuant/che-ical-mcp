import CheMCPKit
import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #236: before an undo or redo writes, it compares the item with the state the recorded write
/// left and refuses when a field changed since and the undo would change it again (diagnosis D1;
/// PR #259 verify #9). An update-undo compares the fields it writes back; a create-undo, which
/// deletes, compares the fields a person edits (verify #7). Every EventKit object here is in
/// memory (never fetched or saved), so no TCC prompt.
final class UndoPostStateGuardTests: XCTestCase {
    /// An item whose store was deallocated reads back no alarms, so the store lives as long as
    /// the test.
    private let store = EKEventStore()
    private lazy var calendarA = EKCalendar(for: .event, eventStore: store)
    private lazy var calendarB = EKCalendar(for: .event, eventStore: store)
    private lazy var listA = EKCalendar(for: .reminder, eventStore: store)
    private lazy var listB = EKCalendar(for: .reminder, eventStore: store)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    // MARK: - Fixtures

    private func office(latitude: Double = 25.04) -> EKStructuredLocation {
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: latitude, longitude: 121.61)
        place.radius = 150
        return place
    }

    private func makeEvent() -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendarA
        event.title = "Review"
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.timeZone = taipei
        event.notes = "agenda"
        event.structuredLocation = office()
        event.location = "Office"
        event.url = URL(string: "https://example.com/review")
        event.addAlarm(EKAlarm(relativeOffset: -900))
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 4))]
        return event
    }

    private func components(hour: Int) -> DateComponents {
        DateComponents(timeZone: taipei, year: 2026, month: 10, day: 10, hour: hour, minute: 0)
    }

    private func makeReminder() -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = listA
        reminder.title = "Pay rent"
        reminder.notes = "transfer"
        reminder.priority = 1
        reminder.startDateComponents = components(hour: 9)
        reminder.dueDateComponents = components(hour: 9)
        reminder.url = URL(string: "https://example.com/rent")
        reminder.addAlarm(EKAlarm(relativeOffset: -600))
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
        return reminder
    }

    // MARK: - Events: update-undo (restores a snapshot)

    func testUnchangedEventHasNoChangedFields() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), [])
    }

    /// Restoring the recorded state itself, so every changed field also differs from the target.
    func testEachChangedEventFieldIsNamedForAnUpdateUndo() {
        XCTAssertNotEqual(calendarA.calendarIdentifier, calendarB.calendarIdentifier, "precondition: distinct calendars")
        // A new location string replaces the place (EventKit couples the two), so it reports both.
        let edits: [(fields: [String], edit: (EKEvent) -> Void)] = [
            (["title"], { $0.title = "Retro" }),
            (["start_time"], { $0.startDate = $0.startDate.addingTimeInterval(1800) }),
            (["end_time"], { $0.endDate = $0.endDate.addingTimeInterval(1800) }),
            (["calendar"], { [calendarB] in $0.calendar = calendarB }),
            (["notes"], { $0.notes = "new agenda" }),
            (["location", "structured_location"], { $0.location = "Lab" }),
            (["url"], { $0.url = URL(string: "https://example.com/other") }),
            (["timezone"], { $0.timeZone = TimeZone(identifier: "America/New_York") }),
            (["alarms"], { $0.addAlarm(EKAlarm(relativeOffset: -60)) }),
            (["structured_location"], { [unowned self] in $0.structuredLocation = office(latitude: 24.0) }),
            // Recurrence is not compared for an update-undo: it restores only one-off events, and
            // an event that repeats at undo time is refused before the comparison (round 5;
            // UndoRecurrenceGuardTests).
        ]
        for (fields, edit) in edits {
            let event = makeEvent()
            let saved = EventSnapshot(from: event)
            edit(event)
            XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), fields, fields[0])
        }
    }

    func testAllDayChangeIsNamed() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.isAllDay = true

        XCTAssertTrue(saved.changedFields(in: EventSnapshot(from: event), restoring: nil).contains("all_day"))
    }

    /// A synced store may not keep sub-second digits; whole seconds are what the tools write.
    func testSubSecondDateDriftIsNotAChange() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.startDate = start.addingTimeInterval(0.4)
        event.endDate = start.addingTimeInterval(3600.4)

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), [])
    }

    /// verify #9: a field already back at the value the undo writes is not overwritten by it, so
    /// it is no reason to refuse. A field changed to anything else still is.
    func testUpdateUndoDoesNotRefuseATitleChangedBackByHand() {
        let event = makeEvent()
        let original = EventSnapshot(from: event)
        event.title = "Retro"                                   // the update
        let saved = EventSnapshot(from: event)

        event.title = "Review"                                  // changed back in Calendar.app
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: original), [])
        event.title = "Planning"                                // changed to something else
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: original), ["title"])
    }

    /// `applySnapshot` writes `location` unconditionally, and EventKit couples it with the
    /// structured location (a new string replaces the place, `nil` clears it; checked in memory),
    /// so the place always round-trips and update-undo always compares it.
    func testUpdateUndoComparesTheStructuredLocation() {
        let withoutLocation = makeEvent()
        withoutLocation.location = nil
        let restored = EventSnapshot(from: withoutLocation)
        XCTAssertNil(restored.structuredLocationTitle, "precondition: clearing location clears the place")

        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.structuredLocation = office(latitude: 24.0)

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: restored), ["structured_location"])
    }

    /// verify #7: a place recorded without coordinates that later gains them under the same name
    /// (geocoding by the calendar app or server) is enrichment, not an edit.
    func testCoordinatesAddedToAPlaceWithoutThemAreNotAChange() {
        let event = makeEvent()
        event.structuredLocation = nil
        event.location = "Office"
        let saved = EventSnapshot(from: event)
        XCTAssertNil(saved.structuredLocationLat, "precondition: a location string carries no coordinates")
        event.structuredLocation = office()

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), [])
    }

    /// verify #7: an alarm sound is cosmetic and a server may set a default one.
    func testAnAlarmSoundIsNotAChange() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.alarms?.forEach(event.removeAlarm)
        let sounding = EKAlarm(relativeOffset: -900)
        sounding.soundName = "Basso"
        event.addAlarm(sounding)

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), [])
    }

    /// A place added by a later update is cleared by restoring a snapshot without a location.
    func testPlaceAddedToAnEventWithoutLocationIsClearedByTheRestore() {
        let event = makeEvent()
        event.location = nil
        let snapshot = EventSnapshot(from: event)
        event.structuredLocation = office()

        snapshot.apply(to: event, calendar: calendarA)

        XCTAssertEqual(snapshot.changedFields(in: EventSnapshot(from: event), restoring: snapshot), [])
    }

    /// D1 round trip: what the undo writes reads back equal to the snapshot it wrote.
    func testRestoringAnEventSnapshotRoundTrips() {
        let event = makeEvent()
        let snapshot = EventSnapshot(from: event)
        event.title = "Retro"
        event.startDate = start.addingTimeInterval(7200)
        event.endDate = start.addingTimeInterval(9000)
        event.notes = nil
        event.location = "Lab"
        event.structuredLocation = office(latitude: 24.0)
        event.url = nil
        event.timeZone = nil
        event.addAlarm(EKAlarm(relativeOffset: -60))
        event.recurrenceRules = nil

        snapshot.apply(to: event, calendar: calendarA)

        XCTAssertEqual(snapshot.changedFields(in: EventSnapshot(from: event), restoring: snapshot), [])
    }

    /// Two updates undone in order: the second undo restores exactly the state the first
    /// update left, so the first undo still matches. A `lastModifiedDate` token would not
    /// (diagnosis D1).
    func testTwoConsecutiveEventUpdatesUndoneInOrderBothPass() {
        let event = makeEvent()
        event.structuredLocation = nil
        event.location = "Office"
        let original = EventSnapshot(from: event)

        event.title = "Retro"                                   // update 1
        let afterFirst = EventSnapshot(from: event)
        event.notes = "moved"                                   // update 2, adds a place
        event.structuredLocation = office(latitude: 24.0)
        let afterSecond = EventSnapshot(from: event)

        XCTAssertEqual(afterSecond.changedFields(in: EventSnapshot(from: event), restoring: afterFirst), [])
        afterFirst.apply(to: event, calendar: calendarA)       // undo 2
        XCTAssertEqual(afterFirst.changedFields(in: EventSnapshot(from: event), restoring: original), [])
        original.apply(to: event, calendar: calendarA)         // undo 1
        XCTAssertEqual(event.title, "Review")
    }

    // MARK: - Events: create-undo (deletes)

    /// The delete removes everything the event holds, so every recorded field counts, a moved
    /// calendar and an added alarm included (PR #259 round 2, finding 1). Only changes a calendar
    /// server is known to make on its own are exempt (see the next test).
    func testCreateUndoComparesEveryRecordedField() {
        let compared: [(fields: [String], edit: (EKEvent) -> Void)] = [
            (["title"], { $0.title = "Retro" }),
            (["start_time"], { $0.startDate = $0.startDate.addingTimeInterval(1800) }),
            (["end_time"], { $0.endDate = $0.endDate.addingTimeInterval(1800) }),
            (["calendar"], { [calendarB] in $0.calendar = calendarB }),
            (["notes"], { $0.notes = "new agenda" }),
            (["location", "structured_location"], { $0.location = "Lab" }),
            (["url"], { $0.url = URL(string: "https://example.com/other") }),
            (["timezone"], { $0.timeZone = TimeZone(identifier: "America/New_York") }),
            (["alarms"], { $0.addAlarm(EKAlarm(relativeOffset: -60)) }),
            (["structured_location"], { [unowned self] in $0.structuredLocation = office(latitude: 24.0) }),
            (["recurrence"], { $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)] }),
        ]
        for (fields, edit) in compared {
            let event = makeEvent()
            let saved = EventSnapshot(from: event)
            edit(event)
            XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), fields, fields[0])
        }
    }

    /// An alarm sound is the one change a server is known to make on its own; the alarm itself
    /// (time, kind, place) still counts.
    func testCreateUndoIgnoresOnlyTheAlarmSound() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.alarms?.forEach(event.removeAlarm)
        let sounding = EKAlarm(relativeOffset: -900)
        sounding.soundName = "Basso"
        event.addAlarm(sounding)

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
    }

    /// The delete has no value to write, so the "already at the value the undo writes" exemption
    /// (finding 9 of round 1) does not apply: a changed field counts. A field changed and then
    /// changed back equals the recorded state again and does not count, like any unchanged field.
    func testCreateUndoHasNoRestoredValueToMatch() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.title = "Retro"
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), ["title"])

        event.title = "Review"
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
    }

    // MARK: - Reminders

    func testUnchangedReminderHasNoChangedFields() {
        let reminder = makeReminder()
        let saved = ReminderSnapshot(from: reminder)

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: saved), [])
        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: nil), [])
    }

    func testEachChangedReminderFieldIsNamedForAnUpdateUndo() {
        XCTAssertNotEqual(listA.calendarIdentifier, listB.calendarIdentifier, "precondition: distinct lists")
        let edits: [(field: String, edit: (EKReminder) -> Void)] = [
            ("title", { $0.title = "Pay bills" }),
            ("list", { [listB] in $0.calendar = listB }),
            ("notes", { $0.notes = nil }),
            ("completed", { $0.isCompleted = true }),
            ("priority", { $0.priority = 5 }),
            ("start_date", { [unowned self] in $0.startDateComponents = components(hour: 8) }),
            ("alarms", { $0.addAlarm(EKAlarm(relativeOffset: -60)) }),
            ("recurrence", { $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)] }),
            ("url", { $0.url = nil }),
        ]
        for (field, edit) in edits {
            let reminder = makeReminder()
            let saved = ReminderSnapshot(from: reminder)
            edit(reminder)
            XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: saved), [field], field)
        }
    }

    /// As for events, the delete compares every recorded field, the list and the alarms included.
    func testCreateReminderUndoComparesEveryRecordedField() {
        let compared: [(field: String, edit: (EKReminder) -> Void)] = [
            ("title", { $0.title = "Pay bills" }),
            ("list", { [listB] in $0.calendar = listB }),
            ("notes", { $0.notes = nil }),
            ("completed", { $0.isCompleted = true }),
            ("priority", { $0.priority = 5 }),
            ("due_date", { [unowned self] in $0.dueDateComponents = components(hour: 11) }),
            ("start_date", { [unowned self] in $0.startDateComponents = components(hour: 8) }),
            ("alarms", { $0.addAlarm(EKAlarm(relativeOffset: -60)) }),
            ("recurrence", { $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)] }),
            ("url", { $0.url = nil }),
        ]
        for (field, edit) in compared {
            let reminder = makeReminder()
            let saved = ReminderSnapshot(from: reminder)
            edit(reminder)
            XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: nil), [field], field)
        }
    }

    /// The documented tolerance applies to absolute alarm dates too (round 2, finding 10).
    /// EventKit itself keeps whole seconds in memory, so the keys are built directly.
    func testAbsoluteAlarmsCompareToTheSecond() {
        func key(_ date: Date) -> UndoPostState.AlarmKey {
            UndoPostState.AlarmKey(absoluteDate: date, relativeOffset: 0, location: nil, proximity: .none, emailAddress: nil)
        }
        let alarmAt = start.addingTimeInterval(-3600)

        XCTAssertTrue(UndoPostState.sameAlarmKeys([key(alarmAt.addingTimeInterval(0.6))], [key(alarmAt)]))
        XCTAssertFalse(UndoPostState.sameAlarmKeys([key(alarmAt)], [key(alarmAt.addingTimeInterval(60))]))
        XCTAssertFalse(UndoPostState.sameAlarmKeys([key(alarmAt), key(alarmAt)], [key(alarmAt)]), "still a multiset")
    }

    func testDueDateChangeIsNamed() {
        let reminder = makeReminder()
        let saved = ReminderSnapshot(from: reminder)
        reminder.dueDateComponents = components(hour: 11)

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: saved), ["due_date"])
    }

    /// verify #9: an update-undo of a reminder completed by hand and then unchecked by hand.
    func testUpdateUndoDoesNotRefuseAFieldChangedBackByHand() {
        let reminder = makeReminder()
        let original = ReminderSnapshot(from: reminder)
        reminder.title = "Pay bills"                        // the update
        let saved = ReminderSnapshot(from: reminder)

        reminder.title = "Pay rent"                         // changed back by hand
        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: original), [])
    }

    func testCompletionInstantChangeIsNamed() {
        let reminder = makeReminder()
        reminder.isCompleted = true
        reminder.completionDate = start
        let saved = ReminderSnapshot(from: reminder)
        reminder.completionDate = start.addingTimeInterval(60)

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: saved), ["completion_date"])
    }

    /// Completion instants come from `now` and carry sub-second digits a synced store may drop.
    func testSubSecondCompletionDriftIsNotAChange() {
        let reminder = makeReminder()
        reminder.isCompleted = true
        reminder.completionDate = start.addingTimeInterval(0.789)
        let saved = ReminderSnapshot(from: reminder)
        reminder.completionDate = start

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder), restoring: saved), [])
    }

    /// EventKit can attach derived week / weekday fields after a save without changing the date,
    /// and a store can write the same wall-clock time with another time-zone representation
    /// (verify #7): both compare by the moment (or the day, for a date-only value).
    func testDateComponentsCompareByTheMomentTheyName() {
        var derived = components(hour: 9)
        derived.weekday = 7
        derived.weekOfYear = 41
        var offsetZone = components(hour: 9)
        offsetZone.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        var otherZone = components(hour: 9)
        otherZone.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let dateOnly = DateComponents(year: 2026, month: 10, day: 10)

        XCTAssertTrue(ReminderSnapshot.sameDateComponents(components(hour: 9), derived))
        XCTAssertTrue(ReminderSnapshot.sameDateComponents(components(hour: 9), offsetZone))
        XCTAssertFalse(ReminderSnapshot.sameDateComponents(components(hour: 9), otherZone), "another moment")
        XCTAssertFalse(ReminderSnapshot.sameDateComponents(components(hour: 9), components(hour: 10)))
        XCTAssertFalse(ReminderSnapshot.sameDateComponents(components(hour: 9), dateOnly))
        XCTAssertTrue(ReminderSnapshot.sameDateComponents(dateOnly, DateComponents(timeZone: taipei, year: 2026, month: 10, day: 10)))
        XCTAssertFalse(ReminderSnapshot.sameDateComponents(components(hour: 9), nil))
        XCTAssertTrue(ReminderSnapshot.sameDateComponents(nil, nil))
    }

    func testRestoringAReminderSnapshotRoundTrips() {
        let reminder = makeReminder()
        let snapshot = ReminderSnapshot(from: reminder)
        reminder.title = "Pay bills"
        reminder.notes = nil
        reminder.priority = 9
        reminder.startDateComponents = components(hour: 12)
        reminder.dueDateComponents = components(hour: 12)
        reminder.url = nil
        reminder.addAlarm(EKAlarm(relativeOffset: -60))

        snapshot.apply(to: reminder, now: start)

        XCTAssertEqual(snapshot.changedFields(in: ReminderSnapshot(from: reminder), restoring: snapshot), [])
    }

    func testTwoConsecutiveReminderUpdatesUndoneInOrderBothPass() {
        let reminder = makeReminder()
        let original = ReminderSnapshot(from: reminder)
        reminder.title = "Pay bills"                        // update 1
        let afterFirst = ReminderSnapshot(from: reminder)
        reminder.priority = 9                               // update 2
        let afterSecond = ReminderSnapshot(from: reminder)

        XCTAssertEqual(afterSecond.changedFields(in: ReminderSnapshot(from: reminder), restoring: afterFirst), [])
        afterFirst.apply(to: reminder, now: start)          // undo 2
        XCTAssertEqual(afterFirst.changedFields(in: ReminderSnapshot(from: reminder), restoring: original), [])
        original.apply(to: reminder, now: start)            // undo 1
        XCTAssertEqual(reminder.title, "Pay rent")
    }
}
