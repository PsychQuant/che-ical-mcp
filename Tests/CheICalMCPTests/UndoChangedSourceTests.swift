import XCTest
@testable import CheICalMCP

/// #540: the revertable changed-after refusal does not know who changed the item, so it names
/// every source it cannot tell apart, this server's own later operations without an entry among
/// them, and no longer says that whoever made the change decides.
final class UndoChangedSourceTests: XCTestCase {
    private func text(_ verb: UndoHistoryVerb, _ kind: UndoPostState.Kind) throws -> String {
        try XCTUnwrap(UndoTargetChangedError(verb: verb, kind: kind, title: "t", changedFields: ["title"]).errorDescription)
    }

    func testTheUndoTextNamesThisServersLaterOperationsWithoutAnEntry() throws {
        for kind in [UndoPostState.Kind.event, .reminder] {
            let message = try text(.undo, kind)
            XCTAssertTrue(message.hasPrefix("Cannot undo: the \(kind.rawValue) 't' was changed after this operation, in another app, by the calendar server, "), message)
            XCTAssertTrue(message.contains("by a later operation of this server that has no entry in the undo history now (for example one whose entry was given up with discard_id)"), message)
            XCTAssertTrue(message.contains("(title). Undoing now would overwrite or delete that change"), message)
        }
    }

    func testTheRedoTextNamesThisServersLaterOperationsOrUndosWithoutAnEntry() throws {
        for kind in [UndoPostState.Kind.event, .reminder] {
            let message = try text(.redo, kind)
            XCTAssertTrue(message.hasPrefix("Cannot redo: the \(kind.rawValue) 't' was changed after the undo, in another app, by the calendar server, "), message)
            XCTAssertTrue(message.contains("by a later operation or undo of this server that has no entry in the redo history now"), message)
            XCTAssertTrue(message.contains("(title). Redoing now would overwrite that change"), message)
        }
    }

    /// The #274 source stays for reminders only, after this server's own operations.
    func testOnlyRemindersAlsoNameTheFailedWrite() throws {
        let before: [UndoHistoryVerb: String] = [.undo: "given up with discard_id)", .redo: "in the redo history now"]
        for verb in [UndoHistoryVerb.undo, .redo] {
            let reminder = try text(verb, .reminder)
            XCTAssertTrue(reminder.contains("\(before[verb]!), or by a failed write of this server that landed later (title)"), reminder)
            let event = try text(verb, .event)
            XCTAssertFalse(event.contains("failed write"), event)
            XCTAssertTrue(event.contains("\(before[verb]!) (title)"), event)
        }
    }

    func testNoTextSaysWhoeverMadeTheChangeDecides() throws {
        for verb in [UndoHistoryVerb.undo, .redo] {
            for kind in [UndoPostState.Kind.event, .reminder] {
                let message = try text(verb, kind)
                XCTAssertFalse(message.contains("Whoever made the change"), message)
                XCTAssertTrue(message.contains("\(verb == .undo ? "this history entry" : "this redo entry") was kept; ask the user whether to change it back and run \(verb.rawValue) again"), message)
            }
        }
    }

    /// The #265 note still follows the undo text.
    func testTheUpdateNoteStillFollowsTheUndoText() throws {
        let message = try XCTUnwrap(UndoTargetChangedError(verb: .undo, kind: .event, title: "t", changedFields: ["title"],
                                                           updateNote: "NOTE.").errorDescription)
        XCTAssertTrue(message.hasSuffix("call undo with discard_id set to its id. NOTE."), message)
    }
}
