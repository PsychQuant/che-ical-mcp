import XCTest
@testable import CheICalMCP

/// #540: the revertable changed-after refusal does not know who changed the item. The undo text
/// names every source it cannot tell apart, this server's own later operations without an entry
/// among them; the redo text names none; neither says that whoever made the change decides.
final class UndoChangedSourceTests: XCTestCase {
    private func text(_ verb: UndoHistoryVerb, _ kind: UndoPostState.Kind) throws -> String {
        try XCTUnwrap(UndoTargetChangedError(verb: verb, kind: kind, title: "t", changedFields: ["title"]).errorDescription)
    }

    private let ownLater = "by a later operation of this server that has no entry in the undo history now (for example one whose entry was given up with discard_id)"

    func testTheEventUndoTextNamesThisServersLaterOperationsWithoutAnEntry() throws {
        let message = try text(.undo, .event)
        XCTAssertTrue(message.hasPrefix("Cannot undo: the event 't' was changed after this operation (title), in another app, by the calendar server, or \(ownLater). Undoing now would overwrite or delete that change"), message)
    }

    /// The #274 source stays for reminders, after this server's own operations.
    func testTheReminderUndoTextAlsoNamesTheFailedWrite() throws {
        let message = try text(.undo, .reminder)
        XCTAssertTrue(message.hasPrefix("Cannot undo: the reminder 't' was changed after this operation (title), in another app, by the calendar server, \(ownLater), or by a failed write of this server that landed later. Undoing now would overwrite or delete that change"), message)
    }

    func testTheRedoTextNamesNoSource() throws {
        for kind in [UndoPostState.Kind.event, .reminder] {
            let message = try text(.redo, kind)
            XCTAssertTrue(message.hasPrefix("Cannot redo: the \(kind.rawValue) 't' was changed after the undo (title). Redoing now would overwrite that change"), message)
            for source in ["another app", "calendar server", "this server"] {
                XCTAssertFalse(message.contains(source), "\(source): \(message)")
            }
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
