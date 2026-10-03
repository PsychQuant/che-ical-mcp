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

    struct MoveCall: Equatable { let identifier: String; let occurrenceDate: Date?; let span: EventMovePolicy.Span }
    private(set) var moveCalls: [MoveCall] = []

    /// #226: the move path. Identifiers select the outcome.
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue {
        moveCalls.append(MoveCall(identifier: identifier, occurrenceDate: occurrenceDate, span: span))
        switch identifier {
        case "save-fail", "delete-fail": throw Failure.failed
        case "refused": throw EventKitError.moveRefused(reason: "fixed refusal reason")
        case "cross-account":
            return EventMoveValue(result: .init(method: .inPlace, eventIdentifier: "moved-" + identifier, notCarriedOver: []), title: identifier)
        case "fallback":
            return EventMoveValue(result: .init(method: .copied, eventIdentifier: "copy-" + identifier, notCarriedOver: ["structured_location"]), title: identifier)
        default:
            await history.record(.moveEvent(id: identifier, fromCalendarIdentifier: "from", title: identifier, isSeries: false))
            return EventMoveValue(result: .init(method: .inPlace, eventIdentifier: identifier, notCarriedOver: []), title: identifier)
        }
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
    // MARK: - #226 move response and parameters

    private func move(_ server: CheICalMCPServer, _ args: [String: Value]) async throws -> [[String: Any]] {
        var arguments = args
        arguments["target_calendar"] = .string("Work")
        let raw = try await server.executeToolCall(name: "move_events_batch", arguments: arguments)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return try XCTUnwrap(result["results"] as? [[String: Any]])
    }

    func testInPlaceMoveKeepsTheIdentifierAndSaysSo() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let row = try await move(server, ["event_ids": .array([.string("good")])])[0]
        XCTAssertEqual(row["method"] as? String, "in_place")
        XCTAssertEqual(row["id_changed"] as? Bool, false)
        XCTAssertNil(row["new_event_id"], "new_event_id only when the identifier changed")
        XCTAssertNil(row["not_carried_over"])
    }

    func testMoveAcrossAccountsReportsTheNewIdentifier() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let row = try await move(server, ["event_ids": .array([.string("cross-account")])])[0]
        XCTAssertEqual(row["method"] as? String, "in_place")
        XCTAssertEqual(row["id_changed"] as? Bool, true)
        XCTAssertEqual(row["new_event_id"] as? String, "moved-cross-account")
    }

    func testFallbackCopyListsTheFieldsItDidNotKeep() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let row = try await move(server, ["event_ids": .array([.string("fallback")])])[0]
        XCTAssertEqual(row["method"] as? String, "copied")
        XCTAssertEqual(row["id_changed"] as? Bool, true)
        XCTAssertEqual(row["not_carried_over"] as? [String], ["structured_location"])
    }

    func testRefusalReasonIsReportedForThatItem() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let row = try await move(server, ["event_ids": .array([.string("refused")])])[0]
        XCTAssertEqual(row["success"] as? Bool, false)
        XCTAssertEqual(row["error"] as? String, "fixed refusal reason")
    }

    func testSpanAndIndexAlignedOccurrenceDatesReachTheSource() async throws {
        let fake = CopyFake(history: CalendarUndoManager())
        let server = try await CheICalMCPServer(eventCopySource: fake)
        _ = try await move(server, ["event_ids": .array([.string("a"), .string("b")]),
                                    "span": .string("all"),
                                    "occurrence_dates": .array([.string("2026-10-21T10:00:00+08:00"), .null])])
        let calls = await fake.moveCalls
        XCTAssertEqual(calls.map(\.identifier), ["a", "b"])
        XCTAssertEqual(calls.map(\.span), [.all, .all])
        XCTAssertEqual(calls[0].occurrenceDate, ISO8601DateFormatter().date(from: "2026-10-21T02:00:00Z"))
        XCTAssertNil(calls[1].occurrenceDate)
    }

    func testSpanDefaultsToThis() async throws {
        let fake = CopyFake(history: CalendarUndoManager())
        let server = try await CheICalMCPServer(eventCopySource: fake)
        _ = try await move(server, ["event_ids": .array([.string("a")])])
        let calls = await fake.moveCalls
        XCTAssertEqual(calls.map(\.span), [.this])
    }

    func testOccurrenceDatesOfTheWrongLengthAreRejectedBeforeAnyWrite() async throws {
        let fake = CopyFake(history: CalendarUndoManager())
        let server = try await CheICalMCPServer(eventCopySource: fake)
        do {
            _ = try await move(server, ["event_ids": .array([.string("a"), .string("b")]),
                                        "occurrence_dates": .array([.string("2026-10-21")])])
            XCTFail("length mismatch must be rejected")
        } catch {}
        let calls = await fake.moveCalls
        XCTAssertEqual(calls, [])
    }

    func testUnknownSpanIsRejected() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        do { _ = try await move(server, ["event_ids": .array([.string("a")]), "span": .string("future")]); XCTFail("span") } catch {}
    }

    func testCopyEventMoveReportsWhetherTheIdentifierChanged() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let raw = try await server.executeToolCall(name: "copy_event", arguments: [
            "event_id": .string("good"), "target_calendar": .string("Work"), "delete_original": .bool(true)])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "moved")
        XCTAssertEqual(result["id_changed"] as? Bool, true)
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
