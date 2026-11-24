import XCTest
@testable import CheICalMCP

/// #544: the exclusion check of `createEvent` works on the event store, which no seam reaches. What
/// it decides is tested in `ExclusionRetryTargetTests`; these pins hold that `createEvent` asks it
/// before the presence loop, checks the series it names, and hands that series' identifier to the
/// skipped answer.
final class ExclusionRetryTargetWiringTests: XCTestCase {
    private func create() throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func createEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift"))))
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    private func assertOnce(_ needle: String, in text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(count(needle, in: text), 1, needle, file: file, line: line)
    }

    /// The target is resolved from the match, with the series object read through `storedEvent`,
    /// and the guard on the match's own rules is gone.
    func testTheTargetIsResolvedFromTheMatch() throws {
        let body = try create()
        // #578: the request and the series read are shared with the paths without exclusions.
        assertOnce("let target = try ExclusionRetryTarget.resolve( match: ExclusionRetryTarget.Match(identifier: existingId, isDetached: existing.isDetached, hasRecurrenceRules: existing.hasRecurrenceRules, timeZone: existing.timeZone, start: existing.startDate), request: retryRequest, series: retrySeriesFacts)", in: body)
        assertOnce("let retryRequest = ExclusionRetryTarget.Request(title: title, start: startDate, host: .current)", in: body)
        let facts = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "private func retrySeriesFacts(", in: try SourcePins.source("EventKit/EventKitManager.swift"))))
        assertOnce("try storedEvent(id: id).map { ExclusionRetryTarget.SeriesFacts(hasRecurrenceRules: $0.hasRecurrenceRules, timeZone: $0.timeZone, title: $0.title, isAllDay: $0.isAllDay, firstStart: $0.occurrenceDate ?? $0.startDate) }", in: facts)
        XCTAssertFalse(body.contains("guard existing.hasRecurrenceRules"), body)
        assertOnce("case .notRecurring(let id): throw EventKitError.exclusionConflict(existingId: id, date: Self.formatExclusionDay(excluded[0], timezone: timezone))", in: body)
        assertOnce("case .notChecked(let occurrenceID): throw EventKitError.exclusionRetryNotChecked(occurrenceId: occurrenceID)", in: body)
        assertOnce("case .series(let id, let zone): (seriesID, seriesZone) = (id, zone)", in: body)
        assertOnce("let tz = timezone ?? seriesZone", in: body)
    }

    /// The resolution comes before the presence loop, and the loop and both conflicts use the
    /// series' identifier.
    func testThePresenceLoopChecksTheSeries() throws {
        let body = try create()
        let loop = "for date in excluded { switch EditedOccurrenceAddress.presence( lookupHit: findOccurrence(identifier: seriesID, on: date, in: tz) != nil, onDay: dayReadings(containing: date, in: tz), seriesID: seriesID, requested: date, zone: tz) { case .absent: continue case .resolved: throw EventKitError.exclusionConflict( existingId: seriesID, date: Self.formatExclusionDay(date, timezone: tz)) case .editedOccurrenceStarts: throw EventKitError.exclusionEditedOccurrence( existingId: seriesID, date: Self.formatExclusionDay(date, timezone: tz)) } }"
        assertOnce(loop, in: body)
        let resolve = try XCTUnwrap(body.range(of: "ExclusionRetryTarget.resolve("))
        let presence = try XCTUnwrap(body.range(of: "EditedOccurrenceAddress.presence("))
        XCTAssertLessThan(resolve.lowerBound, presence.lowerBound)
        XCTAssertFalse(body.contains("findOccurrence(identifier: existingId"), body)
        XCTAssertFalse(body.contains("existingId: existingId"), body)
    }

    /// The skipped answer on the exclusion path carries the series' identifier when it differs from
    /// the match's; the other duplicate return carries #578's (`CreateRetryIdentityWiringTests`).
    func testTheSkippedResultCarriesTheSeriesIdentifier() throws {
        let body = try create()
        assertOnce("return CreateEventResult(event: existing, isDuplicate: true, seriesIdentifier: seriesID == existingId ? nil : seriesID)", in: body)
        assertOnce("return CreateEventResult(event: existing, isDuplicate: true, seriesIdentifier: answeredSeries)", in: body)
        XCTAssertFalse(body.contains("return CreateEventResult(event: existing, isDuplicate: true) "), body)
        let write = SourceScan.collapsingWhitespace(try SourcePins.source("EventWriteSource.swift"))
        assertOnce("isDuplicate: result.isDuplicate, existingSeriesIdentifier: result.seriesIdentifier)", in: write)
    }

    /// X5 (verify round 1): the duplicate branch returns before the new event is built and saved,
    /// so a retry writes nothing; the store is not reachable from a test (no seam), so this is the
    /// structural check, next to the device rows.
    func testTheDuplicateBranchReturnsBeforeAnyWrite() throws {
        let body = try create()
        let branch = try XCTUnwrap(body.range(of: "let duplicate = findDuplicateEvent("))
        let returns = try XCTUnwrap(body.range(of: "return CreateEventResult(event: existing, isDuplicate: true, seriesIdentifier: answeredSeries)"))
        let skippedSeries = try XCTUnwrap(body.range(of: "return CreateEventResult(event: existing, isDuplicate: true, seriesIdentifier:"))
        let build = try XCTUnwrap(body.range(of: "let event = EKEvent(eventStore: eventStore)"))
        for write in ["eventStore.save(", "applyExclusions(", "CalendarUndoManager.shared.record("] {
            let at = try XCTUnwrap(body.range(of: write), write)
            XCTAssertLessThan(returns.lowerBound, at.lowerBound, write)
            XCTAssertLessThan(skippedSeries.lowerBound, at.lowerBound, write)
        }
        XCTAssertLessThan(branch.lowerBound, skippedSeries.lowerBound)
        XCTAssertLessThan(returns.lowerBound, build.lowerBound)
        let duplicateBranch = String(body[branch.lowerBound..<build.lowerBound])
        for write in ["save(", "remove(", "record(", "commit("] {
            XCTAssertFalse(duplicateBranch.contains(write), write)
        }
    }

    /// Both create handlers answer the identifier through `answeredIdentifier`.
    func testTheHandlersAnswerTheSeriesIdentifier() throws {
        let server = SourceScan.collapsingWhitespace(try SourcePins.source("Server.swift"))
        assertOnce("\"action\": \"skipped\", \"reason\": \"duplicate\", \"title\": result.event.title ?? title, \"id\": result.answeredIdentifier ?? \"unknown\"]", in: server)
        assertOnce("\"event_id\": result.answeredIdentifier ?? \"\",", in: server)
    }
}
