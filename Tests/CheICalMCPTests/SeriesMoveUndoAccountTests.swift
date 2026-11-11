import XCTest
@testable import CheICalMCP

/// #511: the undo of a whole-series move back to a calendar of another account is a create plus a
/// delete, as the forward move is (#503, PR #505 round 4), so it is refused unless the deleted-occurrence
/// check finds none, before anything is written, and the record is kept.
final class SeriesMoveUndoAccountTests: XCTestCase {
    private func refusal(isSeries: Bool = true, verb: UndoHistoryVerb = .undo, across: Bool = true,
                         verdict: DeletedOccurrenceCheck.Verdict, read: inout Bool) -> String? {
        var wasRead = false
        let result = SeriesMoveUndo.deletedOccurrenceRefusal(isSeries: isSeries, verb: verb, acrossAccounts: across, title: "Weekly",
                                                             verdict: { wasRead = true; return verdict })
        read = wasRead
        return result
    }

    func testAMoveBackAcrossAccountsIsRefusedUnlessNoneWasDeleted() {
        var read = false
        XCTAssertNil(refusal(verdict: .none, read: &read))
        XCTAssertTrue(read)
        let deleted = refusal(verdict: .deleted(blocked: nil), read: &read)
        XCTAssertNotNil(deleted)
        XCTAssertTrue(deleted!.contains("deleted on its own"), deleted!)
        let unknown = refusal(verdict: .unknown(.notCovered), read: &read)
        XCTAssertNotNil(unknown)
        XCTAssertTrue(unknown!.contains(DeletedOccurrenceCheck.unknownCause(.notCovered)), unknown!)
    }

    /// Within one account the move back was measured to keep them (the forward move's text), a one-off
    /// has no deletions, and a redo of a move does not write: the listing is not read for those.
    func testOnlyTheUndoOfAWholeSeriesMoveAcrossAccountsIsChecked() {
        var read = true
        XCTAssertNil(refusal(across: false, verdict: .deleted(blocked: nil), read: &read))
        XCTAssertFalse(read)
        XCTAssertNil(refusal(isSeries: false, verdict: .deleted(blocked: nil), read: &read))
        XCTAssertFalse(read)
        XCTAssertNil(refusal(verb: .redo, verdict: .deleted(blocked: nil), read: &read))
        XCTAssertFalse(read)
    }

    /// The text says why (unmeasured create plus delete, #503), that nothing was written and the entry
    /// was kept, and gives #269's way on: Calendar, then discard_id after asking the user.
    func testTheRefusalKeepsTheEntryAndGivesTheWayOn() {
        let text = DeletedOccurrenceCheck.undoAccountMoveReason(.deleted(blocked: nil), title: "Weekly 'sync'")
        // PR #516 round 1: the event is named (through undoShownTitle, quotes replaced), and the Calendar
        // route says it may bring the deleted occurrences back.
        XCTAssertTrue(text.contains("'Weekly \u{2019}sync\u{2019}'"), text)
        XCTAssertTrue(text.contains("may also bring back the occurrences deleted on their own, so check them afterwards"), text)
        XCTAssertTrue(text.contains("(or one whose account could not be read)"), text)
        for part in ["Cannot undo the move", "another account", "create plus a delete", "#503", "Nothing was written",
                     "this history entry was kept", "Calendar",
                     "ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertFalse(text.contains("Moving it with update_event"), "the forward route is not offered for an undo")
    }

    /// PR #516 round 1: a move made through an occurrence's own id (#426) records that id, whose object has
    /// no rules of its own, so the verdict lists the series behind it, as the forward move does; a detached
    /// object without a `/RID=` part has no series identifier and gives nil (refused as not listed).
    func testAnOccurrenceIdIsCheckedThroughItsSeries() throws {
        var asked: [String] = []
        let seriesOf: (String) -> String? = { asked.append($0); return "series-object" }
        let plain = SeriesMoveUndo.verdictTarget(id: "ABC", isDetached: false, resolved: "resolved", seriesOf: seriesOf)
        XCTAssertEqual(plain?.series, "resolved")
        XCTAssertEqual(plain?.id, "ABC")
        XCTAssertTrue(asked.isEmpty)
        let own = SeriesMoveUndo.verdictTarget(id: "ABC/RID=804211200", isDetached: true, resolved: "resolved", seriesOf: seriesOf)
        XCTAssertEqual(own?.series, "series-object")
        XCTAssertEqual(own?.id, "ABC")
        XCTAssertEqual(asked, ["ABC/RID=804211200"])
        XCTAssertNil(SeriesMoveUndo.verdictTarget(id: "ABC", isDetached: true, resolved: "resolved", seriesOf: seriesOf))
        XCTAssertNil(SeriesMoveUndo.verdictTarget(id: "ABC/RID=1", isDetached: false, resolved: "resolved", seriesOf: { _ in nil }))
    }
}
