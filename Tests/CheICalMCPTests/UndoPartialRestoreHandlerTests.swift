import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #287: `undo` with `restore_available` on a batch the pre-check refuses. The executor is
/// scripted as the manager answers (`UndoBatchPartialRestore.run`): it keeps the members whose
/// calendar or list is missing, the handler puts back a record of only those under the same id,
/// and the answer says what was restored and what is kept. No EventKit and no TCC prompt.
private actor PartialRestoreExecutor: UndoExecutionSource {
    private(set) var flags: [Bool] = []
    /// What the next undo answers, in order; the last one repeats.
    private var answers: [Result<String, Error>]

    init(_ answers: [Result<String, Error>]) {
        self.answers = answers
    }

    func executeUndo(_ operation: UndoOperation) async throws -> String {
        try await executeUndo(operation, restoreAvailable: false)
    }

    func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String {
        flags.append(restoreAvailable)
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        return try answer.get()
    }

    func executeRedo(_ operation: UndoOperation) async throws -> String { "Redone" }
}

final class UndoPartialRestoreHandlerTests: XCTestCase {
    private func deleted(_ title: String) -> UndoOperation {
        .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: title))
    }

    private func reminder(_ title: String) -> UndoOperation {
        .deleteReminder(snapshot: UndoSnapshotFixtures.reminder(title: title))
    }

    private func object(_ result: CallTool.Result) throws -> [String: Any] {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected text content")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else { return "" }
        return text
    }

    private let refusal = UndoRestoreDestinationMissingError(findings: [], total: 4)

    private func kept(_ members: [UndoOperation]) -> UndoBatchKeptUnavailable {
        UndoBatchKeptUnavailable(kept: members, message: "Undone batch (2 operations). 2 items of this batch were not restored")
    }

    /// The batch of a reminder batch delete (or a cleanup): two restored, two kept.
    private func setUp(_ answers: [Result<String, Error>]) async throws
        -> (CalendarUndoManager, PartialRestoreExecutor, CheICalMCPServer, String) {
        let history = CalendarUndoManager()
        await history.record(deleted("Older"))
        await history.record(.batch(["A", "B", "C", "D"].map(reminder)))
        let snapshot = await history.historySnapshot()
        let id = try XCTUnwrap(snapshot.entries.first?.id)
        let executor = PartialRestoreExecutor(answers)
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)
        return (history, executor, server, id)
    }

    func testRestoreAvailableRestoresSomeAndKeepsTheRestUnderTheSameId() async throws {
        let (history, executor, server, id) = try await setUp([.failure(kept([reminder("B"), reminder("D")]))])

        let result = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .bool(true)])

        XCTAssertNotEqual(result.isError, true)
        let answer = try object(result)
        XCTAssertEqual(answer["success"] as? Bool, true)
        XCTAssertEqual(answer["partial"] as? Bool, true)
        XCTAssertEqual(answer["kept"] as? Int, 2)
        XCTAssertTrue((answer["message"] as? String)?.contains("were not restored") == true, "\(answer)")
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.first?.id, id, "the narrowed record keeps its id")
        XCTAssertEqual(after.entries.first?.description, "Batch (2 operations)")
        XCTAssertEqual(after.entries.count, 2, "the older record is still under it")
        let flags = await executor.flags
        XCTAssertEqual(flags, [true])
    }

    /// Giving up the kept record drops only the kept items; the older record is reachable.
    func testDiscardIdDropsOnlyTheKeptRecord() async throws {
        let (history, _, server, id) = try await setUp([.failure(kept([reminder("B"), reminder("D")]))])
        _ = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .bool(true)])

        let discarded = await server.handleToolCallForTesting(name: "undo", arguments: ["discard_id": .string(id)])

        let discardText = try text(discarded)
        XCTAssertNotEqual(discarded.isError, true, discardText)
        XCTAssertEqual(try object(discarded)["description"] as? String, "Batch (2 operations)")
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Deleted event: Older"])
    }

    /// Once the calendar or list is back, a later undo restores the kept items and consumes the
    /// record.
    func testALaterUndoRestoresTheKeptItems() async throws {
        let (history, executor, server, _) = try await setUp([.failure(kept([reminder("B"), reminder("D")])),
                                                              .success("Undone batch (2 operations)")])
        _ = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .bool(true)])

        let later = await server.handleToolCallForTesting(name: "undo", arguments: [:])

        let laterText = try text(later)
        XCTAssertNotEqual(later.isError, true, laterText)
        XCTAssertEqual(try object(later)["message"] as? String, "Undone batch (2 operations)")
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Deleted event: Older"])
        let flags = await executor.flags
        XCTAssertEqual(flags, [true, false])
    }

    /// Without the argument (or with every member blocked, where the manager refuses as before) the
    /// refusal stands and the record is kept whole.
    func testTheRefusalKeepsTheRecordWhole() async throws {
        for arguments in [[:], ["restore_available": Value.bool(true)]] as [[String: Value]] {
            let (history, _, server, id) = try await setUp([.failure(refusal)])

            let result = await server.handleToolCallForTesting(name: "undo", arguments: arguments)

            XCTAssertEqual(result.isError, true)
            let after = await history.historySnapshot()
            XCTAssertEqual(after.entries.first?.id, id)
            XCTAssertEqual(after.entries.first?.description, "Batch (4 operations)", "\(arguments)")
        }
    }

    /// A part-way failure on the partial path keeps the blocked members and the ones not yet restored.
    func testAPartWayFailureOnThePartialPathKeepsWhatIsLeft() async throws {
        let stopped = UndoBatchPartialRestoreStoppedError(remaining: [reminder("B"), reminder("D"), reminder("A")], message: "stopped")
        let (history, _, server, id) = try await setUp([.failure(stopped)])

        let result = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .bool(true)])

        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(try text(result).hasSuffix("stopped"))
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.first?.id, id)
        XCTAssertEqual(after.entries.first?.description, "Batch (3 operations)")
    }

    /// An event batch: the same narrowing.
    func testAnEventBatchIsNarrowedTheSameWay() async throws {
        let history = CalendarUndoManager()
        await history.record(.batch(["A", "B", "C"].map(deleted)))
        let executor = PartialRestoreExecutor([.failure(kept([deleted("B")]))])
        let server = try await CheICalMCPServer(undoManager: history, undoExecutionSource: executor)

        let result = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .bool(true)])

        XCTAssertEqual(try object(result)["kept"] as? Int, 1)
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.map(\.description), ["Batch (1 operation)"])
    }

    func testRestoreAvailableIsABooleanAndNotWithDiscardId() async throws {
        let (history, executor, server, id) = try await setUp([.success("x")])
        let wrongType = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .string("yes")])
        XCTAssertEqual(wrongType.isError, true)
        let both = await server.handleToolCallForTesting(name: "undo", arguments: ["restore_available": .bool(true),
                                                                                  "discard_id": .string(id)])
        XCTAssertEqual(both.isError, true)
        let bothText = try text(both)
        XCTAssertTrue(bothText.contains("restore_available"), bothText)
        let flags = await executor.flags
        XCTAssertTrue(flags.isEmpty, "nothing ran")
        let after = await history.historySnapshot()
        XCTAssertEqual(after.entries.count, 2)
    }
}
