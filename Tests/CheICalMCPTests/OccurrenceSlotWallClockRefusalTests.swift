import XCTest
@testable import CheICalMCP

/// PR #558 round 1 (ruling F): where the refusal of an occurrence's undo goes when its slot is held
/// only at the wall-clock reading (`OccurrenceSlotWallClockRefusal`). It writes nothing and keeps the
/// record; the existing "slot not checked" answer (`occurrenceSlotUncheckedNote`) writes the one-off and
/// uses the record up, so it is not that route. The kept route is a thrown error that is not an
/// `UnrecoverableUndoError`, as for `UndoTargetChangedError`.
final class OccurrenceSlotWallClockRefusalTests: XCTestCase {
    private let refusal = OccurrenceSlotWallClockRefusal(title: "Third", kind: .recreateDeletedOccurrence)

    /// A single undo keeps the record (`handleUndo` puts it back for `.restore`), and the text is shown
    /// as it is (a trusted message).
    func testTheRecordIsKeptAndTheTextIsShownAsItIs() {
        XCTAssertEqual(UndoFailureDisposition.of(refusal), .restore)
        XCTAssertFalse((refusal as Error) is UnrecoverableUndoError)
        XCTAssertEqual(EventKitErrorSanitizer.writeFailureLog(handler: "undo", identifier: "batch member", error: refusal), refusal.message)
    }

    /// In a batch (for example `[occurrence id, series id]`, whose series member is restored first and
    /// makes the slot held), the refused member is kept with the members not yet restored, under the same
    /// id, and its own text follows the batch's. PR #558 round 2 (H6, H8, H32): the batch text says this
    /// member wrote nothing, for its own reason (not a missing calendar or list), and does not ask to
    /// check for a second copy.
    func testInABatchTheRefusedMemberIsKept() throws {
        let occurrence = UndoOperation.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(title: "Third"), notCarriedOver: [])
        let series = UndoOperation.deleteEvent(id: "S", snapshot: UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 6))
        let failure = UndoOperation.batchUndoFailure(
            members: [occurrence, series], interrupted: .init(completed: 1, underlying: refusal),
            describe: { EventKitErrorSanitizer.writeFailureLog(handler: "undo", identifier: "batch member", error: $0) })
        let partial = try XCTUnwrap(failure as? UndoBatchPartiallyUndoneError, "\(failure)")
        XCTAssertEqual(partial.remaining.count, 1)
        XCTAssertEqual(partial.remaining.first?.restoredItemTitle, "Third")
        XCTAssertEqual(partial.restoredCount, 1)
        XCTAssertEqual(partial.failing, .runsLast)
        XCTAssertTrue(partial.message.hasSuffix(": " + refusal.message), partial.message)
        XCTAssertTrue(partial.message.contains("'Third' was refused before anything of it was written (this server could not tell whether its series already holds its time, as its own error says), so this attempt left no copy of it."), partial.message)
        XCTAssertFalse(partial.message.contains("may have left something written"), partial.message)
        XCTAssertFalse(partial.message.contains("its calendar or list was not found"), partial.message)
        XCTAssertEqual(UndoFailureDisposition.of(partial), .restore)
        XCTAssertFalse(UndoOperation.failsBeforeAnyWrite(refusal))
    }

    /// The split move's undo (`MoveByCopyUndo.run`): the refusal comes from restoring the source, so it
    /// is thrown before the copy is looked at, and the copy stays where the move put it.
    func testASplitMovesUndoThrowsItBeforeTheCopyIsTouched() async {
        let moveRefusal = OccurrenceSlotWallClockRefusal(title: "Third", kind: .undoMoveByCopy)
        do {
            _ = try await MoveByCopyUndo.run(copyID: "COPY-1", restoreOriginal: { throw moveRefusal },
                                             checkAndRemove: { XCTFail("the copy must not be checked or removed") })
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual((error as? OccurrenceSlotWallClockRefusal)?.message, moveRefusal.message)
            XCTAssertEqual(UndoFailureDisposition.of(error), .restore)
        }
    }
}
