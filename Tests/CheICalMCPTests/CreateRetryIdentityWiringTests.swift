import XCTest
@testable import CheICalMCP

/// #578: `createEvent` works on the event store, which no seam reaches. What it decides is tested in
/// `CreateRetryIdentityTests`; these pins hold where `createEvent` asks it, and that both new paths
/// write nothing.
final class CreateRetryIdentityWiringTests: XCTestCase {
    private func create() throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func createEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift"))))
    }
    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
    private func assertOnce(_ needle: String, in text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(count(needle, in: text), 1, needle, file: file, line: line)
    }

    /// The retitled scan runs only after the title lookup missed, only for a recurring request, over
    /// the same window and calendar, and throws before the duplicate branch and any write.
    func testTheRetitledScanRunsAfterTheLookupMissedAndBeforeAnyWrite() throws {
        let body = try create()
        assertOnce("let duplicate = findDuplicateEvent(title: title, startDate: startDate, isAllDay: isAllDay, calendar: calendar)", in: body)
        assertOnce("if duplicate == nil, let retitled = CreateRetryIdentity.retitledFirstOccurrence( recurring: recurrenceRule != nil, candidates: recurrenceRule == nil ? [] : startWindowEvents(startDate: startDate, calendar: calendar).compactMap(CreateRetryIdentity.Candidate.init), isAllDay: isAllDay, request: retryRequest, series: retrySeriesFacts) { throw EventKitError.createRetryRetitledFirstOccurrence(seriesId: retitled.seriesID, occurrenceId: retitled.occurrenceID) }", in: body)
        assertOnce("if let existing = duplicate {", in: body)
        let scan = try XCTUnwrap(body.range(of: "CreateRetryIdentity.retitledFirstOccurrence("))
        let branch = try XCTUnwrap(body.range(of: "if let existing = duplicate {"))
        XCTAssertLessThan(scan.lowerBound, branch.lowerBound)
        for write in ["eventStore.save(", "applyExclusions(", "CalendarUndoManager.shared.record(", "let event = EKEvent(eventStore: eventStore)"] {
            let at = try XCTUnwrap(body.range(of: write), write)
            XCTAssertLessThan(branch.lowerBound, at.lowerBound, write)
        }
        let lookup = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "private func findDuplicateEvent(", in: try SourcePins.source("EventKit/EventKitManager.swift"))))
        assertOnce("startWindowEvents(startDate: startDate, calendar: calendar).first {", in: lookup)
        let window = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "private func startWindowEvents(", in: try SourcePins.source("EventKit/EventKitManager.swift"))))
        assertOnce("withStart: startDate.addingTimeInterval(-30), end: startDate.addingTimeInterval(30), calendars: [calendar]", in: window)
    }

    /// The fall-through duplicate return answers `CreateRetryIdentity.answeredSeries` for the match,
    /// gated on a recurring request, and through the same request and series read.
    func testTheFallThroughReturnAsksForTheSeries() throws {
        let body = try create()
        assertOnce("let answeredSeries = existing.eventIdentifier.flatMap { id in CreateRetryIdentity.answeredSeries( recurring: recurrenceRule != nil, match: ExclusionRetryTarget.Match(identifier: id, isDetached: existing.isDetached, hasRecurrenceRules: existing.hasRecurrenceRules, timeZone: existing.timeZone, start: existing.startDate), request: retryRequest, series: retrySeriesFacts) }", in: body)
        let ask = try XCTUnwrap(body.range(of: "let answeredSeries ="))
        let answer = try XCTUnwrap(body.range(of: "return CreateEventResult(event: existing, isDuplicate: true, seriesIdentifier: answeredSeries)"))
        XCTAssertLessThan(ask.lowerBound, answer.lowerBound)
    }
}
