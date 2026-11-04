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

    func testOnlyACreateUndoProbesForAStandIn() {
        let move = UndoOperation.moveEvent(id: "S", fromCalendarIdentifier: "a", toCalendarIdentifier: "b",
                                           title: "Standup", isSeries: false)
        let delete = UndoOperation.deleteEvent(snapshot: UndoSnapshotFixtures.event(title: "Standup"))
        var asked = 0
        for (operation, verb) in [(createOp, UndoHistoryVerb.redo), (move, .undo), (delete, .undo), (delete, .redo)] {
            XCTAssertNil(SeriesCreateUndo.missingError(of: operation, verb: verb, stored: true,
                                                       hasStandIn: { asked += 1; return true }), "\(operation) \(verb)")
        }
        XCTAssertEqual(asked, 0, "no scan for any other record")
    }

    func testNothingStoredIsThePlainNotFound() {
        var asked = false
        XCTAssertNil(SeriesCreateUndo.missingError(of: createOp, verb: .undo, stored: false,
                                                   hasStandIn: { asked = true; return true }))
        XCTAssertFalse(asked, "a deleted series is not scanned")
    }

    func testAStoredSeriesWithoutAStandInIsThePlainNotFound() {
        XCTAssertNil(SeriesCreateUndo.missingError(of: createOp, verb: .undo, stored: true, hasStandIn: { false }),
                     "the probe requires a stand-in, so a plain not-found keeps its message")
    }

    func testAStoredSeriesWithAStandInGetsTheFirstOccurrenceDeletedRefusal() throws {
        let error = try XCTUnwrap(SeriesCreateUndo.missingError(of: createOp, verb: .undo, stored: true, hasStandIn: { true }))
        let missing = try XCTUnwrap(error as? UndoTargetMissingError, "\(error)")
        XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "kept, as the spec keeps every not-found")
        XCTAssertTrue(error is TrustedErrorMessage)
        let message = missing.message
        XCTAssertTrue(message.hasPrefix("Cannot undo the creation of the recurring event 'Standup':"), message)
        XCTAssertTrue(message.contains("first occurrence"), "names the shape: \(message)")
        XCTAssertTrue(message.contains("Nothing was written and this history entry was kept"), message)
        XCTAssertTrue(message.contains("no retry can change this"), "no retry can succeed: \(message)")
        XCTAssertFalse(message.contains("again only if it may still be syncing"), message)
        XCTAssertTrue(message.contains("delete_event"), "the way to remove what is left: \(message)")
        XCTAssertTrue(message.contains("discard_id"), "the way on: \(message)")
    }

    func testTheTitleIsShownAsOtherUndoErrorsShowIt() throws {
        let op = UndoOperation.createEvent(id: "S", title: "Bob's\u{202E} sync",
                                           created: UndoSnapshotFixtures.event(title: "Bob's\u{202E} sync"))
        let error = try XCTUnwrap(SeriesCreateUndo.missingError(of: op, verb: .undo, stored: true, hasStandIn: { true }))
        let message = try XCTUnwrap(error as? UndoTargetMissingError).message
        XCTAssertTrue(message.contains("'\(undoShownTitle("Bob's\u{202E} sync"))'"), message)
        XCTAssertFalse(message.contains("\u{202E}"), message)
    }
}
