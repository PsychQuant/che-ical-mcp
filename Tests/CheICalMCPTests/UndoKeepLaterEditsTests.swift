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
        XCTAssertEqual(whole.restored, ["start_time", "end_time", "all_day", "timezone"])
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
