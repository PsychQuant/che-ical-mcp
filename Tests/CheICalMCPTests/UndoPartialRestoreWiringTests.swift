import XCTest
@testable import CheICalMCP

/// #287: the production wiring of the partial restore, which reads the store and so no unit test
/// runs: the manager's batch undo goes through `UndoBatchPartialRestore.run`, the split reads the
/// calendars and lists the restore reads, and the `undo` handler passes `restore_available` on and
/// narrows the record for both new answers.
final class UndoPartialRestoreWiringTests: XCTestCase {
    private static func body(_ declaration: String, in file: String) throws -> String {
        try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source(file)), declaration)
    }

    func testTheBatchUndoGoesThroughTheSplit() throws {
        let undoBatch = try Self.body("func undoBatch(_ ops: [UndoOperation], restoreAvailable: Bool", in: "EventKit/EventKitManager.swift")
        let permanent = try XCTUnwrap(undoBatch.range(of: "try verifyBatchMemberRestorable(.batch(ops), verb: .undo)"))
        let partial = try XCTUnwrap(undoBatch.range(of: "if restoreAvailable { return try await undoBatchRestoringAvailable(ops) }"))
        XCTAssertLessThan(permanent.lowerBound, partial.lowerBound, "the refusal that discards the record still comes first")
        let restoring = try Self.body("func undoBatchRestoringAvailable(", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(restoring.contains("UndoBatchPartialRestore.run("))
        XCTAssertTrue(restoring.contains("verifyRestoreDestinations(of: ops, verb: .undo)"))
        XCTAssertTrue(restoring.contains("splitByRestoreDestination(ops)"))
        XCTAssertTrue(restoring.contains("runMembers: { members in try await self.undoBatch(members) }"),
                      "the restorable members run as a whole batch does: #236's check, #248 A's part-way rule")
        XCTAssertTrue(restoring.contains("UndoBatchKeptUnavailable("))
        let dispatch = try Self.body("func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool)", in: "EventKit/EventKitManager.swift")
        XCTAssertTrue(dispatch.contains("undoBatch(ops, restoreAvailable: true)"))
    }

    func testTheSplitReadsTheListsTheRestoreReads() throws {
        let split = try Self.body("func splitByRestoreDestination(", in: "EventKit/UndoBatchPartialRestore.swift")
        XCTAssertTrue(split.contains("eventCalendarsForRestore()"))
        XCTAssertTrue(split.contains("reminderListsForRestore()"))
        XCTAssertTrue(split.contains("UndoRestoreDestination.problems("))
    }

    func testTheHandlerPassesTheArgumentAndNarrowsTheRecord() throws {
        let handler = try Self.body("private func handleUndo(arguments:", in: "Server.swift")
        XCTAssertTrue(handler.contains("executeUndo(record.operation, restoreAvailable: restoreAvailable)"))
        XCTAssertTrue(handler.contains("catch let kept as UndoBatchKeptUnavailable"))
        XCTAssertTrue(handler.contains("finishPartialUndo(record, kept: .batch(kept.kept), restored: .batch(kept.restored))"))
        XCTAssertTrue(handler.contains("catch let stopped as UndoBatchPartialRestoreStoppedError"))
        XCTAssertTrue(handler.contains("restoreFailedUndo(record, remaining: .batch(stopped.remaining))"))
    }
}
