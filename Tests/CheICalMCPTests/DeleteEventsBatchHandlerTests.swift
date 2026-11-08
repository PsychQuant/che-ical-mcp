import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// The date-range path of `delete_events_batch` behind `EventBatchDeletionSource` (#331): the fake
/// lists value events and records the delete calls, so the handler's response is read, not its
/// source. What lives inside `EventKitManager.deleteEventsBatch` (exact-slot lookup, when a span
/// "future" removal is recorded, `/RID=` identifiers, the count behind `already_removed`) is not
/// reachable from here; `FutureDeletionCoverageTests` and the device checks cover it.
/// `SeriesModel` below is the other double: one series as data, for the `event_ids` rows.
private actor BatchDeletionFake: EventBatchDeletionSource {
    struct ListCall: Equatable { let start: Date; let end: Date; let calendarName: String?; let calendarSource: String? }
    struct DeleteCall: Equatable { let identifiers: [String]; let occurrenceDates: [Date?]; let span: EKSpan; let slots: [Date?]? }

    private let listed: [BatchDeletionListedEvent]
    private let result: BatchDeleteResult
    /// #332: what the listing throws (the read bound), if anything.
    private let listError: Error?
    private(set) var listCalls: [ListCall] = []
    private(set) var deleteCalls: [DeleteCall] = []
    private(set) var seriesCalls: [[String]] = []

    /// What every `event_ids` dry-run row answers (PR #465 verify r2).
    private let previewRow: BatchDeletionPreviewRow

    init(listed: [BatchDeletionListedEvent],
         result: BatchDeleteResult = BatchDeleteResult(successCount: 0, failedCount: 0, failures: []),
         listError: Error? = nil,
         previewRow: BatchDeletionPreviewRow = .deletes(start: Date(timeIntervalSinceReferenceDate: 0), end: Date(timeIntervalSinceReferenceDate: 0))) {
        self.listed = listed
        self.result = result
        self.listError = listError
        self.previewRow = previewRow
    }

    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent] {
        listCalls.append(ListCall(start: startDate, end: endDate, calendarName: calendarName, calendarSource: calendarSource))
        if let listError { throw listError }
        return listed
    }

    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult {
        deleteCalls.append(DeleteCall(identifiers: items.map(\.identifier), occurrenceDates: items.map(\.occurrenceDate),
                                      span: span, slots: slots))
        return result
    }

    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {
        seriesCalls.append(identifiers)
        return result
    }

    func previewEventDeletion(identifier: String, span: EKSpan, spanAll: Bool, namedInTheCall: Set<String>,
                              goneInTheCall: Set<String>) async throws -> BatchDeletionPreviewRow {
        previewRow
    }

    var anyDelete: Bool { !deleteCalls.isEmpty || !seriesCalls.isEmpty }
}

/// #416: one series held as data. The dry run and the real call each walk the rows through the
/// rules the manager uses (`FirstRemainingOccurrence.pick`, `DetachedOccurrenceSpan`), over what is
/// left when the row is reached, so a test compares the two answers instead of scripting them. The
/// first slot is taken out of the series (deleted, or edited at its original start), so the bare id
/// reaches the series through the stand-in, as on iCloud (#326, #428).
private actor SeriesModel: EventBatchDeletionSource {
    private let series: String
    private var occurrences: [FirstRemainingOccurrence.Candidate]
    private let listed: [BatchDeletionListedEvent]
    /// false: an open-ended series, where the scan cannot show it ends (#427 cluster verify).
    private let coversWholeSeries: Bool

    init(series: String, occurrences: [FirstRemainingOccurrence.Candidate], listed: [BatchDeletionListedEvent] = [],
         coversWholeSeries: Bool = true) {
        self.series = series
        self.occurrences = occurrences
        self.listed = listed
        self.coversWholeSeries = coversWholeSeries
    }

    var left: Int { occurrences.count }

    /// nil when the row goes ahead; a refusal; or a throw, as the bare id's edited-before refusal.
    private func judge(_ id: String, named: Set<String>, gone: Set<String>) throws -> String? {
        guard id != series else {
            let left = occurrences.filter { !gone.contains($0.eventIdentifier ?? "") }
            guard FirstRemainingOccurrence.pick(occurrences, identifier: series, goneInTheCall: gone) != nil
                    || FirstRemainingOccurrence.earliestEdited(left, identifier: series) != nil else {
                throw EventKitError.standInRefused(reason: EventKitManager.standInEditedBeforeBatchReason)
            }
            return nil
        }
        guard let own = occurrences.first(where: { $0.eventIdentifier == id }) else {
            throw EventKitError.eventNotFound(identifier: id)
        }
        return DetachedOccurrenceSpan.seriesDeleteRefusal(
            identifier: id, isDetached: own.isDetached, batch: true,
            neighbours: DetachedOccurrenceSpan.neighbours(of: id, slot: own.slot ?? own.start, among: occurrences,
                                                          coversWholeSeries: coversWholeSeries, namedInTheCall: named))
    }

    func previewEventDeletion(identifier: String, span: EKSpan, spanAll: Bool, namedInTheCall: Set<String>,
                              goneInTheCall: Set<String>) async throws -> BatchDeletionPreviewRow {
        if !spanAll {
            if let refusal = try judgeOneRow(identifier, span: span) { return .refused(refusal) }
        } else if let refusal = try judge(identifier, named: namedInTheCall, gone: goneInTheCall) {
            return .refused(refusal)
        }
        return .deletes(start: Date(timeIntervalSinceReferenceDate: 0), end: Date(timeIntervalSinceReferenceDate: 3600))
    }

    /// A row with span `this` or `future`: the edited-before refusal only with span `future`, and a
    /// bare recurring id has no date to go with, as by `event_ids` none is passed.
    private func judgeOneRow(_ id: String, span: EKSpan) throws -> String? {
        guard id == series else { return nil }
        guard FirstRemainingOccurrence.pick(occurrences, identifier: series,
                                            refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span)) != nil else {
            throw EventKitError.standInRefused(reason: EventKitManager.standInEditedBeforeBatchReason)
        }
        return EventKitManager.batchOccurrenceDateRequired
    }

    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {
        var succeeded = 0
        var failures: [(String, String)] = []
        for id in identifiers {
            do {
                if let refusal = try judge(id, named: Set(identifiers), gone: []) {
                    failures.append((id, refusal))
                    continue
                }
                // The series' row takes what is left, edited occurrences included (#436: measured).
                occurrences.removeAll { id == series || $0.eventIdentifier == id }
                succeeded += 1
            } catch {
                failures.append((id, "refused"))
            }
        }
        return BatchDeleteResult(successCount: succeeded, failedCount: failures.count, failures: failures)
    }

    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent] { listed }

    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult {
        var succeeded = 0
        var failures: [(String, String)] = []
        for item in items {
            do {
                if let reason = try judgeOneRow(item.identifier, span: span) {
                    failures.append((item.identifier, reason))
                    continue
                }
                occurrences.removeAll { $0.eventIdentifier == item.identifier }
                succeeded += 1
            } catch {
                failures.append((item.identifier, "refused"))
            }
        }
        return BatchDeleteResult(successCount: succeeded, failedCount: failures.count, failures: failures)
    }
}

final class DeleteEventsBatchHandlerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let base = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
    private let iso = ISO8601DateFormatter()

    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func call(_ fake: any EventBatchDeletionSource, _ args: [String: Value]) async throws -> [String: Any] {
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

    // MARK: - Case 1: a two-bound range of at most 1462 days is not limited

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

    /// #436 (PR #465 verify r1): a series row deleted from its first occurrence edited on its own
    /// cannot be undone, so the response names it and says the call's undo leaves it out.
    func testARowThroughTheFirstOccurrenceIsReportedWithItsUndoNote() async throws {
        var result = BatchDeleteResult(successCount: 2, failedCount: 0, failures: [])
        result.throughFirstOccurrence = [(identifier: "S1", occurrenceID: "S1/RID=1")]
        let fake = BatchDeletionFake(listed: [], result: result)
        let real = try await call(fake, ["event_ids": .array([.string("S1"), .string("S2")]), "span": .string("all"),
                                         "dry_run": .bool(false)])
        let rows = try XCTUnwrap(real["through_first_occurrence"] as? [[String: String]])
        XCTAssertEqual(rows, [["event_id": "S1", "occurrence_id": "S1/RID=1"]])
        XCTAssertEqual(real["undo_note"] as? String, CheICalMCPServer.batchSeriesDeletedThroughOccurrenceNote)
        XCTAssertTrue(CheICalMCPServer.batchSeriesDeletedThroughOccurrenceNote.contains("cannot be undone"))
        XCTAssertTrue(CheICalMCPServer.batchSeriesDeletedThroughOccurrenceNote.contains("restores only the other rows"))

        // PR #465 verify r2: when no other row was deleted, the call has no undo of its own.
        var only = BatchDeleteResult(successCount: 1, failedCount: 0, failures: [])
        only.throughFirstOccurrence = [(identifier: "S1", occurrenceID: "S1/RID=1")]
        let alone = try await call(BatchDeletionFake(listed: [], result: only),
                                   ["event_ids": .array([.string("S1")]), "span": .string("all"), "dry_run": .bool(false)])
        XCTAssertEqual(alone["undo_note"] as? String, CheICalMCPServer.batchOnlySeriesDeletedThroughOccurrenceNote)
        XCTAssertFalse(CheICalMCPServer.batchOnlySeriesDeletedThroughOccurrenceNote.contains("other rows"))
        XCTAssertTrue(CheICalMCPServer.batchOnlySeriesDeletedThroughOccurrenceNote.contains("restores nothing"))

        // The dry run says so before anything is deleted.
        let dry = try await call(BatchDeletionFake(listed: [], previewRow: .deletesThroughFirstOccurrence(
                                    start: base, end: base.addingTimeInterval(3600), occurrenceID: "S1/RID=1")),
                                 ["event_ids": .array([.string("S1")]), "span": .string("all"), "dry_run": .bool(true)])
        let row = try XCTUnwrap((dry["events_to_delete"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["occurrence_id"] as? String, "S1/RID=1")
        XCTAssertEqual(row["undo_note"] as? String, CheICalMCPServer.batchPreviewThroughOccurrenceNote)

        let plain = try await call(BatchDeletionFake(listed: [], result: BatchDeleteResult(successCount: 1, failedCount: 0, failures: [])),
                                   ["event_ids": .array([.string("S2")]), "span": .string("all"), "dry_run": .bool(false)])
        XCTAssertNil(plain["undo_note"], "no note when no row went through a first occurrence")
        XCTAssertNil(plain["through_first_occurrence"])
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
        let before = base.addingTimeInterval(1463 * day)
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

    // MARK: - #332: the read bound stops a by-date-range delete before anything is deleted

    func testTheReadBoundStopsTheDeleteWithNothingDeleted() async throws {
        let fake = BatchDeletionFake(listed: [], listError: EventRangeQuery.RangeError.tooManyEvents(
            limit: EventRangeQuery.maxEventsRead, from: base, to: base.addingTimeInterval(36_500 * day), readThrough: base.addingTimeInterval(1460 * day)))
        let server = try await CheICalMCPServer(eventBatchDeletionSource: fake)
        do {
            _ = try await server.executeToolCall(name: "delete_events_batch", arguments: args(after: base, dryRun: false))
            XCTFail("expected the read bound")
        } catch let error as EventRangeQuery.RangeError {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Nothing was deleted."), text)
            XCTAssertTrue(text.contains("Give both after_date and before_date, at most 1460 days apart."), text)
            XCTAssertFalse(text.contains("calendar_name"), "this mode always has one: \(text)")
        }
        let deleted = await fake.anyDelete
        XCTAssertFalse(deleted)
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

    /// By date range too (#427): a listed occurrence with its series not listed would be deleted
    /// alone, answered as the series. Refused in both modes, and not counted as a deletion.
    func testARangeHoldingOnlyAnEditedOccurrenceRefusesThatRow() async throws {
        let slot = base.addingTimeInterval(14 * day)
        let occurrences = [unedited(0), unedited(7), editedOccurrence(14), unedited(21)]
        func listing() -> [BatchDeletionListedEvent] {
            [BatchDeletionListedEvent(identifier: ownId(14), start: slot, end: slot.addingTimeInterval(3600), slot: slot, isDetached: true)]
        }
        let dryModel = SeriesModel(series: series, occurrences: occurrences, listed: listing())
        let dry = try await call(dryModel, args(after: slot.addingTimeInterval(-day), before: slot.addingTimeInterval(day), span: "all", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 0, "\(dry)")
        let rows = try XCTUnwrap(dry["events_to_delete"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["error"] as? String, DetachedOccurrenceSpan.seriesDeleteBatchReason)
        let model = SeriesModel(series: series, occurrences: occurrences, listed: listing())
        let real = try await call(model, args(after: slot.addingTimeInterval(-day), before: slot.addingTimeInterval(day), span: "all", dryRun: false))
        XCTAssertEqual(real["failed"] as? Int, 1, "\(real)")
        XCTAssertEqual(real["succeeded"] as? Int, 0)
        let left = await model.left
        XCTAssertEqual(left, 4)
    }

    /// The series listed too: its row takes the whole series, as ever.
    func testARangeHoldingTheSeriesToo() async throws {
        let first = base, slot = base.addingTimeInterval(14 * day)
        let listing = [BatchDeletionListedEvent(identifier: series, start: first, end: first, slot: first),
                       BatchDeletionListedEvent(identifier: ownId(14), start: slot, end: slot, slot: slot, isDetached: true)]
        let occurrences = [unedited(0), unedited(7), editedOccurrence(14)]
        let dry = try await call(SeriesModel(series: series, occurrences: occurrences, listed: listing),
                                 args(after: first.addingTimeInterval(-day), before: slot.addingTimeInterval(day), span: "all", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 1, "the occurrence is left to the series' row: \(dry)")
    }

    /// #427 cluster verify: an open-ended series, where the scan cannot show it ends. Judged on its
    /// own the occurrence's row was refused while the series' row deleted it anyway; it is left to
    /// the series' row, in both modes, and only that row reaches the delete.
    func testAnOpenEndedSeriesListedTooTakesItsEditedOccurrence() async throws {
        let first = base, slot = base.addingTimeInterval(14 * day)
        let listing = [BatchDeletionListedEvent(identifier: series, start: first, end: first, slot: first),
                       BatchDeletionListedEvent(identifier: ownId(14), start: slot, end: slot, slot: slot, isDetached: true)]
        let occurrences = [unedited(0), unedited(7), editedOccurrence(14), unedited(21)]
        let range = args(after: first.addingTimeInterval(-day), before: slot.addingTimeInterval(day), span: "all", dryRun: true)
        let dry = try await call(SeriesModel(series: series, occurrences: occurrences, listed: listing, coversWholeSeries: false), range)
        XCTAssertEqual(dry["deletions"] as? Int, 1, "\(dry)")
        let rows = try XCTUnwrap(dry["events_to_delete"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2, "both listed occurrences are shown")
        XCTAssertTrue(rows.allSatisfy { $0["error"] == nil }, "\(rows)")
        let model = SeriesModel(series: series, occurrences: occurrences, listed: listing, coversWholeSeries: false)
        var real = range; real["dry_run"] = .bool(false)
        let answer = try await call(model, real)
        XCTAssertEqual(answer["failed"] as? Int, 0, "\(answer)")
        let left = await model.left
        XCTAssertEqual(left, 0)
        let fake = BatchDeletionFake(listed: listing)
        _ = try await call(fake, real)
        let calls = await fake.seriesCalls
        XCTAssertEqual(calls, [[series]], "the occurrence's row is not sent")
    }

    /// Cluster verify r2: the series' row refused on its own (the first occurrence moved past the next
    /// slot, so neither the stand-in nor the first-occurrence route takes it). The occurrence's row is
    /// kept and runs first, as on main, and the series' row then reaches the rest: nothing is newly
    /// refused, in both modes.
    func testAListedSeriesRefusedAloneKeepsItsOccurrenceRow() async throws {
        let firstSlot = base, movedTo = base.addingTimeInterval(10 * day)
        let moved = FirstRemainingOccurrence.Candidate(eventIdentifier: ownId(0), isDetached: true, hasRecurrenceRules: false,
                                                       start: movedTo, slot: firstSlot)
        let occurrences = [moved, unedited(7), unedited(14)]
        let listing = [BatchDeletionListedEvent(identifier: ownId(0), start: movedTo, end: movedTo, slot: firstSlot, isDetached: true),
                       BatchDeletionListedEvent(identifier: series, start: base.addingTimeInterval(7 * day), end: base.addingTimeInterval(7 * day),
                                                slot: base.addingTimeInterval(7 * day))]
        let range = args(after: base.addingTimeInterval(-day), before: base.addingTimeInterval(15 * day), span: "all", dryRun: true)
        let dry = try await call(SeriesModel(series: series, occurrences: occurrences, listed: listing), range)
        XCTAssertEqual(dry["deletions"] as? Int, 2, "\(dry)")
        XCTAssertTrue((dry["events_to_delete"] as? [[String: Any]] ?? []).allSatisfy { $0["error"] == nil }, "\(dry)")
        let model = SeriesModel(series: series, occurrences: occurrences, listed: listing)
        var real = range; real["dry_run"] = .bool(false)
        let answer = try await call(model, real)
        XCTAssertEqual(answer["failed"] as? Int, 0, "\(answer)")
        let left = await model.left
        XCTAssertEqual(left, 0)
    }

    /// #427 cluster verify: by date range too, a series' row that the real call deletes through its
    /// first occurrence says so in the dry run, as by event_ids.
    func testARangeRowThroughTheFirstOccurrenceCarriesItsUndoNote() async throws {
        let first = base
        let listing = [BatchDeletionListedEvent(identifier: series, start: first, end: first, slot: first)]
        let fake = BatchDeletionFake(listed: listing, previewRow: .deletesThroughFirstOccurrence(
            start: first, end: first, occurrenceID: ownId(0)))
        let dry = try await call(fake, args(after: first.addingTimeInterval(-day), before: first.addingTimeInterval(day), span: "all", dryRun: true))
        let row = try XCTUnwrap((dry["events_to_delete"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["occurrence_id"] as? String, ownId(0))
        XCTAssertEqual(row["undo_note"] as? String, CheICalMCPServer.batchPreviewThroughOccurrenceNote)
        XCTAssertEqual(dry["deletions"] as? Int, 1)
    }

    /// #427 cluster verify: an identifier with `/RID=` names one occurrence whatever `isDetached`
    /// says, as the real call reads it (`addressesOneOccurrence`).
    func testARangeRowWithASlotInItsIdIsJudgedWithoutIsDetached() async throws {
        let slot = base.addingTimeInterval(14 * day)
        let own = FirstRemainingOccurrence.Candidate(eventIdentifier: ownId(14), isDetached: false, hasRecurrenceRules: false,
                                                     start: slot, slot: slot)
        let listing = [BatchDeletionListedEvent(identifier: ownId(14), start: slot, end: slot, slot: slot, isDetached: false)]
        let dry = try await call(SeriesModel(series: series, occurrences: [unedited(0), unedited(7), own], listed: listing),
                                 args(after: slot.addingTimeInterval(-day), before: slot.addingTimeInterval(day), span: "all", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 0, "\(dry)")
        XCTAssertEqual((dry["events_to_delete"] as? [[String: Any]])?.first?["error"] as? String, DetachedOccurrenceSpan.seriesDeleteBatchReason)
    }

    /// #427 cluster verify: a row whose preview throws shows the error, as by event_ids, and is not
    /// counted; it used to be dropped with try? and counted.
    func testARangeRowWhosePreviewFailsShowsTheError() async throws {
        let slot = base.addingTimeInterval(14 * day)
        let listing = [BatchDeletionListedEvent(identifier: ownId(14), start: slot, end: slot, slot: slot, isDetached: true)]
        let dry = try await call(SeriesModel(series: series, occurrences: [unedited(0)], listed: listing),
                                 args(after: slot.addingTimeInterval(-day), before: slot.addingTimeInterval(day), span: "all", dryRun: true))
        XCTAssertEqual(dry["deletions"] as? Int, 0, "\(dry)")
        XCTAssertNotNil((dry["events_to_delete"] as? [[String: Any]])?.first?["error"])
    }

    // MARK: - #416: the event_ids dry run and the real call agree

    private let series = "S"

    private func unedited(_ days: Double) -> FirstRemainingOccurrence.Candidate {
        .init(eventIdentifier: series, isDetached: false, hasRecurrenceRules: true, start: base.addingTimeInterval(days * day))
    }

    private func editedOccurrence(_ days: Double) -> FirstRemainingOccurrence.Candidate {
        let slot = base.addingTimeInterval(days * day)
        return .init(eventIdentifier: ownId(days), isDetached: true, hasRecurrenceRules: false, start: slot, slot: slot)
    }

    private func ownId(_ days: Double) -> String { "\(series)/RID=\(Int(base.timeIntervalSince1970 + days * day))" }

    /// What each mode says about the same call on a fresh copy of the series.
    private func dryRunAndRealCall(_ occurrences: [FirstRemainingOccurrence.Candidate], ids: [String], span: String = "all") async throws
        -> (dry: [[String: Any]], total: Int?, real: [String: Any], left: Int) {
        let args: [String: Value] = ["event_ids": .array(ids.map { .string($0) }), "span": .string(span)]
        let dryServer = try await CheICalMCPServer(eventBatchDeletionSource: SeriesModel(series: series, occurrences: occurrences))
        var dryArgs = args
        dryArgs["dry_run"] = .bool(true)
        let dry = try object(await dryServer.executeToolCall(name: "delete_events_batch", arguments: dryArgs))
        let model = SeriesModel(series: series, occurrences: occurrences)
        let realServer = try await CheICalMCPServer(eventBatchDeletionSource: model)
        var realArgs = args
        realArgs["dry_run"] = .bool(false)
        let real = try object(await realServer.executeToolCall(name: "delete_events_batch", arguments: realArgs))
        return (try XCTUnwrap(dry["events_to_delete"] as? [[String: Any]]), dry["total"] as? Int, real, await model.left)
    }

    private func assertSameAnswer(_ occurrences: [FirstRemainingOccurrence.Candidate], ids: [String], deletes: Int, left: Int,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let answer = try await dryRunAndRealCall(occurrences, ids: ids)
        let previewed = answer.dry.filter { $0["error"] == nil }.count
        XCTAssertEqual(previewed, deletes, "\(answer.dry)", file: file, line: line)
        XCTAssertEqual(answer.real["succeeded"] as? Int, deletes, "\(answer.real)", file: file, line: line)
        XCTAssertEqual(answer.real["failed"] as? Int, answer.dry.count - previewed, "\(answer.real)", file: file, line: line)
        XCTAssertEqual(answer.total, answer.real["total"] as? Int, file: file, line: line)
        XCTAssertEqual(answer.left, left, file: file, line: line)
    }

    /// [S, S/RID=first], first occurrence edited: the occurrence's row runs first, and the bare id
    /// is judged with it gone. The dry run used to refuse S and list one deletion, while the real
    /// call deleted everything. In either order of the ids.
    func testTheDryRunShowsTheWholeDeleteWhenTheFirstOccurrenceWasEdited() async throws {
        let shape = [editedOccurrence(0), unedited(7), unedited(14), unedited(21), unedited(28)]
        try await assertSameAnswer(shape, ids: [series, ownId(0)], deletes: 2, left: 0)
        try await assertSameAnswer(shape, ids: [ownId(0), series], deletes: 2, left: 0)
    }

    /// The first occurrence deleted, the first one left edited: the same rows, the same answer.
    func testTheDryRunShowsTheWholeDeleteWhenTheFirstLeftWasEdited() async throws {
        let shape = [editedOccurrence(7), unedited(14), unedited(21), unedited(28)]
        try await assertSameAnswer(shape, ids: [series, ownId(7)], deletes: 2, left: 0)
    }

    /// Another edited occurrence the call does not name: the occurrence's row is refused, as it would
    /// delete only that occurrence, and the series' row reaches the series through it (#436), as
    /// the call named the series. Both modes say so.
    func testTheDryRunShowsTheSeriesRowWhenAnEditedOccurrenceIsNotNamed() async throws {
        let shape = [editedOccurrence(0), unedited(7), editedOccurrence(14), unedited(21)]
        try await assertSameAnswer(shape, ids: [series, ownId(0)], deletes: 1, left: 0)
    }

    /// Every edited occurrence named: each runs first, and the bare id then reaches the rest.
    func testTheDryRunShowsTheWholeDeleteWhenEveryEditedOccurrenceIsNamed() async throws {
        let shape = [editedOccurrence(0), unedited(7), editedOccurrence(14), unedited(21)]
        try await assertSameAnswer(shape, ids: [series, ownId(14), ownId(0)], deletes: 3, left: 0)
    }

    /// The bare id alone, the first occurrence edited (#436): the whole series, in both modes.
    func testTheDryRunShowsTheWholeDeleteForTheBareIdAlone() async throws {
        let shape = [editedOccurrence(0), unedited(7), unedited(14)]
        try await assertSameAnswer(shape, ids: [series], deletes: 1, left: 0)
    }

    /// An occurrence matched only by its external identifier is not the series' first edited
    /// occurrence (`earliestEdited` leaves it out), though it comes first by slot: the bare id
    /// reaches no occurrence of its own and is refused, in both modes.
    func testAnExternalIdMatchIsNotTheFirstEditedOccurrence() async throws {
        let shape = [unedited(7), .init(eventIdentifier: "unrelated", isDetached: true, hasRecurrenceRules: false,
                                        start: base, slot: base, sameSeriesByExternalID: true)]
        try await assertSameAnswer(shape, ids: [series], deletes: 0, left: 2)
    }

    /// Span `this` does not take the edited-before refusal: the first occurrence deleted, the first
    /// left edited, a bare id. The dry run used to fail that row with the refusal of a whole-series
    /// write. Both modes now answer what the real row answers: no date was given. The occurrence's
    /// own id goes ahead in both, and nothing else is touched.
    func testSpanThisPreviewsWhatTheRealRowDoes() async throws {
        let shape = [editedOccurrence(7), unedited(14), unedited(21)]
        let bare = try await dryRunAndRealCall(shape, ids: [series], span: "this")
        let dryError = try XCTUnwrap(bare.dry.first?["error"] as? String, "\(bare.dry)")
        XCTAssertEqual(dryError, EventKitManager.batchOccurrenceDateRequired)
        let failures = try XCTUnwrap(bare.real["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.first?["error"] as? String, dryError)
        XCTAssertEqual(bare.left, 3)
        let own = try await dryRunAndRealCall(shape, ids: [ownId(7)], span: "this")
        XCTAssertNil(own.dry.first?["error"], "\(own.dry)")
        XCTAssertEqual(own.real["succeeded"] as? Int, 1)
        XCTAssertEqual(own.left, 2)
    }

    /// `total` counts each id once, as the real call does.
    func testTheDryRunCountsARepeatedIdOnce() async throws {
        let shape = [editedOccurrence(0), unedited(7)]
        try await assertSameAnswer(shape, ids: [series, ownId(0), series], deletes: 2, left: 0)
    }
}
