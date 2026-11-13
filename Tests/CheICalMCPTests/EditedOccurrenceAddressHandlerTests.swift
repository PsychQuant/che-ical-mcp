import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #532, #534: what the handlers do with the refusals. The manager is behind the seams, so the
/// fakes throw what `EventKitManager` throws; each reason is built by the production builder
/// (`EditedOccurrenceAddress.reason`).
///
/// What these tests show, and no more: the handler hands the manager the span and the occurrence
/// date of the call (the fakes record them, so a handler that dropped span `future` goes red), a
/// trusted reason reaches the caller unchanged, and nothing is written to stderr for it. They do
/// not show that the manager finds an edited occurrence or builds the right text for a span: no
/// seam reaches the event store. That is held by the pure tests (`EditedOccurrenceAddressTests`),
/// the wiring pins (`EditedOccurrenceAddressWiringTests`) and the device cells of the release gate.
/// The two #534 tests at the end likewise show only that the conflict error the manager throws
/// reaches the caller as an error and not as `skipped`, which was so before #534 for the lookup's
/// conflict; the fix itself (which dates count as still present) is in the pure tests and the pins.
private let taipei = TimeZone(identifier: "Asia/Taipei")!
private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private let occurrenceID = "6F2A:9B1C/RID=\(Int(instant("2026-12-21T10:00:00+08:00").timeIntervalSinceReferenceDate))"
private func reason(_ call: EditedOccurrenceAddress.Call) -> String {
    let match = EditedOccurrenceAddress.Match(identifier: occurrenceID, start: instant("2026-12-21T10:00:00+08:00"), isAllDay: false,
                                              kind: .shownThatDay, originalDay: "2026-12-21")
    let request = EditedOccurrenceAddress.Request(seriesID: "6F2A:9B1C", seriesIsAllDay: false, seriesZone: taipei,
                                                  seriesStart: instant("2026-12-07T10:00:00+08:00"),
                                                  requested: instant("2026-12-21T00:00:00+08:00"), host: taipei)
    return EditedOccurrenceAddress.reason(for: call, matches: [match], request: request)
}
/// An error that is not a trusted message: the handlers log it to stderr and answer a code.
private let untrusted = NSError(domain: EKErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "framework text"])
private let conflict = EventKitError.exclusionEditedOccurrence(existingId: "6F2A:9B1C", date: "2026-09-21")
/// What a fake was called with.
private struct Asked: Equatable {
    let identifier: String
    let span: String
    let occurrenceDate: Date?
}
private func name(_ span: EKSpan) -> String { span == .futureEvents ? "future" : "this" }

private actor RefusingWrites: EventWriteSource {
    let updateError: Error
    private(set) var created: [String] = []
    private(set) var asked: [Asked] = []
    init(updateError: Error) { self.updateError = updateError }
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        asked.append(Asked(identifier: request.identifier, span: request.applyToAll ? "all" : name(request.span), occurrenceDate: request.occurrenceDate))
        throw updateError
    }
    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        // The existing series still has an occurrence on an excluded date (#534).
        if request.title == "retry" { throw conflict }
        created.append(request.title)
        return EventCreateValue(event: EventWriteValue(eventIdentifier: "created-\(created.count)", title: request.title, isAllDay: false,
                                                       startDate: request.startDate, endDate: request.endDate), isDuplicate: false)
    }
    func similarEventValues(title: String, limit: Int) async throws -> [SimilarEventValue] { [] }
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { taipei }
}

private actor RefusingDeletes: EventDeletionSource {
    let error: Error
    private(set) var asked: [Asked] = []
    init(error: Error) { self.error = error }
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { taipei }
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws {
        asked.append(Asked(identifier: identifier, span: name(span), occurrenceDate: occurrenceDate))
        throw error
    }
    func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute { .series }
}

private actor RefusingMoves: EventCopySource {
    let error: Error
    private(set) var moved: [String] = []
    private(set) var asked: [Asked] = []
    init(error: Error) { self.error = error }
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        EventCopyValue(eventIdentifier: "copy", title: identifier)
    }
    func eventTimeZone(identifier: String) async throws -> TimeZone? { taipei }
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue {
        asked.append(Asked(identifier: identifier, span: span == .this ? "this" : "all", occurrenceDate: occurrenceDate))
        if identifier == "6F2A:9B1C" { throw error }
        moved.append(identifier)
        return EventMoveValue(result: .init(method: .inPlace, eventIdentifier: identifier, notCarriedOver: []), title: identifier)
    }
}

final class EditedOccurrenceAddressHandlerTests: XCTestCase {
    /// The text of a result. A result with no text fails the test: a skip would pass it unread.
    private func text(_ result: CallTool.Result, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case let .text(text, _, _)? = result.content.first else {
            XCTFail("the result has no text content", file: file, line: line)
            return ""
        }
        return text
    }
    /// The requested day as the handler parses `occurrence_date` in the zone the fakes answer.
    private let requestedDay = instant("2026-12-21T00:00:00+08:00")

    private let dated: [String: Value] = ["event_id": .string("6F2A:9B1C"), "occurrence_date": .string("2026-12-21")]

    // spec-example: edited-occurrence-addressing / Stderr stays empty
    func testUpdateEventAnswersTheReasonUnchangedAndWritesNothingToStderr() async throws {
        for (span, call) in [("this", EditedOccurrenceAddress.Call.update(futureSpan: false)), ("future", .update(futureSpan: true))] {
            let expected = reason(call)
            XCTAssertTrue(expected.contains("Its identifier is \(occurrenceID)"), expected)
            let fake = RefusingWrites(updateError: EventKitError.occurrenceAddressRefused(reason: expected))
            let server = try await CheICalMCPServer(eventWriteSource: fake)
            var arguments = dated
            arguments["span"] = .string(span)
            arguments["title"] = .string("New title")
            let (result, stderr) = await withCapturedStderrAsync { await server.handleToolCallForTesting(name: "update_event", arguments: arguments) }
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(text(result), "Error: \(expected)")
            XCTAssertEqual(stderr, "", "a trusted reason is not logged, so the identifier does not reach stderr")
            // The span and the day of the call reach the manager, which picks the text by them.
            let asked = await fake.asked
            XCTAssertEqual(asked, [Asked(identifier: "6F2A:9B1C", span: span, occurrenceDate: requestedDay)])
        }
    }

    func testDeleteEventAnswersTheReasonUnchangedAndWritesNothingToStderr() async throws {
        for (span, call) in [("this", EditedOccurrenceAddress.Call.delete(futureSpan: false)), ("future", .delete(futureSpan: true))] {
            let expected = reason(call)
            XCTAssertTrue(expected.hasSuffix("Nothing was deleted."), expected)
            let fake = RefusingDeletes(error: EventKitError.occurrenceAddressRefused(reason: expected))
            let server = try await CheICalMCPServer(eventDeletionSource: fake)
            var arguments = dated
            arguments["span"] = .string(span)
            let (result, stderr) = await withCapturedStderrAsync { await server.handleToolCallForTesting(name: "delete_event", arguments: arguments) }
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(text(result), "Error: \(expected)")
            XCTAssertEqual(stderr, "")
            let asked = await fake.asked
            XCTAssertEqual(asked, [Asked(identifier: "6F2A:9B1C", span: span, occurrenceDate: requestedDay)])
        }
    }

    func testAMoveRowCarriesTheReasonTheOtherRowsGoOnAndNothingIsWrittenToStderr() async throws {
        let expected = reason(.moveRow)
        XCTAssertTrue(expected.contains("pass it in event_ids"), expected)
        let fake = RefusingMoves(error: EventKitError.moveRefused(reason: expected))
        let server = try await CheICalMCPServer(eventCopySource: fake)
        let arguments: [String: Value] = ["target_calendar": .string("Work"), "event_ids": .array([.string("6F2A:9B1C"), .string("one-off")]),
                                          "occurrence_dates": .array([.string("2026-12-21"), .null])]
        let (result, stderr) = await withCapturedStderrAsync { await server.handleToolCallForTesting(name: "move_events_batch", arguments: arguments) }
        XCTAssertNotEqual(result.isError, true)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true])
        XCTAssertEqual(rows[0]["error"] as? String, expected)
        let moved = await fake.moved
        XCTAssertEqual(moved, ["one-off"])
        XCTAssertEqual(stderr, "")
        // Each row reaches the manager with its own date, and with span this.
        let asked = await fake.asked
        XCTAssertEqual(asked, [Asked(identifier: "6F2A:9B1C", span: "this", occurrenceDate: requestedDay),
                               Asked(identifier: "one-off", span: "this", occurrenceDate: nil)])
    }

    /// The positive control of the three tests above: through the same calls and the same capture,
    /// an error that is not a trusted message writes its line. Without this, an empty capture could
    /// also mean that nothing was captured.
    func testAnUntrustedErrorWritesOneLineThroughTheSameCapture() async throws {
        let update = try await CheICalMCPServer(eventWriteSource: RefusingWrites(updateError: untrusted))
        var arguments = dated
        arguments["title"] = .string("New title")
        let (updated, updateLog) = await withCapturedStderrAsync { await update.handleToolCallForTesting(name: "update_event", arguments: arguments) }
        XCTAssertEqual(text(updated), "Error: eventkit_error_4")
        XCTAssertEqual(updateLog.split(separator: "\n").count, 1, updateLog)
        XCTAssertTrue(updateLog.contains("update_event"), updateLog)

        let delete = try await CheICalMCPServer(eventDeletionSource: RefusingDeletes(error: untrusted))
        let (_, deleteLog) = await withCapturedStderrAsync { await delete.handleToolCallForTesting(name: "delete_event", arguments: dated) }
        XCTAssertEqual(deleteLog.split(separator: "\n").count, 1, deleteLog)

        let move = try await CheICalMCPServer(eventCopySource: RefusingMoves(error: untrusted))
        let (_, moveLog) = await withCapturedStderrAsync {
            await move.handleToolCallForTesting(name: "move_events_batch", arguments: [
                "target_calendar": .string("Work"), "event_ids": .array([.string("6F2A:9B1C")]), "occurrence_dates": .array([.string("2026-12-21")])])
        }
        XCTAssertEqual(moveLog.split(separator: "\n").count, 1, moveLog)
        XCTAssertTrue(moveLog.contains("moveEventsBatch"), moveLog)
    }

    // MARK: - #534

    private func item(_ title: String) -> Value {
        .object(["title": .string(title), "calendar_name": .string("Work"), "start_time": .string("2026-09-07T10:00:00+08:00"),
                 "end_time": .string("2026-09-07T11:00:00+08:00"),
                 "recurrence": .object(["frequency": .string("weekly"), "occurrence_count": .int(5),
                                        "excluded_occurrence_dates": .array([.string("2026-09-21")])])])
    }

    /// The conflict the manager throws when an excluded date still holds an occurrence reaches the
    /// caller as the error, not as `skipped`.
    func testCreateEventAnswersTheConflictNotSkipped() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: RefusingWrites(updateError: untrusted))
        guard case .object(let arguments) = item("retry") else { return XCTFail("item") }
        let result = await server.handleToolCallForTesting(name: "create_event", arguments: arguments)
        XCTAssertEqual(result.isError, true)
        let answer = text(result)
        XCTAssertEqual(answer, "Error: \(try XCTUnwrap(conflict.errorDescription))")
        XCTAssertTrue(answer.contains("an occurrence of it that was edited on its own starts on 2026-09-21"), answer)
        XCTAssertFalse(answer.contains("skipped"), answer)
    }

    func testACreateEventsBatchRowAnswersTheConflictAndTheOtherRowIsCreated() async throws {
        let fake = RefusingWrites(updateError: untrusted)
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        let raw = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array([item("retry"), item("fresh")])])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true])
        XCTAssertEqual(rows[0]["error"] as? String, conflict.errorDescription)
        XCTAssertNil(rows[0]["skipped"])
        let created = await fake.created
        XCTAssertEqual(created, ["fresh"])
    }
}
