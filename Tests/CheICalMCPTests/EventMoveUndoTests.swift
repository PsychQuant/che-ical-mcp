import EventKit
import XCTest
@testable import CheICalMCP

/// #226: an in-place move is undone by moving the event back to its original calendar,
/// not by delete + recreate (which is what the copy path records, #208).
final class EventMoveUndoTests: XCTestCase {
    func testMoveRecordDescribesTheMoveAndSanitizesTheTitle() {
        let op = UndoOperation.moveEvent(id: "new-id", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B", title: "Standup\u{1B}[31m", isSeries: false)
        XCTAssertTrue(op.description.hasPrefix("Moved event: "))
        XCTAssertFalse(op.description.contains("\u{1B}"), "titles reach undo_history verbatim; they must be sanitized")
    }

    func testMoveRecordIsNotACompletionRecord() {
        let op = UndoOperation.moveEvent(id: "new-id", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B", title: "Standup", isSeries: true)
        XCTAssertNil(op.completionWrite(undo: true, now: Date()))
        XCTAssertNil(op.completionWrite(undo: false, now: Date()))
    }
}

/// #369: the undo of a whole-series move resolves its target through the stand-in, as the move
/// did (#326); every other record keeps the plain lookup.
final class EventMoveUndoStandInTests: XCTestCase {
    func testAWholeSeriesMoveResolvesThroughTheStandIn() {
        let op = UndoOperation.moveEvent(id: "S", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B", title: "Standup", isSeries: true)
        XCTAssertTrue(op.resolvesThroughStandIn)
    }

    /// A one-off move must not reach a series' occurrence; a create-undo compares a snapshot of
    /// the series object, which a middle occurrence never matches; the other records do not
    /// write to an existing event or are refused before any lookup.
    func testNoOtherRecordResolvesThroughTheStandIn() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = "Standup"
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        let snapshot = EventSnapshot(from: event)
        let others: [UndoOperation] = [
            .moveEvent(id: "E", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B", title: "Standup", isSeries: false),
            .createEvent(id: "S", title: "Standup", created: snapshot),
            .updateEvent(id: "E", oldSnapshot: snapshot, saved: snapshot),
            .deleteFollowingOccurrences(title: "Standup"),
            .batch([.moveEvent(id: "S", fromCalendarIdentifier: "cal-A", toCalendarIdentifier: "cal-B", title: "Standup", isSeries: true)]),
        ]
        for op in others {
            XCTAssertFalse(op.resolvesThroughStandIn, op.description)
        }
    }

    /// The composition the `.event` lookup uses for a series move: the stale series object fails
    /// to refresh, the stand-in is returned, and the second refresh in `UndoTargetCheck` passes
    /// it on to the comparison, which sees the calendar the move left.
    func testTheCheckReachesTheStandInWhenTheSeriesObjectDoesNotRefresh() throws {
        let expected = UndoPostState.eventCalendar(id: "S", title: "Standup", calendarIdentifier: "cal-B",
                                                   restoringCalendarIdentifier: "cal-A")
        var compared: [String] = []
        let checked = try UndoTargetCheck.check(
            expected, verb: .undo,
            lookup: { FirstRemainingOccurrence.resolve(stored: "series", refresh: { $0 != "series" },
                                                       standIn: { _ in "occurrence" })?.event },
            refresh: { $0 != "series" },
            conflicts: { compared.append($0); return [] })
        XCTAssertEqual(checked, "occurrence")
        XCTAssertEqual(compared, ["occurrence"])
    }

    /// The residual case (#369): the series object is still stored but no occurrence can stand
    /// in. Kept like every not-found (`undo-history-discard`), but the message does not claim the
    /// event was deleted or moved to another account.
    func testASeriesWithoutAStandInIsNotCalledDeletedOrMoved() {
        let error = UndoTargetMissingError(verb: .undo, kind: .event, title: "Standup", hasIdentifier: true,
                                           seriesWithoutStandIn: true)
        let message = error.message
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "not found keeps the record (spec)")
        XCTAssertTrue(message.hasPrefix("Cannot undo: the event 'Standup' is still stored under its recorded identifier"), message)
        XCTAssertFalse(message.contains("deleted or moved to another account"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
        XCTAssertTrue(message.contains("this history entry was kept"), message)
    }
}
