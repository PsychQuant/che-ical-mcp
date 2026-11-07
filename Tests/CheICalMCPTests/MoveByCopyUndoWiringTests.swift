import XCTest
@testable import CheICalMCP

/// #466: what the `.moveByCopy` arm of `executeUndo` runs, which an in-memory store cannot drive:
/// the original is restored through the delete-undo's own code, the copy is checked through the
/// #236 guard as the undo of a created event, and removed with span `this`. Read from `Sources/`.
final class MoveByCopyUndoWiringTests: XCTestCase {
    private static let manager = (try? SourcePins.source("EventKit/EventKitManager.swift")) ?? ""

    private func arm() throws -> String {
        let undo = try XCTUnwrap(SourcePins.body(of: "func executeUndo(", in: Self.manager))
        let code = SourcePins.code(undo)
        let start = try XCTUnwrap(code.range(of: "case .moveByCopy(let original, let isSplit, let notCarriedOver, let copyID, let copy):"))
        let end = try XCTUnwrap(code.range(of: "case .createReminder(", range: start.upperBound..<code.endIndex))
        return String(code[start.upperBound..<end.lowerBound])
    }

    /// Round 2, LOW 2: a split's original is one occurrence, restored through the occurrence undo, so
    /// #285's check skips the write when the series already holds the slot again; a fallback copy's
    /// one-off goes through the event undo. Both read the calendar as a move-undo words it (INFO).
    func testTheArmRestoresTheOriginalAsTheMatchingDeleteUndoDoes() throws {
        let arm = try arm()
        XCTAssertEqual(SourcePins.ranges(of: "MoveByCopyUndo.run(", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "isSplit", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "let undone = try await self.undoDeletedOccurrence(original, notCarriedOver: notCarriedOver, kind: .undoMoveByCopy)", in: arm).count, 1)
        // Round 3, MEDIUM: the occurrence undo's outcome goes in, so a held slot keeps the copy.
        XCTAssertEqual(SourcePins.ranges(of: "return MoveByCopyUndo.Restore(text: undone.text, outcome: undone.outcome)", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "return .written(try await self.undoDeletedEvent(original, kind: .undoMoveByCopy).text)", in: arm).count, 1)
    }

    /// Round 2, MEDIUM: the check and the removal are one async closure formed on the actor (its
    /// behavior is `MoveByCopyUndoTests.testTheCheckAndTheRemovalRunOnTheCallersActor`); `run` takes
    /// no synchronous closure that touches the store.
    func testTheArmChecksTheCopyAsACreatedEventAndRemovesOnlyThatOccurrence() throws {
        let arm = try arm()
        XCTAssertEqual(SourcePins.ranges(of: "checkAndRemove: {", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "let event = try await self.verifiedEvent(of: .createEvent(id: copyID, title: copy.title, created: copy), verb: .undo)", in: arm).count, 1)
        // Round 3: a copy with attendees is kept; the failure is described in the closure, on the actor.
        XCTAssertEqual(SourcePins.ranges(of: "guard !event.hasAttendees else { throw MoveByCopyUndo.CopyHasAttendees() }", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "try MoveByCopyUndo.removing({ try self.removeMoveCopy(event) }, describe: {", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "removeCopy:", in: arm).count, 0)
        let remove = try XCTUnwrap(SourcePins.body(of: "func removeMoveCopy(", in: Self.manager))
        XCTAssertEqual(SourcePins.ranges(of: "try eventStore.remove(copy, span: .thisEvent)", in: remove).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "MoveByCopyUndo.message(restore: undone.restore, title: original.title, copyID: copyID, copy: undone.copy)", in: arm).count, 1)

        let seam = SourcePins.code(try SourcePins.source("EventKit/MoveByCopyUndo.swift"))
        let run = try XCTUnwrap(SourcePins.body(of: "static func run(", in: seam))
        XCTAssertEqual(SourcePins.ranges(of: "try await checkAndRemove()", in: run).count, 1)
        let signature = try XCTUnwrap(seam.range(of: "static func run(")).upperBound
        let header = seam[signature...].prefix(while: { $0 != "{" })
        XCTAssertFalse(header.contains("throws -> Void,") && header.contains("removeCopy"), String(header))
        XCTAssertTrue(header.contains("checkAndRemove: () async throws -> Void"), String(header))
        XCTAssertFalse(header.contains("describe"), "no synchronous closure runs off the actor: \(header)")
    }

    /// Round 3, LOW: nothing suspends between the copy's last comparison and its removal. In the
    /// guard, the only await of the event case is the access check, before the lookup and the
    /// comparison (`UndoTargetCheck.check`, synchronous); `verifiedEvent` awaits only that guard.
    func testNothingSuspendsBetweenTheCopysComparisonAndItsRemoval() throws {
        let guardSource = SourcePins.code(try SourcePins.source("EventKit/EventKitManager+UndoGuard.swift"))
        let target = try XCTUnwrap(SourcePins.body(of: "func verifiedHistoryTarget(", in: guardSource))
        let eventCase = try XCTUnwrap(target.range(of: "case .event:"))
        let reminderCase = try XCTUnwrap(target.range(of: "case .reminder:"))
        let event = String(target[eventCase.upperBound..<reminderCase.lowerBound])
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bawait\b"#, in: event).count, 1, event)
        let access = try XCTUnwrap(event.range(of: "try await ensureCalendarAccess()"))
        let check = try XCTUnwrap(event.range(of: "UndoTargetCheck.check("))
        XCTAssertLessThan(access.lowerBound, check.lowerBound)
        let verified = try XCTUnwrap(SourcePins.body(of: "func verifiedEvent(", in: guardSource))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bawait\b"#, in: verified).count, 1, verified)
        XCTAssertEqual(SourcePins.ranges(of: "try await verifiedHistoryTarget(of: operation, verb: verb)", in: verified).count, 1)
    }

    /// The redo of the record writes nothing (#247), like every record but completions.
    func testRedoOfTheRecordIsTheNoWriteArm() throws {
        let redo = SourcePins.code(try XCTUnwrap(SourcePins.body(of: "func executeRedo(", in: Self.manager)))
        let noWrite = try XCTUnwrap(redo.range(of: "return operation.redoInstruction ??"))
        let listed = try XCTUnwrap(redo.range(of: ".moveByCopy"))
        XCTAssertLessThan(listed.lowerBound, noWrite.lowerBound)
    }
}
