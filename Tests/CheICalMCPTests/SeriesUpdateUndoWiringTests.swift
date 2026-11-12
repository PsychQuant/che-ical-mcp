import XCTest
@testable import CheICalMCP

/// #263: the production wiring of the whole-series update undo, which writes to the store, so no
/// unit test runs it: the record site lists the exceptions before the first field is assigned and
/// again after the save; the undo arm runs the #236 guard (its only suspension) before its own
/// checks, then writes, saves with rollback, and reads back, with no `await` after the guard.
final class SeriesUpdateUndoWiringTests: XCTestCase {
    private static let manager = "EventKit/EventKitManager.swift"
    private static let arm = "EventKit/EventKitManager+SeriesUpdateUndo.swift"

    private static func body(_ declaration: String, in file: String) throws -> String {
        SourcePins.code(try XCTUnwrap(SourcePins.body(of: declaration, in: try SourcePins.source(file)), declaration))
    }

    private func assertOrder(_ needles: [String], in body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var last = body.startIndex
        for needle in needles {
            let range = try XCTUnwrap(body.range(of: needle, range: last..<body.endIndex), "\(needle) after the previous step", file: file, line: line)
            last = range.upperBound
        }
    }

    func testTheRecordSiteListsBeforeTheFirstFieldAndAgainAfterTheSave() throws {
        let update = try Self.body("func updateEvent(", in: Self.manager)
        try assertOrder(["let seriesPlan = seriesUpdatePlan(",
                         "if let t = title { event.title = t }",
                         "try eventStore.save(event, span: span)",
                         "markNeedsRefresh()",
                         "let seriesRecord = seriesPlan.flatMap {",
                         "EventUpdateRecord.operation(",
                         "seriesRecord: seriesRecord,"], in: update)
        // Only after every refusal: the last one before the plan is #503's verdict.
        try assertOrder(["case .unknown(let cause): throw EventKitError.seriesWriteRefused(reason: DeletedOccurrenceCheck.unknownReason(cause))",
                         "let seriesPlan = seriesUpdatePlan("], in: update)
    }

    func testThePlanGatesOnTheRecordableShapeBeforeListing() throws {
        let plan = try Self.body("func seriesUpdatePlan(", in: Self.arm)
        try assertOrder(["SeriesUpdateUndo.recordable(",
                         "markNeedsRefresh()",
                         "refreshIfNeeded()",
                         "captureSeriesExceptions(of: series)",
                         "SeriesUpdateUndo.covers("], in: plan)
        XCTAssertTrue(plan.contains("defer { markNeedsRefresh() }"))
        let record = try Self.body("func seriesUpdateRecord(", in: Self.arm)
        try assertOrder(["markNeedsRefresh()",
                         "refreshIfNeeded()",
                         "SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore, windows: plan.before.windows)",
                         "postWriteSnapshot(eventID: id, saved: series)",
                         "SeriesUpdateUndo.occurrencesFollowOrKeep(before: plan.before, after: after, old: old,",
                         "written: plan.written, fields: plan.fields)"], in: record)
        XCTAssertTrue(record.contains("defer { markNeedsRefresh() }"), "the next read of another call still refreshes")
    }

    /// Verify r1: the arguments of the gate's call sites, each once, so a bypass there turns a test red.
    func testTheGateArgumentsAreThoseOfTheCall() throws {
        let update = try Self.body("func updateEvent(", in: Self.manager)
        let start = try XCTUnwrap(update.range(of: "let seriesPlan = seriesUpdatePlan(")).lowerBound
        let end = try XCTUnwrap(update.range(of: "if let t = title { event.title = t }")).lowerBound
        let call = String(update[start..<end])
        for argument in ["series: masterEvent,",
                         "wholeSeries: applyToAll, throughOwnOccurrence: addressesOwnOccurrence, viaStandIn: resolved.viaStandIn,",
                         "requested: fields, written: SeriesUpdateUndo.writtenValues(title: title, notes: notes, location: location))",
                         "onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span),"] {
            XCTAssertEqual(SourcePins.ranges(of: argument, in: call).count, 1, argument)
        }
        let arm = SourcePins.code(try SourcePins.source(Self.arm))
        XCTAssertEqual(SourcePins.ranges(of: "isICloud: Self.isICloudSeries(series)", in: arm).count, 2, "the plan and the undo arm")
        XCTAssertEqual(SourcePins.ranges(of: "placeHasCoordinates: series.structuredLocation?.geoLocation != nil", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "requested: requested, isICloud: Self.isICloudSeries(series),", in: arm).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "kind: kind, wholeSeriesCall: wholeSeries, throughOwnOccurrence: throughOwnOccurrence, viaStandIn: viaStandIn,", in: arm).count, 1)
    }

    /// Verify r1: keep_later_edits merges only one-off updates; this record is not routed to a merge arm.
    func testKeepLaterEditsDoesNotMergeThisRecord() throws {
        let dispatch = try Self.body("func executeUndoKeepingLaterEdits(", in: "EventKit/EventKitManager+KeepLaterEdits.swift")
        XCTAssertNil(dispatch.range(of: ".updateSeries"))
        XCTAssertTrue(dispatch.contains("default: return try await executeUndo(operation)"))
    }

    func testTheUndoArmChecksBeforeItWritesAndReadsBackAfter() throws {
        let undo = try Self.body("func executeUndo(_ operation: UndoOperation) async throws -> String", in: Self.manager)
        XCTAssertTrue(undo.contains("case .updateSeries(let record):"))
        XCTAssertTrue(undo.contains("return try await undoSeriesUpdate(operation, record)"))

        let arm = try Self.body("func undoSeriesUpdate(", in: Self.arm)
        try assertOrder(["let series = try await verifiedEvent(of: operation, verb: .undo)",
                         "SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore, windows: record.after.windows)",
                         "SeriesUpdateUndo.refusal(record, current:",
                         "throw SeriesUpdateUndo.refusalError(",
                         "record.old.applyRestoring(Set(record.fields), to: series, calendar: calendar)",
                         "try eventStore.save(series, span: .futureEvents)",
                         "series.rollback()",
                         "markNeedsRefresh()",
                         "refreshIfNeeded()",
                         "SeriesExceptionsUndo.capture(of: readSeries ?? series, in: seriesExceptionsStore, windows: record.before.windows)",
                         "SeriesUpdateUndo.readBackMismatch(record,",
                         "markNeedsRefresh()",
                         "throw SeriesUpdateUndo.readBackError(",
                         "return SeriesUpdateUndo.undoneMessage(record)"], in: arm)
        let afterGuard = try XCTUnwrap(arm.range(of: "let series = try await verifiedEvent(of: operation, verb: .undo)")).upperBound
        XCTAssertNil(arm[afterGuard...].range(of: "await"), "nothing suspends between the guard and the write")
    }

    func testRedoWritesNothing() throws {
        let redo = try Self.body("func executeRedo(_ operation: UndoOperation) async throws -> String", in: Self.manager)
        let fallback = try XCTUnwrap(redo.range(of: "return operation.redoInstruction ??"))
        let listed = try XCTUnwrap(redo.range(of: ".updateSeries"))
        XCTAssertLessThan(listed.lowerBound, fallback.lowerBound, "classified with the records whose redo writes nothing")
    }
}
