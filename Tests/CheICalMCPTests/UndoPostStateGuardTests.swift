import CheMCPKit
import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #236: before an undo or redo writes, it compares the item with the state the recorded write
/// left and refuses when they differ, instead of overwriting a later change. The comparison
/// covers the fields the undo writes (diagnosis D1). Every EventKit object here is in memory
/// (never fetched or saved), so no TCC prompt.
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

    // MARK: - Events

    func testUnchangedEventHasNoChangedFields() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), [])
    }

    func testEachChangedEventFieldIsNamed() {
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
            (["recurrence"], { $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)] }),
        ]
        for (fields, edit) in edits {
            let event = makeEvent()
            let saved = EventSnapshot(from: event)
            edit(event)
            XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), fields, fields[0])
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

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
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

    /// A place added by a later update is cleared by restoring a snapshot without a location.
    func testPlaceAddedToAnEventWithoutLocationIsClearedByTheRestore() {
        let event = makeEvent()
        event.location = nil
        let snapshot = EventSnapshot(from: event)
        event.structuredLocation = office()

        snapshot.apply(to: event, calendar: calendarA)

        XCTAssertEqual(snapshot.changedFields(in: EventSnapshot(from: event), restoring: snapshot), [])
    }

    /// `applySnapshot` leaves the rules alone when the restored snapshot recorded none
    /// (`includeRecurrence: false`), so update-undo does not compare them then.
    func testUpdateUndoComparesRecurrenceOnlyWhenTheRestoredSnapshotRecordedRules() {
        let restored = EventSnapshot(from: makeEvent(), includeRecurrence: false)
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: restored), [])
        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: saved), ["recurrence"])
    }

    /// Create-undo deletes the event, so every recorded field counts.
    func testDeleteScopeComparesStructuredLocationAndRecurrence() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event)
        event.structuredLocation = office(latitude: 24.0)
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), ["structured_location", "recurrence"])
    }

    /// A state recorded without rules cannot vouch for them.
    func testRulesThatWereNotRecordedAreNotCompared() {
        let event = makeEvent()
        let saved = EventSnapshot(from: event, includeRecurrence: false)
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]

        XCTAssertEqual(saved.changedFields(in: EventSnapshot(from: event), restoring: nil), [])
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

    // MARK: - Reminders

    func testUnchangedReminderHasNoChangedFields() {
        let reminder = makeReminder()
        let saved = ReminderSnapshot(from: reminder)

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder)), [])
    }

    func testEachChangedReminderFieldIsNamed() {
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
            XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder)), [field], field)
        }
    }

    func testDueDateChangeIsNamed() {
        let reminder = makeReminder()
        let saved = ReminderSnapshot(from: reminder)
        reminder.dueDateComponents = components(hour: 11)

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder)), ["due_date"])
    }

    func testCompletionInstantChangeIsNamed() {
        let reminder = makeReminder()
        reminder.isCompleted = true
        reminder.completionDate = start
        let saved = ReminderSnapshot(from: reminder)
        reminder.completionDate = start.addingTimeInterval(60)

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder)), ["completion_date"])
    }

    /// Completion instants come from `now` and carry sub-second digits a synced store may drop.
    func testSubSecondCompletionDriftIsNotAChange() {
        let reminder = makeReminder()
        reminder.isCompleted = true
        reminder.completionDate = start.addingTimeInterval(0.789)
        let saved = ReminderSnapshot(from: reminder)
        reminder.completionDate = start

        XCTAssertEqual(saved.changedFields(in: ReminderSnapshot(from: reminder)), [])
    }

    /// EventKit can attach derived week / weekday fields after a save without changing the date.
    func testDerivedDateComponentFieldsAreNotAChange() {
        var derived = components(hour: 9)
        derived.weekday = 7
        derived.weekOfYear = 41

        XCTAssertTrue(ReminderSnapshot.sameDateComponents(components(hour: 9), derived))
        XCTAssertFalse(ReminderSnapshot.sameDateComponents(components(hour: 9), components(hour: 10)))
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

        XCTAssertEqual(snapshot.changedFields(in: ReminderSnapshot(from: reminder)), [])
    }

    func testTwoConsecutiveReminderUpdatesUndoneInOrderBothPass() {
        let reminder = makeReminder()
        let original = ReminderSnapshot(from: reminder)
        reminder.title = "Pay bills"                        // update 1
        let afterFirst = ReminderSnapshot(from: reminder)
        reminder.priority = 9                               // update 2
        let afterSecond = ReminderSnapshot(from: reminder)

        XCTAssertEqual(afterSecond.changedFields(in: ReminderSnapshot(from: reminder)), [])
        afterFirst.apply(to: reminder, now: start)          // undo 2
        XCTAssertEqual(afterFirst.changedFields(in: ReminderSnapshot(from: reminder)), [])
        original.apply(to: reminder, now: start)            // undo 1
        XCTAssertEqual(reminder.title, "Pay rent")
    }

    // MARK: - Completion and move checks

    func testCompletionCheckNamesTheFlagAndTheInstant() {
        let reminder = makeReminder()
        reminder.isCompleted = true
        reminder.completionDate = start
        let check = { (isCompleted: Bool, date: Date?) in
            UndoPostState.reminderCompletion(id: "r", title: "Pay rent", isCompleted: isCompleted, completionDate: date)
                .changedFields(in: reminder)
        }

        XCTAssertEqual(check(true, start), [])
        XCTAssertEqual(check(true, start.addingTimeInterval(0.5)), [])
        XCTAssertEqual(check(true, nil), [], "an unrecorded instant is not compared")
        XCTAssertEqual(check(true, start.addingTimeInterval(120)), ["completion_date"])
        XCTAssertEqual(check(false, nil), ["completed"])
    }

    func testMoveCheckComparesOnlyTheCalendar() {
        let event = makeEvent()
        event.title = "Edited after the move"
        let check = { (calendar: EKCalendar) in
            UndoPostState.eventCalendar(id: "e", title: "Review", calendarIdentifier: calendar.calendarIdentifier)
                .changedFields(in: event)
        }

        XCTAssertEqual(check(calendarA), [], "a move-undo writes only the calendar")
        XCTAssertEqual(check(calendarB), ["calendar"])
    }

    // MARK: - Refusal

    func testRefusalIsTrustedAndKeepsTheRecord() {
        let error = UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup", changedFields: ["title"])

        XCTAssertTrue((error as Error) is TrustedErrorMessage, "otherwise the message flattens to error_unknown")
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "the change can be reverted, so the refusal is not permanent (D2)")
    }

    func testUndoRefusalNamesTheFieldsAndTheEscapeHatch() {
        let error = UndoTargetChangedError(verb: .undo, kind: .event, title: "Standup\u{1B}[31m", changedFields: ["title", "start_time"])
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code

        XCTAssertTrue(message.hasPrefix("Cannot undo"), message)
        XCTAssertTrue(message.contains("event 'Standup"), message)
        XCTAssertFalse(message.contains("\u{1B}"), "titles are store-derived and must be sanitized")
        XCTAssertTrue(message.contains("title, start_time"), message)
        XCTAssertTrue(message.contains("undo_history"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
    }

    func testRedoRefusalSaysTheRedoEntryWasKept() {
        let error = UndoTargetChangedError(verb: .redo, kind: .reminder, title: "Pay rent", changedFields: ["completed"])
        let message = EventKitErrorSanitizer.sanitizeForResponse(error).code

        XCTAssertTrue(message.hasPrefix("Cannot redo"), message)
        XCTAssertTrue(message.contains("reminder 'Pay rent'"), message)
        XCTAssertTrue(message.contains("redo"), message)
        XCTAssertFalse(message.contains("discard_id"), "discard_id removes undo records only")
    }
}
