import XCTest
@testable import CheICalMCP

/// #539 step 6: the wiring of the forecast that an in-memory store cannot run: the four places that
/// capture a whole series' exceptions before a delete compute the count from that capture, before the
/// removal, and hand it out only from the record the delete made; the dry run asks it with the row
/// still present. Pinned from `Sources/` (comments stripped, whitespace collapsed).
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

    /// Each capture point: the capture, then the count from what it captured and how the series was
    /// reached, then the removal.
    func testEachCapturePointCountsFromItsCaptureBeforeItRemoves() throws {
        assertInOrder(["seriesExceptions: { self.captureSeriesExceptions(of: masterEvent) })",
                       "unplacedEdits = unplacedEditsAtDelete(snapshots.series.exceptions, of: masterEvent, id: identifier, viaStandIn: resolved.viaStandIn)",
                       "try eventStore.remove(occurrence, span: span)"],
                      in: try body("func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil) async throws -> RulesAloneOnUndo? {"),
                      "delete_event span future")
        assertInOrder(["EventSnapshot.recordingSeriesDelete(of: event, capture: { self.captureSeriesExceptions(of: event) })",
                       "let unplacedEdits = unplacedEditsAtDelete(snapshot.exceptions, of: event, id: identifier, viaStandIn: resolved.viaStandIn)",
                       "try eventStore.remove(event, span: .futureEvents)"],
                      in: try body("func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute {"), "delete_event span all")
        assertInOrder(["EventSnapshot.recordingSeriesDelete(of: event, capture: { self.captureSeriesExceptions(of: event) })",
                       "let unplacedEdits = unplacedEditsAtDelete(snapshot.exceptions, of: event, id: id, viaStandIn: resolved.viaStandIn)",
                       "try eventStore.remove(event, span: .futureEvents)"],
                      in: try body("func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {"), "batch span all")
        assertInOrder(["seriesExceptions: { self.captureSeriesExceptions(of: masterEvent) })",
                       "unplacedEdits = unplacedEditsAtDelete(snapshots.series.exceptions, of: masterEvent, id: item.identifier, viaStandIn: resolvedRow.viaStandIn)",
                       "try eventStore.remove(occurrence, span: span)"],
                      in: try body(Self.batchDeclaration), "batch span future")
    }

    /// The count leaves only from the record the delete made: a delete recorded as an occurrence or as
    /// an occurrence and the following ones forecasts nothing, and in a batch a member that refuses
    /// the call's undo clears every row (`RulesAloneForecast`).
    func testTheCountLeavesFromTheRecordTheDeleteMade() throws {
        assertInOrder(["let record = snapshots.record(for: kind)", "await CalendarUndoManager.shared.record(record)",
                       "return RulesAloneForecast.expected(of: record, unplacedEdits: unplacedEdits)"],
                      in: try body("func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil) async throws -> RulesAloneOnUndo? {"),
                      "delete_event")
        assertInOrder(["await CalendarUndoManager.shared.record(.deleteEvent(id: removedID, snapshot: snapshot))", "return .series(unplacedEdits: unplacedEdits)"],
                      in: try body("func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute {"), "delete_event span all")
        assertInOrder(["var forecast = RulesAloneForecast()", "undoOperations.append(.deleteEvent(id: removedID, snapshot: snapshot))",
                       "forecast.recorded(.deleteEvent(id: removedID, snapshot: snapshot), identifier: id, unplacedEdits: unplacedEdits)",
                       "rulesAloneOnUndo: forecast.expected"],
                      in: try body("func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {"), "batch span all")
        assertInOrder(["var forecast = RulesAloneForecast()",
                       "if kind != .wholeEvent || undoSeenWholeIdentifiers.insert(item.identifier).inserted { undoOperations.append(snapshots.record(for: kind)) forecast.recorded(snapshots.record(for: kind), identifier: item.identifier, unplacedEdits: unplacedEdits) }",
                       "rulesAloneOnUndo: forecast.expected"],
                      in: try body(Self.batchDeclaration), "batch span future")
    }

    /// The first slot is the one #503 proves (`wholeSeriesBaseline`), and only a plain first occurrence
    /// at its own start counts (`.stored`): a stand-in or a first occurrence edited on its own gives no
    /// count. The zone and the rules are those #503's verdict expands in. PR #558 fix round 4: there is no
    /// other cause (round 3's count of every edit of a floating record is removed with its restore).
    func testTheCountReadsTheFirstSlotAsTheCheckOf503Does() throws {
        assertInOrder(["guard let exceptions, !exceptions.detached.isEmpty else { return nil }",
                       "let first = wholeSeriesBaseline(of: series, id: id, viaStandIn: viaStandIn, excluding: goneInTheCall)",
                       "guard first.baseline == .stored else { return nil }",
                       "let zone = series.isAllDay ? TimeZone.current : (series.timeZone ?? .current)",
                       "let edits = SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: (series.recurrenceRules ?? []).map(DeletedOccurrenceCheck.Rule.init), firstSlot: first.slot, calendar: .gregorian(in: zone)) ?? 0",
                       "return edits > 0 ? RulesAloneOnUndo(edits: edits) : nil"],
                      in: try body("func unplacedEditsAtDelete(_ exceptions: SeriesExceptions?, of series: EKEvent, id: String, viaStandIn: Bool, goneInTheCall: Set<String> = []) -> RulesAloneOnUndo? {",
                                   in: "EventKit/EventKitManager+SeriesExceptions.swift"), "the count")
        let manager = try code("EventKit/EventKitManager+SeriesExceptions.swift")
        XCTAssertFalse(manager.contains("holdsAFloatingEdit"), "no cause but the rule's slots")
        // C3: the first slot's listing leaves out what the dry run counts as gone, as `firstEditedOccurrenceID` does.
        let baseline = try body("func wholeSeriesBaseline(of series: EKEvent, id: String, viaStandIn: Bool, excluding gone: Set<String> = []) -> (baseline: DeletedOccurrenceCheck.StoredBaseline, slot: Date?) {",
                                in: "EventKit/FirstRemainingOccurrence.swift")
        assertInOrder(["guard let (_, listed) = seriesOccurrences(of: series, id: id), case let candidates = listed.filter({ !gone.contains($0.eventIdentifier ?? \"\") }), !candidates.isEmpty else { return (.unproven, nil) }"],
                      in: baseline, "the first slot's listing")
        // #263's capture of a whole-series update does not compute it.
        XCTAssertFalse(try code("EventKit/EventKitManager+SeriesUpdateUndo.swift").contains("unplacedEditsAtDelete("))
    }

    /// The dry run resolves the row as `previewEventDeletion` does and captures it as the real call
    /// does, and asks before the row counts as gone; only the manager answers it. PR #558 fix round 4 (C3):
    /// the occurrences the call's earlier rows delete are left out of the capture and of the first slot's
    /// listing, as the real call's series row no longer sees them (`SeriesDeleteForecastTests`); round 5
    /// (Q2): by identity, the capture made through `DryRunCaptureStore`, and only there.
    func testTheDryRunForecastsTheRowAsTheRealCallRecordsIt() throws {
        let seam = try code("EventKit/EventKitManager+SeriesExceptions.swift")
        let dryRun = try XCTUnwrap(SourceScan.body(of: "func captureSeriesExceptionsForDryRun(of series: EKEvent, goneInTheCall gone: Set<String>) -> SeriesExceptions? {", in: seam))
        XCTAssertEqual(dryRun.trimmingCharacters(in: .whitespaces),
                       "SeriesExceptionsUndo.capture(of: series, in: DryRunCaptureStore(base: seriesExceptionsStore, gone: gone))", dryRun)
        // Every delete's capture is `main`'s, on the manager's own store.
        let deleteCapture = try XCTUnwrap(SourceScan.body(of: "func captureSeriesExceptions(of series: EKEvent) -> SeriesExceptions? {", in: seam))
        XCTAssertEqual(deleteCapture.trimmingCharacters(in: .whitespaces), "SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore)", deleteCapture)
        let sources = try ["EventKit/EventKitManager.swift", "EventBatchDeletionSource.swift", "EventKit/EventKitManager+SeriesExceptions.swift",
                           "EventKit/SeriesExceptionsUndo.swift", "Server.swift"].map(code).joined(separator: " ")
        XCTAssertEqual(sources.components(separatedBy: "DryRunCaptureStore(").count - 1, 1, "one dry-run capture")
        XCTAssertEqual(sources.components(separatedBy: "captureSeriesExceptionsForDryRun(of:").count - 1, 1, "called by the dry run only")
        // The manager's own, not the protocol's default for doubles (which answers nil).
        let manager = try body("func previewUndoForecast(identifier: String, goneInTheCall: Set<String>) async -> RulesAloneOnUndo? { guard", in: "EventBatchDeletionSource.swift")
        assertInOrder(["freshEventWithOrigin( id: identifier, refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: .thisEvent, wholeSeries: true), goneInTheCall: goneInTheCall)",
                       "resolved.event.hasRecurrenceRules else { return nil }",
                       "let series = resolved.event",
                       "let exceptions = captureSeriesExceptionsForDryRun(of: series, goneInTheCall: goneInTheCall)",
                       "return unplacedEditsAtDelete(exceptions, of: series, id: identifier, viaStandIn: resolved.viaStandIn, goneInTheCall: goneInTheCall)"],
                      in: manager, "the manager's dry-run forecast")
        let rows = try body("private func previewDeletionRows(_ eventIds: [String], spanStr: String) async -> [[String: Any]] {", in: "Server.swift")
        assertInOrder(["case .deletes(let start, let end):",
                       "if spanAll { let unplacedEdits = await eventBatchDeletionSource.previewUndoForecast(identifier: id, goneInTheCall: gone)",
                       "if let unplacedEdits { deletion[\"undo_note\"] = Self.batchPreviewRulesAloneNote(unplacedEdits) } gone.insert(id) }"],
                      in: rows, "the dry run's span all row")
    }
}
