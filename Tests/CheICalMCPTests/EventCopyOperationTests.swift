import EventKit
import XCTest
@testable import CheICalMCP

final class EventCopyOperationTests: XCTestCase {
    enum Failure: Error { case save, remove }
    private func snapshot() -> EventSnapshot {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Source"
        event.startDate = Date(timeIntervalSince1970: 100)
        event.endDate = Date(timeIntervalSince1970: 200)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        return EventSnapshot(from: event, includeRecurrence: false)
    }
    func testRestoreUsesExactCalendarIdentityAndRejectsMissingSource() throws {
        let saved = snapshot()
        let calendars = [(id: "other-account", title: "Work"), (id: saved.calendarIdentifier, title: "Work")]
        let selected = try saved.resolveCalendar(in: calendars, identifier: { $0.id })
        XCTAssertEqual(selected.id, saved.calendarIdentifier)
        XCTAssertThrowsError(try saved.resolveCalendar(in: [calendars[0]], identifier: { $0.id }))
    }

    func testMoveReturnsSourceUndoOnlyAfterSuccessfulDeletion() throws {
        var calls: [String] = []
        let outcome = try EventCopyOperation.execute(source: snapshot(), saveCopy: { calls.append("save"); return "new" }, removeSource: { calls.append("remove") })
        XCTAssertEqual(calls, ["save", "remove"])
        XCTAssertEqual(outcome.value, "new")
        guard case .deleteEvent(let saved)? = outcome.undo else { return XCTFail("Missing deletion undo") }
        XCTAssertEqual(saved.title, "Source")
        XCTAssertNil(saved.recurrenceRules, "a single removed occurrence must not restore a duplicate series")
    }
    func testCopyDoesNotDeleteOrRecordSourceUndo() throws {
        let outcome = try EventCopyOperation.execute(source: nil, saveCopy: { "new" }, removeSource: { XCTFail("must not remove") })
        XCTAssertNil(outcome.undo)
    }
    func testFailedSaveDoesNotDeleteSource() {
        XCTAssertThrowsError(try EventCopyOperation.execute(source: snapshot(), saveCopy: { () throws -> String in throw Failure.save }, removeSource: { XCTFail("must not remove") }))
    }
    func testFailedDeletionDoesNotProduceUndoOutcome() {
        XCTAssertThrowsError(try EventCopyOperation.execute(source: snapshot(), saveCopy: { "new" }, removeSource: { throw Failure.remove }))
    }
}
