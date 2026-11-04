import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #377: the undo of `create_event` for a series whose first occurrence was deleted after the
/// create. The series object still resolves but no longer refreshes (#326, root cause #284), and a
/// later occurrence remains. The undo refuses with a message naming that shape, writes nothing,
/// and keeps the record (`undo-history-discard`). Pure seams, no EventKit (closure seam, like
/// `SeriesMoveUndo` and `UndoTargetCheck`).
final class SeriesCreateUndoTests: XCTestCase {
    private let createOp = UndoOperation.createEvent(id: "S", title: "Standup",
                                                     created: UndoSnapshotFixtures.event(title: "Standup"))

    private var expected: UndoPostState {
        get throws { try XCTUnwrap(createOp.undoPostState) }
    }

    // MARK: - UndoTargetCheck's not-found hook

    func testTheNotFoundHookIsNotAskedWhenTheTargetRefreshes() throws {
        var asked = false
        let item = try UndoTargetCheck.check(expected, verb: .undo, lookup: { "series" }, refresh: { _ in true },
                                             missing: { _ in asked = true; return nil },
                                             conflicts: { _ in [] })
        XCTAssertEqual(item, "series")
        XCTAssertFalse(asked, "a create-undo whose series refreshes pays nothing")
    }

    func testTheNotFoundHookGetsTheStoredItemThatDidNotRefresh() throws {
        struct Marker: Error {}
        var seen: [String?] = []
        var compared = false
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { "series" }, refresh: { _ in false },
                                                       missing: { seen.append($0); return Marker() },
                                                       conflicts: { _ in compared = true; return [] })) { error in
            XCTAssertTrue(error is Marker, "\(error)")
        }
        XCTAssertEqual(seen, ["series"])
        XCTAssertFalse(compared, "nothing is compared")
    }

    func testTheNotFoundHookGetsNilWhenNothingIsStored() throws {
        var seen: [String?] = ["unset"]
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { nil as String? },
                                                       refresh: { _ in true },
                                                       missing: { seen = [$0]; return nil },
                                                       conflicts: { _ in [] })) { error in
            XCTAssertTrue(error is UndoTargetMissingError, "\(error)")
        }
        XCTAssertEqual(seen, [nil])
    }

    func testANotFoundHookWithoutAnErrorKeepsThePlainNotFound() throws {
        XCTAssertThrowsError(try UndoTargetCheck.check(expected, verb: .undo, lookup: { "series" }, refresh: { _ in false },
                                                       missing: { _ in nil }, conflicts: { _ in [] })) { error in
            guard let missing = error as? UndoTargetMissingError else { return XCTFail("\(error)") }
            XCTAssertTrue(missing.message.contains("was not found under its recorded identifier"), missing.message)
        }
    }

    // MARK: - SeriesCreateUndo.missingError

    /// `standIn` says where the stand-in starts relative to the record's own start (`created.startDate`):
    /// true later, false not later, nil no stand-in.
    private func decide(_ operation: UndoOperation? = nil, verb: UndoHistoryVerb = .undo, stored: Bool = true,
                        recurring: Bool = true, standIn: () -> Bool?) -> Error? {
        let op = operation ?? createOp
        var recorded = Date.distantPast
        if case .createEvent(_, _, let created) = op { recorded = created.startDate }
        return SeriesCreateUndo.missingError(of: op, verb: verb, stored: stored, recurring: recurring,
                                             standInStart: { standIn().map { recorded.addingTimeInterval($0 ? 7 * 86_400 : 0) } })
    }

    func testOnlyACreateUndoProbesForAStandIn() {
        let move = UndoOperation.moveEvent(id: "S", fromCalendarIdentifier: "a", toCalendarIdentifier: "b",
                                           title: "Standup", isSeries: false, fromCalendarTitle: "Original", fromCalendarAccount: nil)
        let delete = UndoOperation.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Standup"))
        var asked = 0
        for (operation, verb) in [(createOp, UndoHistoryVerb.redo), (move, .undo), (delete, .undo), (delete, .redo)] {
            XCTAssertNil(decide(operation, verb: verb, standIn: { asked += 1; return true }), "\(operation) \(verb)")
        }
        XCTAssertEqual(asked, 0, "no scan for any other record")
    }

    func testNothingStoredIsThePlainNotFound() {
        var asked = false
        XCTAssertNil(decide(stored: false, standIn: { asked = true; return true }))
        XCTAssertFalse(asked, "a deleted series is not scanned")
    }

    func testAStoredEventThatDoesNotRepeatIsThePlainNotFound() {
        var asked = false
        XCTAssertNil(decide(recurring: false, standIn: { asked = true; return true }))
        XCTAssertFalse(asked, "a one-off has no stand-in to look for")
    }

    /// Verify LOW: every remaining occurrence edited on its own (the pick skips them) or none
    /// left. The #369 residual wording: it names the possible causes and does not promise a retry.
    func testAStoredSeriesWithoutAStandInGetsTheResidualWording() throws {
        let error = try XCTUnwrap(decide(standIn: { nil }))
        let message = try XCTUnwrap(error as? UndoTargetMissingError).message
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertEqual(message, UndoTargetMissingError(verb: .undo, kind: .event, title: "Standup", hasIdentifier: true,
                                                       seriesWithoutStandIn: true).message)
        XCTAssertTrue(message.contains("every occurrence left may have been edited on its own"), message)
    }

    /// Verify LOW (over-claim): the cause is named only when the stand-in starts after the series'
    /// recorded start, the slot a deleted first occurrence leaves. Otherwise a neutral wording that
    /// claims no cause and no permanence.
    func testAStandInThatDoesNotStartLaterGetsTheNeutralWording() throws {
        let error = try XCTUnwrap(decide(standIn: { false }))
        let message = try XCTUnwrap(error as? UndoTargetMissingError).message
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        XCTAssertTrue(message.hasPrefix("Cannot undo the creation of the recurring event 'Standup':"), message)
        XCTAssertFalse(message.contains("first occurrence"), "no unchecked cause: \(message)")
        XCTAssertFalse(message.contains("no retry"), "no unchecked permanence: \(message)")
        XCTAssertTrue(message.contains("Nothing was written and this history entry was kept"), message)
        XCTAssertTrue(message.contains("discard_id"), message)
        try assertAskThenDiscardThenDelete(message)
    }

    func testAStandInThatStartsLaterGetsTheFirstOccurrenceDeletedRefusal() throws {
        let error = try XCTUnwrap(decide(standIn: { true }))
        let missing = try XCTUnwrap(error as? UndoTargetMissingError, "\(error)")
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "kept, as the spec keeps every not-found")
        XCTAssertTrue(error is TrustedErrorMessage)
        let message = missing.message
        XCTAssertTrue(message.hasPrefix("Cannot undo the creation of the recurring event 'Standup':"), message)
        XCTAssertTrue(message.contains("first occurrence"), "names the shape: \(message)")
        XCTAssertTrue(message.contains("Nothing was written and this history entry was kept"), message)
        XCTAssertTrue(message.contains("no retry can change this"), "no retry can succeed: \(message)")
        XCTAssertFalse(message.contains("again only if it may still be syncing"), message)
        try assertAskThenDiscardThenDelete(message)
    }

    /// Verify MEDIUM (rounds 1–2): discard_id removes only the top record and any delete pushes its
    /// own, so the user is asked and the entry discarded first. The delete of what is left is the
    /// user's own step, by hand, with no tool named: a delete_event of the rest skips the
    /// modified_occurrences check and defaults to span `this` (the `UndoTargetChangedError` wording).
    private func assertAskThenDiscardThenDelete(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let ask = try XCTUnwrap(message.range(of: "ask the user whether to give up this undo"), message, file: file, line: line)
        let discard = try XCTUnwrap(message.range(of: "discard_id"), message, file: file, line: line)
        let byHand = try XCTUnwrap(message.range(of: "the series can then be deleted by hand if it should still go."),
                                   message, file: file, line: line)
        XCTAssertLessThan(ask.lowerBound, discard.lowerBound, "ask the user first: \(message)", file: file, line: line)
        XCTAssertLessThan(discard.lowerBound, byHand.lowerBound, "discard before any new record: \(message)", file: file, line: line)
        XCTAssertFalse(message.contains("delete_event"), "no destructive tool is named: \(message)", file: file, line: line)
        XCTAssertTrue(message.hasSuffix("the series can then be deleted by hand if it should still go."), message, file: file, line: line)
    }

    /// Round 2 LOW: the comparison is with the record's own start, not the stale object's. A stand-in
    /// later than the recorded start names the cause whatever the stale object reports.
    func testTheStandInIsComparedWithTheRecordedStart() throws {
        let created = UndoSnapshotFixtures.event(title: "Standup")
        let op = UndoOperation.createEvent(id: "S", title: "Standup", created: created)
        let later = try XCTUnwrap(SeriesCreateUndo.missingError(
            of: op, verb: .undo, stored: true, recurring: true,
            standInStart: { created.startDate.addingTimeInterval(60) }) as? UndoTargetMissingError)
        XCTAssertTrue(later.message.contains("first occurrence"), later.message)
        let same = try XCTUnwrap(SeriesCreateUndo.missingError(
            of: op, verb: .undo, stored: true, recurring: true,
            standInStart: { created.startDate }) as? UndoTargetMissingError)
        XCTAssertFalse(same.message.contains("first occurrence"), same.message)
        // Round-3 LOW: an earlier stand-in is the other half of "does not start later"
        // (`start != recorded` would otherwise survive).
        let earlier = try XCTUnwrap(SeriesCreateUndo.missingError(
            of: op, verb: .undo, stored: true, recurring: true,
            standInStart: { created.startDate.addingTimeInterval(-60) }) as? UndoTargetMissingError)
        XCTAssertFalse(earlier.message.contains("first occurrence"), earlier.message)
    }

    func testTheTitleIsShownAsOtherUndoErrorsShowIt() throws {
        let op = UndoOperation.createEvent(id: "S", title: "Bob's\u{202E} sync",
                                           created: UndoSnapshotFixtures.event(title: "Bob's\u{202E} sync"))
        for standIn in [true, false] {
            let error = try XCTUnwrap(decide(op, standIn: { standIn }))
            let message = try XCTUnwrap(error as? UndoTargetMissingError).message
            XCTAssertTrue(message.contains("'\(undoShownTitle("Bob's\u{202E} sync"))'"), message)
            XCTAssertFalse(message.contains("\u{202E}"), message)
        }
    }
}
