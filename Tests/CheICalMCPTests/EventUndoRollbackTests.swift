import XCTest

/// #274: the two event undo arms that write an existing event (update-undo, move-undo) discard what
/// a failed save left on the event before rethrowing, as `updateEvent` does since #379
/// (`UpdateEventRefusalOrderTests.testAFailedSaveRollsTheEventBack`). EventKit cannot be made to
/// fail a save in a unit test, so this is pinned over the source: each arm is read from its `case`
/// to the next `case` of `executeUndo`, with comments and strings blanked (`SourcePins`).
final class EventUndoRollbackTests: XCTestCase {
    private func executeUndoBody() throws -> String {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        return try XCTUnwrap(SourcePins.body(of: "func executeUndo(", in: source), "executeUndo is in EventKitManager.swift")
    }

    /// One arm of `executeUndo`: from `case .<name>(` to the next `case` label (or the end of the body).
    private func arm(_ name: String, in body: String) throws -> String {
        let start = try XCTUnwrap(body.range(of: "case .\(name)("), "executeUndo has an arm for .\(name)")
        let rest = String(body[start.upperBound...])
        let end = SourcePins.ranges(ofPattern: "\\n\\s*case \\.", in: rest).first?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    func testUpdateUndoRollsTheEventBackWhenItsSaveFails() throws {
        let arm = squeezed(try arm("updateEvent", in: try executeUndoBody()))
        XCTAssertTrue(arm.contains("do{tryeventStore.save(event,span:.thisEvent)}catch{event.rollback()throwerror}"),
                      "update-undo rolls the event back when its save fails")
        XCTAssertEqual(SourcePins.ranges(of: "eventStore.save(", in: arm).count, 1,
                       "update-undo has exactly one save, the one wrapped above")
    }

    func testMoveUndoRollsTheEventBackWhenItsSaveFails() throws {
        let arm = squeezed(try arm("moveEvent", in: try executeUndoBody()))
        XCTAssertTrue(arm.contains("do{tryeventStore.save(event,span:isSeries?.futureEvents:.thisEvent)}catch{event.rollback()throwerror}"),
                      "move-undo rolls the event back when its save fails")
        XCTAssertEqual(SourcePins.ranges(of: "eventStore.save(", in: arm).count, 1,
                       "move-undo has exactly one save, the one wrapped above")
    }

    /// The arm reader must see the arms it pins; otherwise an edit that reorders the switch would
    /// make the checks above read the wrong code.
    func testTheArmReaderSeesEachArmAndOnlyThatArm() throws {
        let body = try executeUndoBody()
        let update = try arm("updateEvent", in: body)
        XCTAssertTrue(update.contains("applySnapshot(oldSnapshot"), "the update-undo arm restores the old snapshot")
        XCTAssertFalse(update.contains("recurringUpdateRefusal"), "the update-undo arm stops before the next case")
        let move = try arm("moveEvent", in: body)
        XCTAssertTrue(move.contains("fromCalendarIdentifier"), "the move-undo arm moves the event back")
        XCTAssertFalse(move.contains("verifiedReminder("), "the move-undo arm stops before the reminder arms")
    }

    /// `executeRedo` writes no event (#247: only completions are written again). If a redo event arm
    /// ever saves an event, it needs the same rollback; this makes that edit visible.
    func testRedoWritesNoEvent() throws {
        let source = try SourcePins.source("EventKit/EventKitManager.swift")
        let redo = try XCTUnwrap(SourcePins.body(of: "func executeRedo(", in: source))
        XCTAssertTrue(SourcePins.ranges(ofPattern: "eventStore\\.save\\(\\s*event\\b", in: redo).isEmpty,
                      "executeRedo saves no event")
    }
}
