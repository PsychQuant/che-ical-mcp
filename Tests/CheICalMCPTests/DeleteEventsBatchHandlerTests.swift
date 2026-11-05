import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// The date-range path of `delete_events_batch` behind `EventBatchDeletionSource` (#331): the fake
/// lists value events and records the delete calls, so the handler's response is read, not its
/// source. What lives inside `EventKitManager.deleteEventsBatch` (exact-slot lookup, when a span
/// "future" removal is recorded, `/RID=` identifiers, the count behind `already_removed`) is not
/// reachable from here; `FutureDeletionCoverageTests` and the device checks cover it.
private actor BatchDeletionFake: EventBatchDeletionSource {
    struct ListCall: Equatable { let start: Date; let end: Date; let calendarName: String?; let calendarSource: String? }
    struct DeleteCall: Equatable { let identifiers: [String]; let occurrenceDates: [Date?]; let span: EKSpan; let slots: [Date?]? }

    private let listed: [BatchDeletionListedEvent]
    private let result: BatchDeleteResult
    private(set) var listCalls: [ListCall] = []
    private(set) var deleteCalls: [DeleteCall] = []
    private(set) var seriesCalls: [[String]] = []
    /// `refusingOccurrenceIdentifiers` of each series call (#416).
    private(set) var seriesRefusals: [Bool] = []

    init(listed: [BatchDeletionListedEvent],
         result: BatchDeleteResult = BatchDeleteResult(successCount: 0, failedCount: 0, failures: [])) {
        self.listed = listed
        self.result = result
    }

    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent] {
        listCalls.append(ListCall(start: startDate, end: endDate, calendarName: calendarName, calendarSource: calendarSource))
        return listed
    }

    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult {
        deleteCalls.append(DeleteCall(identifiers: items.map(\.identifier), occurrenceDates: items.map(\.occurrenceDate),
                                      span: span, slots: slots))
        return result
    }

    func deleteEventSeriesBatch(identifiers: [String], refusingOccurrenceIdentifiers: Bool) async throws -> BatchDeleteResult {
        seriesCalls.append(identifiers)
        seriesRefusals.append(refusingOccurrenceIdentifiers)
        return result
    }

    var anyDelete: Bool { !deleteCalls.isEmpty || !seriesCalls.isEmpty }
}

final class DeleteEventsBatchHandlerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let base = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
    private let iso = ISO8601DateFormatter()

    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func call(_ fake: BatchDeletionFake, _ args: [String: Value]) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventBatchDeletionSource: fake)
        return try object(await server.executeToolCall(name: "delete_events_batch", arguments: args))
    }

    private func args(after: Date? = nil, before: Date? = nil, span: String = "this", dryRun: Bool) -> [String: Value] {
        var a: [String: Value] = ["calendar_name": .string("Work"), "span": .string(span), "dry_run": .bool(dryRun)]
        if let after { a["after_date"] = .string(iso.string(from: after)) }
        if let before { a["before_date"] = .string(iso.string(from: before)) }
        return a
    }

    /// A daily series of `count` occurrences sharing one identifier, slot = start.
    private func dailySeries(_ id: String, count: Int, from start: Date) -> [BatchDeletionListedEvent] {
        (0..<count).map { i in
            let s = start.addingTimeInterval(Double(i) * day)
            return BatchDeletionListedEvent(identifier: id, start: s, end: s.addingTimeInterval(3600), slot: s)
        }
    }

    /// `count` one-off events, each its own identifier.
    private func oneOffs(_ count: Int, from start: Date) -> [BatchDeletionListedEvent] {
        (0..<count).map { i in
            let s = start.addingTimeInterval(Double(i) * 3600)
            return BatchDeletionListedEvent(identifier: "one-\(i)", start: s, end: s.addingTimeInterval(600), slot: s)
        }
    }

    private func expectedSearched(after: Date?, before: Date?) throws -> (from: String, to: String) {
        let span = try XCTUnwrap(EventRangeQuery.deletionRange(after: after, before: before))
        return (EventRangeQuery.localText(span.start), EventRangeQuery.localText(span.end))
    }

    private func assertRefused(_ fake: BatchDeletionFake, _ args: [String: Value],
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let server = try await CheICalMCPServer(eventBatchDeletionSource: fake)
        do {
            _ = try await server.executeToolCall(name: "delete_events_batch", arguments: args)
            XCTFail("expected a refusal", file: file, line: line)
        } catch let error as EventRangeQuery.RangeError {
            guard case .tooManyToDelete = error else {
                return XCTFail("wrong refusal: \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Case 1: a two-bound range of at most 1461 days is not limited

    func testANarrowRangeIsNotLimitedAndPreviewsEveryRow() async throws {
        let before = base.addingTimeInterval(1000 * day)
        let fake = BatchDeletionFake(listed: oneOffs(2001, from: base))
        let r = try await call(fake, args(after: base, before: before, dryRun: true))

        XCTAssertEqual(r["total"] as? Int, 2001)
        XCTAssertEqual(r["deletions"] as? Int, 2001)
        XCTAssertEqual((r["events_to_delete"] as? [[String: Any]])?.count, 2001)
        XCTAssertNil(r["preview_truncated"])
        let searched = try expectedSearched(after: base, before: before)
        XCTAssertEqual(r["searched_from"] as? String, searched.from)
        XCTAssertEqual(r["searched_to"] as? String, searched.to)
        let calls = await fake.listCalls
        XCTAssertEqual(calls, [.init(start: base, end: before, calendarName: "Work", calendarSource: nil)])
    }

    // MARK: - Case 2: one-sided range, open-ended daily series, span "this"

    func testAOneSidedRangeOverTheCeilingIsRefusedOnBothPathsWithNothingDeleted() async throws {
        let series = dailySeries("S", count: 2001, from: base)
        for dryRun in [true, false] {
            let fake = BatchDeletionFake(listed: series)
            try await assertRefused(fake, args(after: base, dryRun: dryRun))
            let deleted = await fake.anyDelete
            XCTAssertFalse(deleted, "dry_run \(dryRun): nothing may be deleted")
        }
    }

    // MARK: - Cases 3 and 4: the same series with span "all" / "future" counts once

    func testSpanAllCountsTheSeriesOnceAndDeletesItWhole() async throws {
        let series = dailySeries("S", count: 2001, from: base)
        let dry = try await call(BatchDeletionFake(listed: series), args(after: base, span: "all", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 1)
        XCTAssertEqual(dry["total"] as? Int, 2001)
        XCTAssertEqual(dry["preview_truncated"] as? Bool, true, "a wide range previews at most 2000 rows")
        XCTAssertEqual((dry["events_to_delete"] as? [[String: Any]])?.count, 2000)

        let fake = BatchDeletionFake(listed: series, result: BatchDeleteResult(successCount: 1, failedCount: 0, failures: []))
        let real = try await call(fake, args(after: base, span: "all", dryRun: false))
        let seriesCalls = await fake.seriesCalls
        let deleteCalls = await fake.deleteCalls
        XCTAssertEqual(seriesCalls, [["S"]])
        XCTAssertTrue(deleteCalls.isEmpty)
        XCTAssertEqual(real["span"] as? String, "all")
        XCTAssertEqual(real["total"] as? Int, 1)
    }

    func testSpanFutureCountsTheSeriesOnceAndSendsEveryOccurrenceInSlotOrder() async throws {
        // Listed in start order; the second one was moved earlier than its slot, so slot order
        // differs from start order.
        let a = base, b = base.addingTimeInterval(day), c = base.addingTimeInterval(2 * day)
        let listed = [
            BatchDeletionListedEvent(identifier: "S", start: a, end: a.addingTimeInterval(3600), slot: b),
            BatchDeletionListedEvent(identifier: "S", start: b, end: b.addingTimeInterval(3600), slot: a),
            BatchDeletionListedEvent(identifier: "S", start: c, end: c.addingTimeInterval(3600), slot: c),
        ]
        let dry = try await call(BatchDeletionFake(listed: listed), args(after: base, span: "future", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 1)

        let fake = BatchDeletionFake(listed: listed, result: BatchDeleteResult(successCount: 1, failedCount: 0, failures: [], coveredCount: 2))
        let real = try await call(fake, args(after: base, span: "future", dryRun: false))
        let deleteCalls = await fake.deleteCalls
        XCTAssertEqual(deleteCalls, [.init(identifiers: ["S", "S", "S"], occurrenceDates: [b, a, c],
                                          span: .futureEvents, slots: [a, b, c])])
        XCTAssertEqual(real["already_removed"] as? Int, 2, "the batch result's coveredCount")
    }

    /// Case 4 in the Diagnosis's shape (PR #411 verify round 1): the same open-ended daily series of
    /// 2001 occurrences as case 2, one-sided, with span "future": one deletion, so the size check
    /// passes where span "this" is refused.
    func testSpanFutureOverTheOneSidedSeriesPassesTheSizeCheckWithOneDeletion() async throws {
        let series = dailySeries("S", count: 2001, from: base)
        let fake = BatchDeletionFake(listed: series)
        let dry = try await call(fake, args(after: base, span: "future", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 1)
        XCTAssertEqual(dry["total"] as? Int, 2001)
        let deleted = await fake.anyDelete
        XCTAssertFalse(deleted, "a dry run deletes nothing")
    }

    // MARK: - Case 5: wide range, one-off events, at and over the ceiling

    func testAWideRangeAllowsExactlyTheCeilingAndRefusesOneMore() async throws {
        let before = base.addingTimeInterval(1462 * day)
        let atCeiling = try await call(BatchDeletionFake(listed: oneOffs(2000, from: base)),
                                       args(after: base, before: before, dryRun: true))
        XCTAssertEqual(atCeiling["deletions"] as? Int, 2000)

        let over = BatchDeletionFake(listed: oneOffs(2001, from: base))
        try await assertRefused(over, args(after: base, before: before, dryRun: false))
        let deleted = await over.anyDelete
        XCTAssertFalse(deleted)
    }

    // MARK: - Case 7: only before_date reaches 100 years back, on both paths

    func testOnlyBeforeDateSearchesAHundredYearsBackOnBothPaths() async throws {
        let before = base
        let searched = try expectedSearched(after: nil, before: before)
        XCTAssertTrue(searched.from.hasPrefix("1925-") || searched.from.hasPrefix("1926-"), searched.from)
        for dryRun in [true, false] {
            let fake = BatchDeletionFake(listed: oneOffs(3, from: base.addingTimeInterval(-10 * day)))
            let r = try await call(fake, args(before: before, dryRun: dryRun))
            XCTAssertEqual(r["searched_from"] as? String, searched.from, "dry_run \(dryRun)")
            XCTAssertEqual(r["searched_to"] as? String, searched.to, "dry_run \(dryRun)")
            let list = await fake.listCalls.first
            XCTAssertEqual(list?.end, before)
            XCTAssertEqual(list.map { before.timeIntervalSince($0.start) / (365.2425 * day) } ?? 0, 100, accuracy: 0.1)
        }
    }

    // MARK: - Case 8: the real deletion's response

    func testTheRealDeletionReportsModeCalendarRangeAndFailures() async throws {
        let before = base.addingTimeInterval(30 * day)
        let result = BatchDeleteResult(successCount: 2, failedCount: 1, failures: [(identifier: "one-1", error: "Event not found")])
        let fake = BatchDeletionFake(listed: oneOffs(3, from: base), result: result)
        let r = try await call(fake, args(after: base, before: before, dryRun: false))

        XCTAssertEqual(r["dry_run"] as? Bool, false)
        XCTAssertEqual(r["mode"] as? String, "by_date_range")
        XCTAssertEqual(r["calendar"] as? String, "Work")
        let searched = try expectedSearched(after: base, before: before)
        XCTAssertEqual(r["searched_from"] as? String, searched.from)
        XCTAssertEqual(r["searched_to"] as? String, searched.to)
        XCTAssertEqual(r["total"] as? Int, 3)
        XCTAssertEqual(r["succeeded"] as? Int, 2)
        XCTAssertEqual(r["failed"] as? Int, 1)
        XCTAssertNil(r["already_removed"], "only reported when an earlier removal covered items")
        let failures = try XCTUnwrap(r["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.first?["event_id"] as? String, "one-1")
        XCTAssertEqual(failures.first?["error"] as? String, "Event not found", "the failure's error is passed through")
        let calls = await fake.deleteCalls
        XCTAssertEqual(calls.first?.span, .thisEvent)
        XCTAssertEqual(calls.first?.identifiers, ["one-0", "one-1", "one-2"])
    }

    // MARK: - Case 9: events without an identifier are neither sent nor counted

    func testEventsWithoutAnIdentifierAreNotSentOrCounted() async throws {
        let before = base.addingTimeInterval(10 * day)
        let s = base.addingTimeInterval(day)
        let listed = oneOffs(2, from: base) + [BatchDeletionListedEvent(identifier: nil, start: s, end: s, slot: s)]
        let dry = try await call(BatchDeletionFake(listed: listed), args(after: base, before: before, dryRun: true))
        XCTAssertEqual(dry["total"] as? Int, 3, "the preview lists every listed event")
        XCTAssertEqual(dry["deletions"] as? Int, 2)
        let rows = try XCTUnwrap(dry["events_to_delete"] as? [[String: Any]])
        XCTAssertEqual(rows.last?["event_id"] as? String, "", "an event without an identifier previews an empty id, as before")

        let fake = BatchDeletionFake(listed: listed)
        _ = try await call(fake, args(after: base, before: before, dryRun: false))
        let calls = await fake.deleteCalls
        XCTAssertEqual(calls.first?.identifiers, ["one-0", "one-1"])
    }

    // MARK: - #416: span all through an occurrence's own id

    /// With `event_ids` the caller names what to delete, so an id of one occurrence edited on its
    /// own is refused for span all (it would delete that occurrence only). By date range the
    /// listing, not the caller, put that id in the set: no refusal there.
    func testEventIdsSpanAllRefusesOccurrenceIdentifiersAndTheRangeDoesNot() async throws {
        let byIds = BatchDeletionFake(listed: [])
        _ = try await call(byIds, ["event_ids": .array([.string("S"), .string("S/RID=1")]), "span": .string("all"),
                                   "dry_run": .bool(false)])
        let byIdsRefusals = await byIds.seriesRefusals
        XCTAssertEqual(byIdsRefusals, [true])

        let range = BatchDeletionFake(listed: dailySeries("S", count: 3, from: base))
        _ = try await call(range, args(after: base, before: base.addingTimeInterval(10 * day), span: "all", dryRun: false))
        let rangeRefusals = await range.seriesRefusals
        XCTAssertEqual(rangeRefusals, [false])
    }
}
