import Foundation
import MCP
import XCTest
@testable import CheICalMCP

final class UndoHistoryDiscardHandlerTests: XCTestCase {
    func testDiscardExposesOlderRecordWithoutCreatingRedo() async throws {
        for reversed in [false, true] {
            let manager = CalendarUndoManager()
            let event = UndoOperation.createEvent(id: "event", title: "Event")
            let reminder = UndoOperation.createReminder(id: "reminder", title: "Reminder")
            await manager.record(reversed ? event : reminder)
            await manager.record(reversed ? reminder : event)
            let server = try await CheICalMCPServer(undoManager: manager)
            let raw = try await server.executeToolCall(name: "undo_history", arguments: [:])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let entries = try XCTUnwrap(json["history"] as? [[String: Any]])
            let id = try XCTUnwrap(entries.first?["id"] as? String)
            _ = try await server.executeToolCall(name: "undo", arguments: ["discard_id": .string(id)])
            let state = await manager.historySnapshot()
            XCTAssertEqual(state.undoCount, 1)
            XCTAssertEqual(state.redoCount, 0)
            do {
                _ = try await server.executeToolCall(name: "undo", arguments: ["discard_id": .string(id)])
                XCTFail("stale ID must fail")
            } catch {}
            let remaining = await manager.undoCount
            XCTAssertEqual(remaining, 1)
        }
    }
    func testDiscardPreservesExistingRedoAndRedoBusyLock() async throws {
        let manager = CalendarUndoManager()
        await manager.record(.createEvent(id: "a", title: "A"))
        await manager.record(.createEvent(id: "b", title: "B"))
        let started = try await manager.beginUndo()
        let record = try XCTUnwrap(started)
        await manager.finishHistoryOperation(record)
        let state = await manager.historySnapshot()
        let text = try XCTUnwrap(state.entries.first?.id)
        let id = try XCTUnwrap(UUID(uuidString: text))
        _ = try await manager.discardUndo(expectedID: id)
        let after = await manager.historySnapshot()
        XCTAssertEqual(after.redoCount, 1)
        XCTAssertEqual(after.undoCount, 0)
        let redo = try await manager.beginRedo()
        let redone = try XCTUnwrap(redo)
        do { _ = try await manager.discardUndo(expectedID: redone.id); XCTFail("redo busy") } catch {}
        await manager.finishHistoryOperation(redone)
        _ = try await manager.discardUndo(expectedID: redone.id)
    }

    func testMalformedIdsNeverMutateHistory() async throws {
        let manager = CalendarUndoManager()
        await manager.record(.createEvent(id: "e", title: "E"))
        let server = try await CheICalMCPServer(undoManager: manager)
        for value: Value in [.null, .int(1), .bool(true), .object([:]), .string(""), .string("not-id")] {
            do { _ = try await server.executeToolCall(name: "undo", arguments: ["discard_id": value]); XCTFail("invalid id") } catch {}
        }
        let count = await manager.undoCount
        XCTAssertEqual(count, 1)
    }
    func testBusyBlocksDiscardAndSecondBeginThenRestoreKeepsId() async throws {
        let manager = CalendarUndoManager()
        await manager.record(.createEvent(id: "e", title: "E"))
        let initial = await manager.historySnapshot()
        let started = try await manager.beginUndo()
        let record = try XCTUnwrap(started)
        do { _ = try await manager.discardUndo(expectedID: record.id); XCTFail("busy") } catch {}
        do { _ = try await manager.beginRedo(); XCTFail("busy") } catch {}
        await manager.restoreFailedUndo(record)
        let restored = await manager.historySnapshot()
        XCTAssertEqual(restored.entries.first?.id, initial.entries.first?.id)
        _ = try await manager.discardUndo(expectedID: record.id)
        do { _ = try await manager.discardUndo(expectedID: record.id); XCTFail("empty") } catch {}
    }
}
