import EventKit
import MCP
import XCTest
@testable import CheICalMCP

private actor CopyFake: EventCopySource {
    enum Failure: Error { case failed }
    let history: CalendarUndoManager
    init(history: CalendarUndoManager) { self.history = history }
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        if deleteOriginal {
            // copy_event delete_original goes through the move path (#226).
            let moved = try await moveEventValue(identifier: identifier, occurrenceDate: nil, span: .this,
                                                 toCalendarName: toCalendarName, toCalendarSource: toCalendarSource)
            return EventCopyValue(eventIdentifier: moved.result.eventIdentifier, title: moved.title, move: moved.result)
        }
        if identifier == "save-fail" { throw Failure.failed }
        if identifier == "reminder-id" { throw EventKitError.eventNotFound(identifier: identifier) }
        if identifier == "refused-alarms" { throw EventKitError.copyRefused(code: "eventkit_error_1", alarmKinds: ["location_alarms"]) }
        return EventCopyValue(eventIdentifier: "copy-" + identifier, title: identifier)
    }

    func eventTimeZone(identifier: String) async -> TimeZone? {
        identifier.hasPrefix("ny-") ? TimeZone(identifier: "America/New_York") : nil
    }

    struct MoveCall: Equatable { let identifier: String; let occurrenceDate: Date?; let span: EventMovePolicy.Span }
    private(set) var moveCalls: [MoveCall] = []

    /// #226: the move path. Identifiers select the outcome.
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue {
        moveCalls.append(MoveCall(identifier: identifier, occurrenceDate: occurrenceDate, span: span))
        switch identifier {
        case "save-fail", "delete-fail": throw Failure.failed
        case "reminder-id": throw EventKitError.eventNotFound(identifier: identifier)
        case "refused": throw EventKitError.moveRefused(reason: "fixed refusal reason")
        case "refused-alarms": throw EventKitError.copyRefused(code: "eventkit_error_1", alarmKinds: ["location_alarms", "email_alarms"])
        case "cross-account":
            return EventMoveValue(result: .init(method: .inPlace, eventIdentifier: "moved-" + identifier, notCarriedOver: []), title: identifier)
        case "fallback":
            return EventMoveValue(result: .init(method: .copied, eventIdentifier: "copy-" + identifier, notCarriedOver: ["structured_location"]), title: identifier)
        case "same-calendar":
            return EventMoveValue(result: .init(method: .unchanged, eventIdentifier: identifier, notCarriedOver: []), title: identifier)
        default:
            await history.record(.moveEvent(id: identifier, fromCalendarIdentifier: "from", toCalendarIdentifier: "to", title: identifier, isSeries: false))
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

    /// #253 verify round 2, D1: a copy the target refused names the alarm kinds it carried.
    func testARefusedCopyNamesItsAlarmKindsInTheRow() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let row = try await move(server, ["event_ids": .array([.string("refused-alarms")])])[0]
        XCTAssertEqual(row["success"] as? Bool, false)
        let error = try XCTUnwrap(row["error"] as? String)
        XCTAssertTrue(error.contains("location_alarms, email_alarms"), error)
        XCTAssertTrue(error.contains("eventkit_error_1"), error)
    }

    /// Verify round 3 #7: a plain copy_event returns the refusal message as it is.
    func testARefusedPlainCopyReturnsTheMessageVerbatim() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let result = await server.handleToolCallForTesting(name: "copy_event", arguments: [
            "event_id": .string("refused-alarms"), "target_calendar": .string("Work")])
        XCTAssertEqual(result.isError, true)
        guard case let .text(text, _, _)? = result.content.first else { return XCTFail("no text content") }
        let expected = try XCTUnwrap(EventKitError.copyRefused(code: "eventkit_error_1", alarmKinds: ["location_alarms"]).errorDescription)
        XCTAssertTrue(text.contains(expected), text)
    }

    /// #260: the manager answers a reminder's id with not found instead of aborting
    /// (`EventLookup`); copy_event reports it as the call's error.
    func testCopyEventGivenAnIdThatIsNotAnEventReportsNotFound() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let result = await server.handleToolCallForTesting(name: "copy_event", arguments: [
            "event_id": .string("reminder-id"), "target_calendar": .string("Work")])
        XCTAssertEqual(result.isError, true)
        guard case let .text(text, _, _)? = result.content.first else { return XCTFail("no text content") }
        XCTAssertTrue(text.contains("Event not found: reminder-id"), text)
    }

    /// #260: in move_events_batch the not-found row fails on its own and the rows after it still
    /// run; before the fix the process aborted there with earlier rows already moved.
    func testMoveBatchReportsANotFoundRowAndMovesTheRest() async throws {
        let history = CalendarUndoManager()
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: history))
        let rows = try await move(server, ["event_ids": .array([.string("reminder-id"), .string("good")])])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true])
        XCTAssertEqual(rows[0]["error"] as? String, "Event not found: reminder-id")
        let recorded = await history.history()
        XCTAssertEqual(recorded.count, 1)
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

    private func copyMove(_ id: String) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let raw = try await server.executeToolCall(name: "copy_event", arguments: [
            "event_id": .string(id), "target_calendar": .string("Work"), "delete_original": .bool(true)])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testCopyEventMoveReportsWhetherTheIdentifierChanged() async throws {
        let result = try await copyMove("cross-account")
        XCTAssertEqual(result["action"] as? String, "moved")
        XCTAssertEqual(result["id_changed"] as? Bool, true)
    }

    /// Round 1 #11: the headline case — an in-place move keeps the identifier.
    func testCopyEventInPlaceMoveKeepsTheIdentifier() async throws {
        let result = try await copyMove("good")
        XCTAssertEqual(result["method"] as? String, "in_place")
        XCTAssertEqual(result["id_changed"] as? Bool, false)
        XCTAssertEqual(result["new_id"] as? String, "good")
    }

    /// Round 1 #2: a fallback copy through copy_event discloses what it did not keep.
    func testCopyEventFallbackCopyReportsMethodAndNotCarriedOver() async throws {
        let result = try await copyMove("fallback")
        XCTAssertEqual(result["method"] as? String, "copied")
        XCTAssertEqual(result["not_carried_over"] as? [String], ["structured_location"])
    }

    /// Round 2 #5: copy_event to the event's own calendar did nothing; say so.
    func testCopyEventMoveToTheCurrentCalendarReportsUnchanged() async throws {
        let result = try await copyMove("same-calendar")
        XCTAssertEqual(result["action"] as? String, "unchanged")
        XCTAssertEqual(result["method"] as? String, "unchanged")
        XCTAssertEqual(result["id_changed"] as? Bool, false)
    }

    /// Round 2 #3: non-string ids would shift occurrence_dates onto the wrong event.
    func testNonStringEventIdsAreRejected() async throws {
        let fake = CopyFake(history: CalendarUndoManager())
        let server = try await CheICalMCPServer(eventCopySource: fake)
        do {
            _ = try await move(server, ["event_ids": .array([.string("a"), .int(1), .string("b")]),
                                        "occurrence_dates": .array([.string("2026-10-21"), .string("2026-10-28")])])
            XCTFail("a non-string event id must be rejected")
        } catch {}
        let calls = await fake.moveCalls
        XCTAssertEqual(calls, [])
    }

    /// Round 1 #1: an event already in the target calendar is reported unchanged.
    func testMoveToTheCurrentCalendarIsReportedUnchanged() async throws {
        let server = try await CheICalMCPServer(eventCopySource: CopyFake(history: CalendarUndoManager()))
        let row = try await move(server, ["event_ids": .array([.string("same-calendar")])])[0]
        XCTAssertEqual(row["method"] as? String, "unchanged")
        XCTAssertEqual(row["id_changed"] as? Bool, false)
    }

    /// Round 1 #4: a date-only occurrence date is read in the event's own time zone, as
    /// delete_event does.
    func testDateOnlyOccurrenceDateUsesTheEventsTimeZone() async throws {
        let fake = CopyFake(history: CalendarUndoManager())
        let server = try await CheICalMCPServer(eventCopySource: fake)
        _ = try await move(server, ["event_ids": .array([.string("ny-series")]),
                                    "occurrence_dates": .array([.string("2026-10-21")])])
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let calls = await fake.moveCalls
        XCTAssertEqual(calls.first?.occurrenceDate, ny.date(from: DateComponents(year: 2026, month: 10, day: 21)))
    }

    /// Round 1 #10: a present but non-array occurrence_dates is rejected, not ignored.
    func testNonArrayOccurrenceDatesIsRejected() async throws {
        let fake = CopyFake(history: CalendarUndoManager())
        let server = try await CheICalMCPServer(eventCopySource: fake)
        do {
            _ = try await move(server, ["event_ids": .array([.string("a")]), "occurrence_dates": .string("2026-10-21")])
            XCTFail("a string occurrence_dates must be rejected")
        } catch {}
        let calls = await fake.moveCalls
        XCTAssertEqual(calls, [])
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
