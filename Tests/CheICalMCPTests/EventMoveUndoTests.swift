import XCTest
@testable import CheICalMCP

/// #226: an in-place move is undone by moving the event back to its original calendar,
/// not by delete + recreate (which is what the copy path records, #208).
final class EventMoveUndoTests: XCTestCase {
    func testMoveRecordDescribesTheMoveAndSanitizesTheTitle() {
        let op = UndoOperation.moveEvent(id: "new-id", fromCalendarIdentifier: "cal-A", title: "Standup\u{1B}[31m", isSeries: false)
        XCTAssertTrue(op.description.hasPrefix("Moved event: "))
        XCTAssertFalse(op.description.contains("\u{1B}"), "titles reach undo_history verbatim; they must be sanitized")
    }

    func testMoveRecordIsNotACompletionRecord() {
        let op = UndoOperation.moveEvent(id: "new-id", fromCalendarIdentifier: "cal-A", title: "Standup", isSeries: true)
        XCTAssertNil(op.completionWrite(undo: true, now: Date()))
        XCTAssertNil(op.completionWrite(undo: false, now: Date()))
    }
}
