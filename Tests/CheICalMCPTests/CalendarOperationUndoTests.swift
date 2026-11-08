import XCTest
@testable import CheICalMCP

/// #273: `create_calendar`, `update_calendar` and `delete_calendar` record a marker
/// (`UndoOperation.calendarOperation`) whose undo is refused, writes nothing and discards the
/// record, so the next undo reaches the operation recorded before it and does not revert it in the
/// calendar operation's place. Pure: no store.
final class CalendarOperationUndoTests: XCTestCase {
    private let kinds: [CalendarOperationKind] = [.created, .updated, .deleted]

    func testTheMarkersAreListedAsNotUndoable() {
        XCTAssertEqual(UndoOperation.calendarOperation(kind: .created, title: "Work").description,
                       "Created calendar: Work (undo not available)")
        XCTAssertEqual(UndoOperation.calendarOperation(kind: .updated, title: "Work").description,
                       "Updated calendar: Work (undo not available)")
        XCTAssertEqual(UndoOperation.calendarOperation(kind: .deleted, title: "Work").description,
                       "Deleted calendar: Work (undo not available)")
    }

    /// The listing shows the title as the other listings do (`undoVisibleTitle`): hidden characters
    /// dropped, quotes kept.
    func testTheListingShowsTheTitleLikeTheOtherListings() {
        let op = UndoOperation.calendarOperation(kind: .deleted, title: "Wo\u{202E}rk\u{200B} 'x'")
        XCTAssertEqual(op.description, "Deleted calendar: Work 'x' (undo not available)")
    }

    /// Refused permanently (the record is discarded). The message says nothing was written, that
    /// the entry was discarded, and that the next undo reverts the operation recorded before it, so
    /// an agent does not run undo again to reach the calendar. It names the tool that does the
    /// reverse by hand, and never the calendar: a trusted error does not carry a calendar title,
    /// which a shared or subscribed calendar's owner sets (#37).
    func testUndoIsRefusedPermanentlyAndDoesNotNameTheCalendar() throws {
        let expected: [CalendarOperationKind: (prefix: String, tool: String)] = [
            .created: ("Cannot undo the creation of a calendar", "delete_calendar"),
            .updated: ("Cannot undo the update of a calendar", "update_calendar"),
            .deleted: ("Cannot undo the deletion of a calendar", "create_calendar"),
        ]
        for kind in kinds {
            let error = UndoOperation.calendarOperationRefusal(kind: kind)
            XCTAssertEqual(UndoFailureDisposition.of(error), .discard, "\(kind): discarded so earlier operations stay undoable")
            let message = EventKitErrorSanitizer.sanitizeForResponse(error).code
            let want = try XCTUnwrap(expected[kind])
            XCTAssertTrue(message.hasPrefix(want.prefix), "\(kind): \(message)")
            XCTAssertTrue(message.contains(want.tool), "\(kind): \(message)")
            XCTAssertTrue(message.contains("Nothing was written"), message)
            XCTAssertTrue(message.contains("This history entry was discarded"), message)
            XCTAssertTrue(message.contains("the next undo reverts the operation recorded before it"), message)
            XCTAssertTrue(message.contains("not this calendar operation"), message)
            XCTAssertFalse(message.contains("discard_id"), "the entry is already discarded: \(message)")
        }
        let deleted = EventKitErrorSanitizer.sanitizeForResponse(UndoOperation.calendarOperationRefusal(kind: .deleted)).code
        XCTAssertTrue(deleted.contains("events or reminders it held"), "a recreated calendar is empty: \(deleted)")
    }

    /// The executeUndo arm builds its refusal from the record's kind only, so the title cannot
    /// reach the error.
    func testTheRefusalDoesNotDependOnTheTitle() {
        for kind in kinds {
            let message = UndoOperation.calendarOperationRefusal(kind: kind).message
            XCTAssertFalse(message.contains("Work"), message)
        }
    }

    /// A marker: nothing to compare or restore, no batch records it, and its redo writes nothing.
    func testTheMarkerHasNothingToCompareRestoreOrRedo() throws {
        for kind in kinds {
            let op = UndoOperation.calendarOperation(kind: kind, title: "Standup")
            XCTAssertNil(op.undoPostState, "\(kind)")
            XCTAssertNil(op.redoPostState, "\(kind)")
            XCTAssertNil(op.batchMemberUndoRefusal, "\(kind): not batched")
            XCTAssertNil(op.restoredItemTitle, "\(kind)")
            XCTAssertFalse(op.mayRunLastAfterAFailure, "\(kind): no batch records it")
            XCTAssertFalse(op.redoWrites, "\(kind)")
            let redo = try XCTUnwrap(op.redoInstruction)
            XCTAssertTrue(redo.contains("'Standup'"), redo)
            XCTAssertTrue(redo.contains("was not undone, so there is nothing to redo"), redo)
            XCTAssertTrue(redo.contains("Nothing was written"), redo)
        }
    }
}
