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
        XCTAssertFalse(source.contains("wholeSeriesBaseline(of: series, id: id, viaStandIn: viaStandIn"),
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
        assertInOrder(["undoOperations.append(.deleteEvent(id: removedID, snapshot: snapshot))",
                       "forecast.recorded(.deleteEvent(id: removedID, snapshot: snapshot), identifier: id, unplacedEdits: anchor?.forecast(for: snapshot))",
                       "rulesAloneOnUndo: forecast.expected"],
                      in: try body("func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {"), "batch span all")
        assertInOrder(["let record = snapshots.record(for: kind)", "undoOperations.append(record)",
                       "forecast.recorded(record, identifier: item.identifier, unplacedEdits: kind == .wholeEvent ? anchor?.forecast(for: snapshots.series) : nil)",
                       "rulesAloneOnUndo: forecast.expected"], in: try body(Self.batchDeclaration), "batch span future")
    }

    func testTheCountReadsTheFirstSlotAsTheCheckOf503Does() throws {
        let source = try code("EventKit/DeleteUndo.swift")
        XCTAssertTrue(source.contains("guard !viaStandIn, series.hasRecurrenceRules, !series.isDetached else { return nil }"))
        assertInOrder(["guard let exceptions = snapshot.exceptions, !exceptions.detached.isEmpty,",
                       "let first = DeletedOccurrenceCheck.firstSlot(",
                       "guard DeletedOccurrenceCheck.baseline(firstSlot: first, firstIsEdited: firstIsEdited, startDate: start) == .stored else { return nil }",
                       "SeriesExceptionsPlanner.unplacedEdits(", "return edits > 0 ? RulesAloneOnUndo(edits: edits) : nil"],
                      in: try body("func forecast(for snapshot: EventSnapshot) -> RulesAloneOnUndo? {", in: "EventKit/DeleteUndo.swift"),
                      "the count")
        let capture = try body("func captureSeriesExceptionsForDelete(of series: EKEvent, anchor: SeriesDeleteAnchor?) -> SeriesExceptions? {",
                               in: "EventKit/EventKitManager+SeriesExceptions.swift")
        assertInOrder(["guard let anchor else { return captureSeriesExceptions(of: series) }", "store.observeForForecast = anchor.observe",
                       "return SeriesExceptionsUndo.capture(of: series, in: store)"], in: capture, "capture observations only")
        XCTAssertFalse(try code("EventKit/EventKitManager+SeriesUpdateUndo.swift").contains("captureSeriesExceptionsForDelete("))
    }

    func testTheModelChecksTheAnchorBeforeReportingAMissingEdit() throws {
        let planner = try XCTUnwrap(SourceScan.body(of: "static func unplacedEdits(", in: try code("EventKit/SeriesExceptions.swift")))
        assertInOrder(["for window in exceptions.windows", "taken.insert(slot)",
                       "guard !inWindows(firstSlot, exceptions.windows) || generated.contains(firstSlot),",
                       "exceptions.keptSlots.allSatisfy(generated.contains)",
                       "return exceptions.detached.filter { !generated.contains($0.slot) }.count"],
                      in: planner, "the forecast uses listing order and checks the anchor before counting")
    }

    func testTheDryRunForecastsTheRowAsTheRealCallRecordsIt() throws {
        let source = try code("EventBatchDeletionSource.swift")
        assertInOrder(["guard let resolved = try freshEventWithOrigin(",
                       "if spanAll, let refusal = try seriesDeleteRefusal(",
                       "let start: Date = event.startDate, end: Date = event.endDate", "context.read(identity, eligible: anchor != nil)",
                       "self.captureSeriesExceptionsForDelete(of: event, anchor: anchor)", "return anchor?.forecast(for: snapshot)",
                       "return .deletes(start: start, end: end, forecast: estimate)"], in: source, "the read-only preview")
        let handler = try body("private func previewDeletionRows(_ eventIds: [String], spanStr: String) async -> [[String: Any]] {", in: "Server.swift")
        assertInOrder(["goneInTheCall: gone, forecast: spanAll ? forecast : nil)",
                       "gone.insert(id) if let estimate", "forecast.record(estimate.identity, read: estimate.read)",
                       "case .deletesThroughFirstOccurrence(let start, let end, let occurrenceID, let identity): if spanAll { gone.insert(id)"],
                      in: handler, "preserve main's requested identifiers")
    }
}
