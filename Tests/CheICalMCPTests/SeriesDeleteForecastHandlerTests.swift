import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #539 step 6: where the forecast of a whole-series delete reaches the caller, through the two
/// deletion seams (`EventDeletionSource`, `EventBatchDeletionSource`). The count comes from the fakes;
/// how the manager computes it is `SeriesDeleteForecastTests` and `SeriesDeleteForecastWiringTests`.
/// The note never replaces the `undo_note` of #436 or #452: in `delete_event` the routes exclude each
/// other, and in `delete_events_batch` the forecast is per row while those notes are top-level (the
/// real call) or on rows the forecast is not asked for (the dry run).
private actor ForecastDeletes: EventDeletionSource {
    let route: SeriesDeleteRoute
    let unplacedEdits: Int
    init(route: SeriesDeleteRoute = .series(unplacedEdits: 0), unplacedEdits: Int = 0) {
        self.route = route
        self.unplacedEdits = unplacedEdits
    }
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { TimeZone(identifier: "UTC") }
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws -> Int { unplacedEdits }
    func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute { route }
}

private actor ForecastBatch: EventBatchDeletionSource {
    private let listed: [BatchDeletionListedEvent]
    private let result: BatchDeleteResult
    private let rows: [String: BatchDeletionPreviewRow]
    private let forecasts: [String: Int]
    private(set) var forecastAsks: [String] = []

    init(listed: [BatchDeletionListedEvent] = [], result: BatchDeleteResult = BatchDeleteResult(successCount: 0, failedCount: 0, failures: []),
         rows: [String: BatchDeletionPreviewRow] = [:], forecasts: [String: Int] = [:]) {
        self.listed = listed
        self.result = result
        self.rows = rows
        self.forecasts = forecasts
    }

    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent] { listed }
    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult { result }
    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult { result }
    func previewEventDeletion(identifier: String, span: EKSpan, spanAll: Bool, namedInTheCall: Set<String>,
                              goneInTheCall: Set<String>) async throws -> BatchDeletionPreviewRow {
        rows[identifier] ?? .deletes(start: Date(timeIntervalSinceReferenceDate: 0), end: Date(timeIntervalSinceReferenceDate: 3600))
    }
    func previewUndoForecast(identifier: String, goneInTheCall: Set<String>) async -> Int {
        forecastAsks.append(identifier)
        return forecasts[identifier] ?? 0
    }
}

final class SeriesDeleteForecastHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func deleteEvent(_ fake: ForecastDeletes, _ args: [String: Value]) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventDeletionSource: fake)
        return try object(await server.executeToolCall(name: "delete_event", arguments: args))
    }

    private func batch(_ fake: ForecastBatch, _ args: [String: Value]) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventBatchDeletionSource: fake)
        return try object(await server.executeToolCall(name: "delete_events_batch", arguments: args))
    }

    private func rows(_ response: [String: Any], _ key: String = "events_to_delete") throws -> [[String: Any]] {
        try XCTUnwrap(response[key] as? [[String: Any]], "\(key) in \(response)")
    }

    private func daily(_ id: String, count: Int) -> [BatchDeletionListedEvent] {
        (0..<count).map { i in
            let start = Date(timeIntervalSinceReferenceDate: 820_000_000 + Double(i) * 86_400)
            return BatchDeletionListedEvent(identifier: id, start: start, end: start.addingTimeInterval(3600), slot: start)
        }
    }

    private var range: [String: Value] {
        ["calendar_name": .string("Work"), "after_date": .string("2026-12-20T00:00:00Z"), "before_date": .string("2027-01-20T00:00:00Z")]
    }

    // MARK: - delete_event

    func testSpanAllWritesTheNoteWhenAnEditCannotBePlaced() async throws {
        let answer = try await deleteEvent(ForecastDeletes(route: .series(unplacedEdits: 2)), ["event_id": .string("S"), "span": .string("all")])
        XCTAssertEqual(answer["undo_note"] as? String, CheICalMCPServer.rulesAloneUndoNote(unplacedEdits: 2))
        XCTAssertNil(answer["occurrence_id"])
        XCTAssertEqual(answer["action"] as? String, "deleted", "the delete is not refused")
    }

    func testSpanAllWithEveryEditPlacedHasNoNote() async throws {
        let answer = try await deleteEvent(ForecastDeletes(route: .series(unplacedEdits: 0)), ["event_id": .string("S"), "span": .string("all")])
        XCTAssertNil(answer["undo_note"])
    }

    /// #436's route keeps its own note: it records no whole-series delete, so there is no forecast.
    func testSpanAllThroughTheFirstEditedOccurrenceKeepsItsOwnNote() async throws {
        let answer = try await deleteEvent(ForecastDeletes(route: .firstEditedOccurrence(id: "S/RID=1")), ["event_id": .string("S"), "span": .string("all")])
        XCTAssertEqual(answer["undo_note"] as? String, CheICalMCPServer.seriesDeletedThroughOccurrenceNote)
        XCTAssertEqual(answer["occurrence_id"] as? String, "S/RID=1")
    }

    func testSpanFutureFromTheFirstOccurrenceWritesTheNote() async throws {
        let args: [String: Value] = ["event_id": .string("S"), "span": .string("future"), "occurrence_date": .string("2027-02-11")]
        let noted = try await deleteEvent(ForecastDeletes(unplacedEdits: 1), args)
        XCTAssertEqual(noted["undo_note"] as? String, CheICalMCPServer.rulesAloneUndoNote(unplacedEdits: 1))
        XCTAssertEqual(noted["span"] as? String, "future")
        let plain = try await deleteEvent(ForecastDeletes(unplacedEdits: 0), args)
        XCTAssertNil(plain["undo_note"])
    }

    // MARK: - delete_events_batch, the real call

    /// The forecast is a row of `rules_alone_on_undo`; #436's top-level `undo_note` is left as it is.
    func testTheRealCallListsTheForecastPerRowBesideTheTopLevelNote() async throws {
        var result = BatchDeleteResult(successCount: 2, failedCount: 0, failures: [], throughFirstOccurrence: [(identifier: "T", occurrenceID: "T/RID=1")])
        result.rulesAloneOnUndo = [.init(identifier: "S", unplacedEdits: 1)]
        let answer = try await batch(ForecastBatch(result: result),
                                     ["event_ids": .array([.string("S"), .string("T")]), "span": .string("all"), "dry_run": .bool(false)])
        XCTAssertEqual(answer["undo_note"] as? String, CheICalMCPServer.batchSeriesDeletedThroughOccurrenceNote)
        let forecast = try rows(answer, "rules_alone_on_undo")
        XCTAssertEqual(forecast.count, 1)
        XCTAssertEqual(forecast.first?["event_id"] as? String, "S")
        XCTAssertEqual(forecast.first?["undo_note"] as? String, CheICalMCPServer.rulesAloneUndoNote(unplacedEdits: 1))
    }

    func testTheRealCallWithoutAForecastHasNoForecastRows() async throws {
        let answer = try await batch(ForecastBatch(result: BatchDeleteResult(successCount: 1, failedCount: 0, failures: [])),
                                     ["event_ids": .array([.string("S")]), "span": .string("all"), "dry_run": .bool(false)])
        XCTAssertNil(answer["rules_alone_on_undo"])
    }

    /// A span future row that removed a whole series (by date range) is listed the same way.
    func testTheRealSpanFutureCallListsTheForecast() async throws {
        var result = BatchDeleteResult(successCount: 1, failedCount: 0, failures: [])
        result.rulesAloneOnUndo = [.init(identifier: "S", unplacedEdits: 3)]
        var args = range
        args["span"] = .string("future"); args["dry_run"] = .bool(false)
        let answer = try await batch(ForecastBatch(listed: daily("S", count: 3), result: result), args)
        let forecast = try rows(answer, "rules_alone_on_undo")
        XCTAssertEqual(forecast.first?["undo_note"] as? String, CheICalMCPServer.rulesAloneUndoNote(unplacedEdits: 3))
        XCTAssertNil(answer["undo_note"])
    }

    /// No row qualifies: the key is absent, not an empty list, with span future too.
    func testTheRealSpanFutureCallWithoutAForecastHasNoForecastRows() async throws {
        var args = range
        args["span"] = .string("future"); args["dry_run"] = .bool(false)
        let answer = try await batch(ForecastBatch(listed: daily("S", count: 3), result: BatchDeleteResult(successCount: 1, failedCount: 0, failures: [])), args)
        XCTAssertNil(answer["rules_alone_on_undo"])
        XCTAssertEqual(answer["succeeded"] as? Int, 1)
    }

    // MARK: - delete_events_batch, the dry run

    func testTheDryRunWithSpanAllWritesTheNoteInTheSeriesRow() async throws {
        let fake = ForecastBatch(forecasts: ["S": 2])
        let answer = try await batch(fake, ["event_ids": .array([.string("S"), .string("U")]), "span": .string("all"), "dry_run": .bool(true)])
        let preview = try rows(answer)
        XCTAssertEqual(preview.first { $0["event_id"] as? String == "S" }?["undo_note"] as? String,
                       CheICalMCPServer.batchPreviewRulesAloneNote(unplacedEdits: 2))
        XCTAssertNil(preview.first { $0["event_id"] as? String == "U" }?["undo_note"])
        let asked = await fake.forecastAsks
        XCTAssertEqual(asked, ["S", "U"])
    }

    /// The three row-level notes exclude each other: a row through the first occurrence (#436) and an
    /// occurrence's own row with span future (#452) keep theirs, and the forecast is not asked for them.
    func testTheDryRunAsksTheForecastOnlyForARowThatDeletesWithSpanAll() async throws {
        let through = ForecastBatch(rows: ["S": .deletesThroughFirstOccurrence(start: Date(timeIntervalSinceReferenceDate: 0),
                                                                                 end: Date(timeIntervalSinceReferenceDate: 3600), occurrenceID: "S/RID=1")],
                                    forecasts: ["S": 2])
        let throughRows = try rows(try await batch(through, ["event_ids": .array([.string("S")]), "span": .string("all"), "dry_run": .bool(true)]))
        XCTAssertEqual(throughRows.first?["undo_note"] as? String, CheICalMCPServer.batchPreviewThroughOccurrenceNote)
        let throughAsks = await through.forecastAsks
        XCTAssertEqual(throughAsks, [])

        let following = ForecastBatch(forecasts: ["S/RID=5": 2])
        let followingRows = try rows(try await batch(following, ["event_ids": .array([.string("S/RID=5")]), "span": .string("future"), "dry_run": .bool(true)]))
        XCTAssertEqual(followingRows.first?["undo_note"] as? String, CheICalMCPServer.batchPreviewFollowingOccurrencesNote)
        let followingAsks = await following.forecastAsks
        XCTAssertEqual(followingAsks, [])
    }

    /// By date range with span all every listed occurrence of the series shows its row's answer.
    func testTheDryRunByDateRangeWithSpanAllCarriesTheNote() async throws {
        var args = range
        args["span"] = .string("all"); args["dry_run"] = .bool(true)
        let preview = try rows(try await batch(ForecastBatch(listed: daily("S", count: 3), forecasts: ["S": 1]), args))
        XCTAssertEqual(preview.count, 3)
        for row in preview {
            XCTAssertEqual(row["undo_note"] as? String, CheICalMCPServer.batchPreviewRulesAloneNote(unplacedEdits: 1))
        }
    }

    /// By date range with span future the dry run does not forecast: another row of the call can make
    /// its undo refuse, which the dry run cannot tell (the real call can, `RulesAloneForecast`).
    func testTheDryRunByDateRangeWithSpanFutureDoesNotForecast() async throws {
        var args = range
        args["span"] = .string("future"); args["dry_run"] = .bool(true)
        let fake = ForecastBatch(listed: daily("S", count: 3), forecasts: ["S": 1])
        let preview = try rows(try await batch(fake, args))
        XCTAssertTrue(preview.allSatisfy { $0["undo_note"] == nil })
        let asked = await fake.forecastAsks
        XCTAssertEqual(asked, [])
    }
}
