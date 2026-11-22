import XCTest
@testable import CheICalMCP

/// #539 step 6: the wiring of the forecast that an in-memory store cannot run: the four places that
/// capture a whole series before removal and calculate the forecast from those observations only
/// when the delete records the series. The dry run reuses the already resolved row.
final class SeriesDeleteForecastWiringTests: XCTestCase {
    private static let batchDeclaration = "func deleteEventsBatch( items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan = .thisEvent, slots: [Date?]? = nil ) async throws -> BatchDeleteResult {"

    private func code(_ file: String) throws -> String {
        SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source(file)))
    }

    private func body(_ declaration: String, in file: String = "EventKit/EventKitManager.swift") throws -> String {
        try XCTUnwrap(SourceScan.body(of: declaration, in: try code(file)), declaration)
    }

    /// Asserts each of `pieces` occurs once in `text`, in that order.
    private func assertInOrder(_ pieces: [String], in text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        var from = text.startIndex
        for piece in pieces {
            XCTAssertEqual(text.components(separatedBy: piece).count - 1, 1, "\(message): once: \(piece)", file: file, line: line)
            guard let found = text.range(of: piece, range: from..<text.endIndex) else {
                return XCTFail("\(message): not after the previous piece: \(piece)", file: file, line: line)
            }
            from = found.upperBound
        }
    }

    func testTheRealForecastDoesNotQueryTheStoreAgain() throws {
        let source = try code("EventKit/EventKitManager+SeriesExceptions.swift")
        XCTAssertFalse(source.contains("wholeSeriesBaseline("),
                       "the delete already captured the series before removal")
    }

    func testEachCapturePointObservesItsRecordBeforeRemoval() throws {
        let single = try body("func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil) async throws -> RulesAloneOnUndo? {")
        let futureBatch = try body(Self.batchDeclaration)
        for path in [single, futureBatch] {
            assertInOrder(["seriesExceptions: { self.captureSeriesExceptionsForDelete(of: masterEvent, anchor: anchor) })",
                           "try eventStore.remove(occurrence, span: span)"], in: path, "span future")
        }
        for declaration in ["func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute {",
                            "func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {"] {
            assertInOrder(["EventSnapshot.recordingSeriesDelete(of: event, capture: { self.captureSeriesExceptionsForDelete(of: event, anchor: anchor) })",
                           "try eventStore.remove(event, span: .futureEvents)"], in: try body(declaration), "span all")
        }
    }

    func testTheCountLeavesFromTheRecordTheDeleteMade() throws {
        assertInOrder(["let record = snapshots.record(for: kind)", "await CalendarUndoManager.shared.record(record)",
                       "return RulesAloneForecast.expected(of: record, unplacedEdits: { anchor?.forecast(for: snapshots.series) })"],
                      in: try body("func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil) async throws -> RulesAloneOnUndo? {"),
                      "delete_event")
        assertInOrder(["await CalendarUndoManager.shared.record(.deleteEvent(id: removedID, snapshot: snapshot))",
                       "return .series(unplacedEdits: anchor?.forecast(for: snapshot))"],
                      in: try body("func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute {"), "delete_event span all")
        assertInOrder(["undoOperations.append(record)",
                       "forecast.recorded(record, identifier: id, anchor: anchor)",
                       "rulesAloneOnUndo: forecast.expected"],
                      in: try body("func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {"), "batch span all")
        assertInOrder(["let record = snapshots.record(for: kind)", "undoOperations.append(record)",
                       "forecast.recorded(record, identifier: item.identifier, anchor: anchor)",
                       "rulesAloneOnUndo: forecast.expected"], in: try body(Self.batchDeclaration), "batch span future")
    }

    func testTheCountReadsTheFirstSlotAsTheCheckOf503Does() throws {
        let source = try code("EventKit/DeleteUndo.swift")
        XCTAssertTrue(source.contains("guard !viaStandIn, series.hasRecurrenceRules, !series.isDetached else { return nil }"))
        assertInOrder(["guard let exceptions = snapshot.exceptions, !exceptions.detached.isEmpty,",
                       "let first = DeletedOccurrenceCheck.firstSlot(",
                       "guard let first, DeletedOccurrenceCheck.baseline(firstSlot: first, firstIsEdited: firstIsEdited, startDate: start) == .stored,",
                       "SeriesExceptionsPlanner.unplacedEdits(", "return RulesAloneOnUndo(edits: edits)"],
                      in: try body("func forecast(for snapshot: EventSnapshot, previewSlots: [Date]? = nil) -> RulesAloneOnUndo? {", in: "EventKit/DeleteUndo.swift"),
                      "the count")
        let capture = try body("func captureSeriesExceptionsForDelete(of series: EKEvent, anchor: SeriesDeleteAnchor?) -> SeriesExceptions? {",
                               in: "EventKit/EventKitManager+SeriesExceptions.swift")
        assertInOrder(["guard let anchor else { return captureSeriesExceptions(of: series) }", "store.observeForForecast = anchor.observe",
                       "return SeriesExceptionsUndo.capture(of: series, in: store)"], in: capture, "capture observations only")
        XCTAssertFalse(try code("EventKit/EventKitManager+SeriesUpdateUndo.swift").contains("captureSeriesExceptionsForDelete("))
    }

    func testTheModelChecksTheAnchorBeforeReportingAMissingEdit() throws {
        let source = try code("EventKit/SeriesExceptions.swift")
        let projection = try XCTUnwrap(SourceScan.body(of: "static func projectedSlots(", in: source))
        assertInOrder(["for window in windows", "taken.insert(slot)"], in: projection, "the model preserves listing order")
        let declaration = "static func unplacedEdits(_ exceptions: SeriesExceptions, firstSlot: Date, slotsListed: [Date]) -> Int? {"
        let check = try XCTUnwrap(SourceScan.body(of: declaration, in: source))
        assertInOrder(["guard !inWindows(firstSlot, exceptions.windows) || generated.contains(firstSlot),",
                       "exceptions.keptSlots.allSatisfy(generated.contains)",
                       "return exceptions.detached.filter { !generated.contains($0.slot) }.count"],
                      in: check, "the forecast checks the anchor before counting")
    }

    func testTheDryRunReadsTheResolvedIdentityInBothDeletionArms() throws {
        let source = try code("EventBatchDeletionSource.swift")
        assertInOrder(["BatchForecastIdentity(requested: identifier, resolved: occurrence.eventIdentifier, external: occurrence.calendarItemExternalIdentifier, throughFirstOccurrence: true)",
                       "return .deletesThroughFirstOccurrence(start: start, end: end, occurrenceID: first.id, isAllDay: occurrence.isAllDay, timeZone: occurrence.timeZone, identity: identity)",
                       "BatchForecastIdentity(requested: identifier, resolved: event.eventIdentifier, external: event.calendarItemExternalIdentifier, detached: event.isDetached)",
                       "return .deletes(start: start, end: end, isAllDay: event.isAllDay, timeZone: event.timeZone, forecast: estimate)"], in: source, "record the fetched identity on either route")
    }

    func testBatchDefersForecastWorkUntilStructuralRefusalsAreKnown() throws {
        let future = try body(Self.batchDeclaration)
        assertInOrder(["anchor = span == .futureEvents && !forecast.isSuppressed",
                       "let record = snapshots.record(for: kind)", "undoOperations.append(record)",
                       "forecast.recorded(record, identifier: item.identifier, anchor: anchor)",
                       "rulesAloneOnUndo: forecast.expected"], in: future, "the batch queues only committed records")
    }

    func testCaptureOnlyCollectsInputsAndRefusedBatchesDiscardPendingWork() throws {
        let file = "EventKit/DeleteUndo.swift"
        let observe = try body("func observe(_ occurrence: SeriesExceptionsPlanner.ObservedOccurrence) {", in: file)
        XCTAssertFalse(observe.contains("UndoPostState.ruleSlot("))
        let queued = try body("mutating func recorded(_ record: UndoOperation, identifier: String, anchor: SeriesDeleteAnchor?) {", in: file)
        assertInOrder(["if record.batchMemberUndoRefusal != nil", "isSuppressed = true", "pending.removeAll()",
                       "guard !isSuppressed, case .deleteEvent", "pending.append((identifier, { anchor.forecast(for: snapshot) }))"],
                      in: queued, "defer the computation until all records can be undone")
    }

    func testPreviewUsesTheCaptureListingPlanAndRemainingBudget() throws {
        let preview = try code("EventBatchDeletionSource.swift")
        assertInOrder(["context.read(identity)", "remainingListings in", "remainingListings: remainingListings"],
                      in: preview, "the preview passes the call's remaining listing budget")
        let capture = try code("EventKit/SeriesExceptionsUndo.swift")
        let start = try XCTUnwrap(capture.range(of: "let fromFirst")).lowerBound
        let end = try XCTUnwrap(capture.range(of: "let observed = observedOccurrences")).lowerBound
        assertInOrder(["guard admitPreview?(windows, ranges) ?? true else { return nil }", "over: ranges, in: store"],
                      in: String(capture[start..<end]), "the count-series capture checks exact query ranges before listing")
    }

    func testTheDryRunForecastsTheRowAsTheRealCallRecordsIt() throws {
        let source = try code("EventBatchDeletionSource.swift")
        assertInOrder(["guard let resolved = try freshEventWithOrigin(",
                       "if spanAll, let refusal = try seriesDeleteRefusal(",
                       "let start: Date = event.startDate, end: Date = event.endDate", "context.read(identity)",
                       "store.observeForForecast = anchor.observe", "return anchor.preview(of: event, in: store",
                       "return .deletes(start: start, end: end, isAllDay: event.isAllDay, timeZone: event.timeZone, forecast: estimate)"], in: source, "the read-only preview")
        let handler = try body("private func previewDeletionRows(_ eventIds: [String], spanStr: String) async -> [[String: Any]] {", in: "Server.swift")
        assertInOrder(["goneInTheCall: gone, forecast: spanAll ? forecast : nil)",
                       "gone.insert(id) if let estimate", "forecast.record(estimate.identity, listings: estimate.listings)",
                       "case .deletesThroughFirstOccurrence(let start, let end, let occurrenceID, let isAllDay, let timeZone, let identity): if spanAll { gone.insert(id)"],
                      in: handler, "preserve main's requested identifiers")
    }
}
