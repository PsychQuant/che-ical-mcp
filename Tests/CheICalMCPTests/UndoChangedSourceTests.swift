import XCTest
@testable import CheICalMCP

/// #540: the revertable changed-after refusal does not know who changed the item. The undo text
/// names every source it cannot tell apart, this server's own later operations without an entry
/// among them, and says what a change made back through this server needs before undo runs again;
/// the redo text names no source and sends the change-back outside this server. Neither says that
/// whoever made the change decides. Whole texts are compared (verify round 1, E10).
final class UndoChangedSourceTests: XCTestCase {
    private func text(_ verb: UndoHistoryVerb, _ kind: UndoPostState.Kind, note: String? = nil) throws -> String {
        try XCTUnwrap(UndoTargetChangedError(verb: verb, kind: kind, title: "t", changedFields: ["title"], updateNote: note).errorDescription)
    }

    private static let ownLater = "by a later operation of this server that has no entry in the undo history now (for example one whose entry was given up with discard_id)"
    private static let undoTail = "Undoing now would overwrite or delete that change, so nothing was written and this history entry was kept; ask the user whether to change it back and run undo again, or to give up this undo; if they agree to give it up, read undo_history and call undo with discard_id set to its id. A change made back through this server is recorded as an entry of its own above this one, and the next undo takes that entry first: give it up with discard_id, then run undo again; a change made back in another app records nothing here."

    func testTheEventUndoTextIsWhole() throws {
        XCTAssertEqual(try text(.undo, .event),
                       "Cannot undo: the event 't' was changed after this operation (title), in another app, by the calendar server, or \(Self.ownLater). " + Self.undoTail)
    }

    /// The #274 source stays for reminders, after this server's own operations.
    func testTheReminderUndoTextIsWhole() throws {
        XCTAssertEqual(try text(.undo, .reminder),
                       "Cannot undo: the reminder 't' was changed after this operation (title), in another app, by the calendar server, \(Self.ownLater), or by a failed write of this server that landed later. " + Self.undoTail)
    }

    /// The redo text names no source, and does not offer a change-back through this server: any
    /// recorded change clears the redo history (verify round 1, E9).
    func testTheRedoTextIsWhole() throws {
        for kind in [UndoPostState.Kind.event, .reminder] {
            XCTAssertEqual(try text(.redo, kind),
                           "Cannot redo: the \(kind.rawValue) 't' was changed after the undo (title). Redoing now would overwrite that change, so nothing was written and this redo entry was kept; ask the user whether to change it back in another app and run redo again. A change recorded through this server, complete_reminder included, clears the redo history and this entry with it; to set the completion through this server, call complete_reminder instead of redo.")
        }
    }

    func testNoTextSaysWhoeverMadeTheChangeDecides() throws {
        for verb in [UndoHistoryVerb.undo, .redo] {
            for kind in [UndoPostState.Kind.event, .reminder] {
                let message = try text(verb, kind)
                XCTAssertNil(message.range(of: "whoever", options: .caseInsensitive), message)
            }
        }
    }

    /// The #265 note still follows the undo text.
    func testTheUpdateNoteStillFollowsTheUndoText() throws {
        XCTAssertTrue(try text(.undo, .event, note: "NOTE.").hasSuffix(Self.undoTail + " NOTE."))
    }
}
