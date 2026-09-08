import EventKit
import MCP
import XCTest
@testable import CheICalMCP

private actor CopyFake: EventCopySource {
    enum Failure: Error { case failed }
    let history: CalendarUndoManager
    init(history: CalendarUndoManager) { self.history = history }
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = identifier
        event.startDate = Date(timeIntervalSince1970: 100)
        event.endDate = Date(timeIntervalSince1970: 200)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        let outcome = try EventCopyOperation.execute(source: deleteOriginal ? EventSnapshot(from: event, includeRecurrence: false) : nil, saveCopy: {
            if identifier == "save-fail" { throw Failure.failed }
            return EventCopyValue(eventIdentifier: "copy-" + identifier, title: identifier)
        }, removeSource: {
            if identifier == "delete-fail" { throw Failure.failed }
        })
        if let undo = outcome.undo { await history.record(undo) }
        return outcome.value
    }
}
final class EventCopyHandlerTests: XCTestCase {
    func testBatchMixedFailuresCountOnlySuccessfulSourceDeletion() async throws {
        let history = CalendarUndoManager()
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: history))
        let raw = try await server.executeToolCall(name: "move_events_batch", arguments: ["target_calendar": .string("Work"), "target_calendar_source": .string("Other"), "event_ids": .array([.string("save-fail"), .string("good"), .string("delete-fail")])])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(result["succeeded"] as? Int, 1)
        XCTAssertEqual(result["failed"] as? Int, 2)
        let rows = try XCTUnwrap(result["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true, false])
        let recorded = await history.history()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].description.contains("good"))
    }
    func testCopyOnlyLeavesHistoryUntouched() async throws {
        let history = CalendarUndoManager()
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: history))
        let raw = try await server.executeToolCall(name: "copy_event", arguments: ["event_id": .string("good"), "target_calendar": .string("Work")])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "copied")
        let count = await history.undoCount
        XCTAssertEqual(count, 0)
    }
}
