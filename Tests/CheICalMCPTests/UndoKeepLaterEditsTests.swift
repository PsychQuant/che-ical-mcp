import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// #265: the opt-in merge of an update-undo (`keep_later_edits`). The plan, the masked restore on
/// in-memory items, and the refusal text the guard builds for an update record. No store access.
final class UndoKeepLaterEditsTests: XCTestCase {
    private var store: EKEventStore { SharedTestStore.store }

    // MARK: - Plan

    func testADisjointEditIsKeptAndTheUpdatesGroupRestored() throws {
        let plan = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["title"], changedElsewhere: ["location"],
                                                         groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(plan.restored, ["title"])
        XCTAssertEqual(plan.kept, ["location"])
        XCTAssertEqual(plan.overlapping, [])
    }

    func testAnEditOfAFieldTheUpdateChangedOverlaps() throws {
        let plan = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["title", "notes"], changedElsewhere: ["title"],
                                                         groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(plan.overlapping, ["title"])
    }

    func testFieldsThatMoveTogetherOverlapAsOneGroup() throws {
        // The update moved the start (start and end); the later edit changed the time zone.
        let time = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["start_time", "end_time"], changedElsewhere: ["timezone"],
                                                         groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(time.overlapping, ["timezone"])
        let place = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["location"], changedElsewhere: ["structured_location"],
                                                          groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(place.overlapping, ["structured_location"])
        // A restored group is written whole, in table order.
        let whole = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["end_time"], changedElsewhere: ["notes"],
                                                          groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(whole.restored, ["start_time", "end_time", "all_day", "timezone", "alarms", "calendar", "availability"])
    }

    func testAReminderRepetitionMovesWithItsDueDate() throws {
        let plan = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["due_date"], changedElsewhere: ["recurrence"],
                                                         groups: UndoKeepLaterEdits.reminderGroups))
        XCTAssertEqual(plan.overlapping, ["recurrence"])
        let alarms = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["alarms"], changedElsewhere: ["start_date"],
                                                           groups: UndoKeepLaterEdits.reminderGroups))
        XCTAssertEqual(alarms.overlapping, ["start_date"])
    }

    func testACompletedReminderIsKeptWhenTheUpdateDidNotTouchCompletion() throws {
        let plan = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["title"], changedElsewhere: ["completed"],
                                                         groups: UndoKeepLaterEdits.reminderGroups))
        XCTAssertEqual(plan.restored, ["title"])
        XCTAssertEqual(plan.kept, ["completed"])
    }

    func testAFieldOutsideTheTableIsNeverMerged() {
        XCTAssertNil(UndoKeepLaterEdits.plan(changedByUpdate: ["title"], changedElsewhere: ["item_type"],
                                             groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertNil(UndoKeepLaterEdits.plan(changedByUpdate: ["recurrence"], changedElsewhere: ["notes"],
                                             groups: UndoKeepLaterEdits.eventGroups))
    }

    /// PR #504 round 1, M2: clear_recurrence, then a completion elsewhere: restoring the rule onto a
    /// completed reminder is a write update_reminder refuses, so completion moves with the dates.
    func testACompletionOverlapsTheRestoredRepetition() throws {
        let plan = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["recurrence"], changedElsewhere: ["completed"],
                                                         groups: UndoKeepLaterEdits.reminderGroups))
        XCTAssertEqual(plan.overlapping, ["completed"])
        let date = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["due_date"], changedElsewhere: ["completion_date"],
                                                         groups: UndoKeepLaterEdits.reminderGroups))
        XCTAssertEqual(date.overlapping, ["completion_date"])
    }

    /// Round 1, LOW: a calendar decides which availability and alarms it takes; a list which dates
    /// and alarms its source supports.
    func testACalendarMovesWithItsAvailabilityAndAlarms() throws {
        for later in ["availability", "alarms"] {
            let plan = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["calendar"], changedElsewhere: [later],
                                                             groups: UndoKeepLaterEdits.eventGroups))
            XCTAssertEqual(plan.overlapping, [later])
        }
        let list = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["list"], changedElsewhere: ["alarms"],
                                                         groups: UndoKeepLaterEdits.reminderGroups))
        XCTAssertEqual(list.overlapping, ["alarms"])
    }

    /// PR #504 round 2 (HIGH, MEDIUM): an event's relative alarm means another time once the event
    /// turns all-day or timed, so the all-day flag and the alarms move together, both ways.
    func testTheAllDayFlagAndTheAlarmsOverlapBothWays() throws {
        let toggled = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["all_day", "start_time", "end_time"], changedElsewhere: ["alarms"],
                                                            groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(toggled.overlapping, ["alarms"])
        let alarmed = try XCTUnwrap(UndoKeepLaterEdits.plan(changedByUpdate: ["alarms"], changedElsewhere: ["all_day"],
                                                            groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertEqual(alarmed.overlapping, ["all_day"])
    }

    /// Round 2 (LOW 4): the success message names the item by the title it has after the merge.
    func testTheAnswerNamesTheItemByItsCurrentTitle() {
        let plan = UndoKeepLaterEdits.Plan(restored: ["notes"], kept: ["title"], overlapping: [])
        let text = UndoKeepLaterEdits.undoneMessage(kind: .event, title: "Later title", plan: plan)
        XCTAssertTrue(text.contains("'Later title'"), text)
        XCTAssertTrue(text.contains("kept the later edits to title"), text)
    }

    /// Round 1, M3: the guard's geocode exemption is not applied to what the update itself wrote.
    func testCoordinatesTheUpdateAddedCountAsChangedByIt() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = EKCalendar(for: .event, eventStore: store)
        let before = event(title: "A", location: "Room", notes: nil, start: start, calendar: calendar)
        before.structuredLocation = EKStructuredLocation(title: "Room")
        let after = event(title: "A", location: "Room", notes: nil, start: start, calendar: calendar)
        let place = EKStructuredLocation(title: "Room")
        place.geoLocation = CLLocation(latitude: 25.0, longitude: 121.5)
        after.structuredLocation = place
        let changed = UndoKeepLaterEdits.changedByUpdate(old: EventSnapshot(from: before), saved: EventSnapshot(from: after))
        XCTAssertEqual(changed, ["structured_location"])
    }

    /// Round 1, M3: an update that changed nothing undo restores is never offered the merge.
    func testNoOfferWhenTheUpdateChangedNothingUndoRestores() throws {
        let note = try XCTUnwrap(UndoKeepLaterEdits.refusalNote(changedByUpdate: [], changedElsewhere: ["title"],
                                                                groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertFalse(note.contains("keep_later_edits set to true"), note)
        XCTAssertTrue(note.contains("keep_later_edits does not apply"), note)
    }

    /// Round 1, LOW: after a masked undo the item does not hold every recorded value.
    func testTheRedoInstructionOfAnUpdateSaysOnlyWhatIsTrue() throws {
        let event = UndoOperation.updateEvent(id: "x", oldSnapshot: UndoSnapshotFixtures.event(title: "A"),
                                              saved: UndoSnapshotFixtures.event(title: "B"))
        let reminder = UndoOperation.updateReminder(id: "x", oldSnapshot: UndoSnapshotFixtures.reminder(title: "A"),
                                                    saved: UndoSnapshotFixtures.reminder(title: "B"))
        for text in [try XCTUnwrap(event.redoInstruction), try XCTUnwrap(reminder.redoInstruction)] {
            XCTAssertFalse(text.contains("restored to its previous state"), text)
            XCTAssertTrue(text.contains("as the undo left it"), text)
        }
    }

    // MARK: - Masked restore

    private func event(title: String, location: String?, notes: String?, start: Date, calendar: EKCalendar? = nil) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar ?? EKCalendar(for: .event, eventStore: store)
        event.title = title
        event.location = location
        event.notes = notes
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.timeZone = TimeZone(identifier: "Asia/Taipei")
        return event
    }

    func testTheMaskedEventRestoreWritesOnlyTheGivenFields() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = EventSnapshot(from: event(title: "A", location: "L0", notes: "n0", start: start))
        let current = event(title: "B", location: "L1", notes: "n1", start: start.addingTimeInterval(7200))
        old.applyRestoring(["title"], to: current, calendar: current.calendar)
        XCTAssertEqual(current.title, "A")
        XCTAssertEqual(current.location, "L1", "a field outside the restored groups is kept")
        XCTAssertEqual(current.notes, "n1")
        XCTAssertEqual(current.startDate, start.addingTimeInterval(7200))

        old.applyRestoring(["start_time", "end_time", "all_day", "timezone"], to: current, calendar: current.calendar)
        XCTAssertEqual(current.startDate, start)
        XCTAssertEqual(current.endDate, start.addingTimeInterval(3600))
        XCTAssertEqual(current.location, "L1")

        old.applyRestoring(["location", "structured_location"], to: current, calendar: current.calendar)
        XCTAssertEqual(current.location, "L0")
        XCTAssertEqual(current.notes, "n1")
    }

    /// Round 1, LOW (Codex): an event that had no place before; restoring the place group clears
    /// the one the update added and keeps a later edit to notes. In memory; the store side is the
    /// release gate.
    func testRestoringThePlaceOfAnEventThatHadNoneClearsIt() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = EventSnapshot(from: event(title: "A", location: nil, notes: "n0", start: start))
        let current = event(title: "A", location: "Room", notes: "n1", start: start)
        current.structuredLocation = EKStructuredLocation(title: "Room")
        old.applyRestoring(["location", "structured_location"], to: current, calendar: current.calendar)
        XCTAssertNil(current.location)
        XCTAssertNil(current.structuredLocation, "the place goes with the location")
        XCTAssertEqual(current.notes, "n1")
    }

    func testTheMaskedReminderRestoreWritesOnlyTheGivenFields() {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        reminder.title = "A"
        reminder.priority = 1
        reminder.notes = "n0"
        let old = ReminderSnapshot(from: reminder)
        reminder.title = "B"
        reminder.priority = 9
        reminder.notes = "n1"
        old.applyRestoring(["title"], to: reminder, list: nil, now: Date())
        XCTAssertEqual(reminder.title, "A")
        XCTAssertEqual(reminder.priority, 9, "a field outside the restored groups is kept")
        XCTAssertEqual(reminder.notes, "n1")
    }

    // MARK: - Refusal text (A) and the offer (C)

    func testTheRefusalNamesBothSidesAndOffersKeepLaterEditsWhenNothingOverlaps() throws {
        let note = try XCTUnwrap(UndoKeepLaterEdits.refusalNote(changedByUpdate: ["title"], changedElsewhere: ["location"],
                                                                groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertTrue(note.contains("The update changed: title."), note)
        XCTAssertTrue(note.contains("Changed after it: location."), note)
        XCTAssertTrue(note.contains("keep_later_edits set to true"), note)
        XCTAssertTrue(note.contains("ask the user"), note)
    }

    func testTheRefusalDoesNotOfferKeepLaterEditsWhenAGroupOverlaps() throws {
        let note = try XCTUnwrap(UndoKeepLaterEdits.refusalNote(changedByUpdate: ["start_time", "end_time"], changedElsewhere: ["timezone"],
                                                                groups: UndoKeepLaterEdits.eventGroups))
        XCTAssertTrue(note.contains("The update changed: start_time, end_time."), note)
        XCTAssertFalse(note.contains("keep_later_edits set to true"), note)
        XCTAssertTrue(note.contains("timezone"), note)
    }

    /// Through the production builder: an update record refused for a later edit carries the note.
    func testThePostStateRefusalOfAnUpdateCarriesTheNote() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = EKCalendar(for: .event, eventStore: store)
        let old = EventSnapshot(from: event(title: "A", location: "L0", notes: nil, start: start, calendar: calendar))
        let saved = EventSnapshot(from: event(title: "B", location: "L0", notes: nil, start: start, calendar: calendar))
        let current = event(title: "B", location: "L1", notes: nil, start: start, calendar: calendar)
        let operation = UndoOperation.updateEvent(id: "x", oldSnapshot: old, saved: saved)
        let error = operation.postStateRefusal(verb: .undo, changedFields: ["location"], current: current)
        let message = try XCTUnwrap(error as? UndoTargetChangedError).message
        XCTAssertTrue(message.contains("(location)"), message)
        XCTAssertTrue(message.contains("The update changed: title. Changed after it: location."), message)
        XCTAssertTrue(message.contains("keep_later_edits set to true"), message)
    }

    /// The create-undo refusal is unchanged: no note.
    func testACreateUndoRefusalCarriesNoNote() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let created = EventSnapshot(from: event(title: "A", location: nil, notes: nil, start: start))
        let current = event(title: "B", location: nil, notes: nil, start: start)
        let error = UndoOperation.createEvent(id: "x", title: "A", created: created)
            .postStateRefusal(verb: .undo, changedFields: ["title"], current: current)
        let message = try XCTUnwrap(error as? UndoTargetChangedError).message
        XCTAssertFalse(message.contains("keep_later_edits"), message)
        XCTAssertFalse(message.contains("The update changed"), message)
    }
}
