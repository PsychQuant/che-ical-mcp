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
        let start = try XCTUnwrap(code.range(of: "case .moveByCopy(let original, let copyID, let copy):"))
        let end = try XCTUnwrap(code.range(of: "case .createReminder(", range: start.upperBound..<code.endIndex))
        return String(code[start.upperBound..<end.lowerBound])
    }

    func testTheArmRestoresTheOriginalAsADeleteUndoDoes() throws {
        let arm = try arm()
        XCTAssertEqual(SourcePins.ranges(of: "MoveByCopyUndo.run(", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "restoreOriginal: { try await self.undoDeletedEvent(original).text }", in: arm).count, 1)
    }

    func testTheArmChecksTheCopyAsACreatedEventAndRemovesOnlyThatOccurrence() throws {
        let arm = try arm()
        XCTAssertEqual(SourcePins.ranges(of: "checkCopy: { try await self.verifiedEvent(of: .createEvent(id: copyID, title: copy.title, created: copy), verb: .undo) }", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "removeCopy: { try self.removeMoveCopy($0) }", in: arm).count, 1)
        let remove = try XCTUnwrap(SourcePins.body(of: "func removeMoveCopy(", in: Self.manager))
        XCTAssertEqual(SourcePins.ranges(of: "try eventStore.remove(copy, span: .thisEvent)", in: remove).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "MoveByCopyUndo.message(restored: undone.restored, copyID: copyID, copy: undone.copy)", in: arm).count, 1)
    }

    /// The redo of the record writes nothing (#247), like every record but completions.
    func testRedoOfTheRecordIsTheNoWriteArm() throws {
        let redo = SourcePins.code(try XCTUnwrap(SourcePins.body(of: "func executeRedo(", in: Self.manager)))
        let noWrite = try XCTUnwrap(redo.range(of: "return operation.redoInstruction ??"))
        let listed = try XCTUnwrap(redo.range(of: ".moveByCopy"))
        XCTAssertLessThan(listed.lowerBound, noWrite.lowerBound)
    }
}
