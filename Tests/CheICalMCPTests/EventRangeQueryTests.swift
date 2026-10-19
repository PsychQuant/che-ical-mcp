import CheMCPKit
import XCTest
@testable import CheICalMCP

/// Pure-unit tests for the chunked event range query (#325).
///
/// EventKit shortens a predicate's span to its first 1461 days and returns what falls there,
/// without an error (measured on device, #325 diagnosis). The query layer splits a range into
/// spans of at most 1460 days and merges the results; the fake query below truncates the way
/// EventKit does, so a range the chunker failed to split loses events here as it does on device.
final class EventRangeQueryTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 536_457_600) // 2018-01-01 00:00 UTC

    private struct StubEvent: Equatable {
        let id: String
        let start: Date
        let end: Date
    }

    /// Returns the events overlapping [from, to) after cutting `to` at from + 1461 days, like
    /// `predicateForEvents(withStart:end:calendars:)`.
    private func eventKitLikeQuery(_ events: [StubEvent]) -> (Date, Date) -> [StubEvent] {
        { from, to in
            let cut = min(to, from.addingTimeInterval(1461 * self.day))
            return events.filter { $0.start < cut && $0.end > from }
        }
    }

    private func key(_ event: StubEvent) -> String {
        EventRangeQuery.occurrenceKey(eventIdentifier: event.id, fallbackIdentifier: "", start: event.start)
    }

    // MARK: spans

    func testRangeOf1460DaysIsOneSpan() throws {
        let end = start.addingTimeInterval(1460 * day)
        XCTAssertEqual(try EventRangeQuery.spans(from: start, to: end),
                       [EventRangeQuery.Span(start: start, end: end)])
    }

    func testRangeOf1461DaysIsSplitInTwo() throws {
        let end = start.addingTimeInterval(1461 * day)
        let spans = try EventRangeQuery.spans(from: start, to: end)
        XCTAssertEqual(spans, [EventRangeQuery.Span(start: start, end: start.addingTimeInterval(1460 * day)),
                               EventRangeQuery.Span(start: start.addingTimeInterval(1460 * day), end: end)])
    }

    func testSpansAreContiguousAndNoneExceeds1460Days() throws {
        let end = start.addingTimeInterval(3287 * day)
        let spans = try EventRangeQuery.spans(from: start, to: end)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.first?.start, start)
        XCTAssertEqual(spans.last?.end, end)
        for (left, right) in zip(spans, spans.dropFirst()) {
            XCTAssertEqual(left.end, right.start, "spans must meet with no gap and no overlap")
        }
        XCTAssertTrue(spans.allSatisfy { $0.end.timeIntervalSince($0.start) <= 1460 * day })
    }

    func testEmptyOrInvertedRangeIsPassedThroughAsOneSpan() throws {
        XCTAssertEqual(try EventRangeQuery.spans(from: start, to: start),
                       [EventRangeQuery.Span(start: start, end: start)])
        let earlier = start.addingTimeInterval(-day)
        XCTAssertEqual(try EventRangeQuery.spans(from: start, to: earlier),
                       [EventRangeQuery.Span(start: start, end: earlier)],
                       "an inverted range keeps today's behaviour (EventKit matches nothing), it does not crash")
    }

    func testRangeNeedingMoreThanTheSpanCeilingIsRefusedWithTheLimitNamed() {
        let end = start.addingTimeInterval(Double(EventRangeQuery.maxSpans * 1460 + 1) * day)
        XCTAssertThrowsError(try EventRangeQuery.spans(from: start, to: end)) { error in
            XCTAssertTrue(error is TrustedErrorMessage, "the message must reach the caller unsanitized")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("400 years"), message)
        }
        let atCeiling = start.addingTimeInterval(Double(EventRangeQuery.maxSpans * 1460) * day)
        XCTAssertEqual(try EventRangeQuery.spans(from: start, to: atCeiling).count, EventRangeQuery.maxSpans)
    }

    // MARK: collect

    func testNineYearRangeReturnsEveryEventDespiteTheFourYearCut() throws {
        let dates = [519, 1885, 2708, 3226, 3286].map { start.addingTimeInterval(Double($0) * day) }
        let events = dates.enumerated().map { StubEvent(id: "e\($0.offset)", start: $0.element, end: $0.element.addingTimeInterval(3600)) }
        let end = start.addingTimeInterval(3287 * day)

        // Without chunking, the cut drops everything after the first four years (the device result).
        XCTAssertEqual(eventKitLikeQuery(events)(start, end).map(\.id), ["e0"])

        let found = try EventRangeQuery.collect(from: start, to: end, query: eventKitLikeQuery(events), key: key)
        XCTAssertEqual(found.map(\.id), ["e0", "e1", "e2", "e3", "e4"])
    }

    func testEventAcrossASpanBoundaryIsReturnedOnce() throws {
        let boundary = start.addingTimeInterval(1460 * day)
        let straddling = StubEvent(id: "x", start: boundary.addingTimeInterval(-3600), end: boundary.addingTimeInterval(3600))
        let end = start.addingTimeInterval(2000 * day)
        let found = try EventRangeQuery.collect(from: start, to: end, query: eventKitLikeQuery([straddling]), key: key)
        XCTAssertEqual(found, [straddling])
    }

    func testOccurrencesOfOneSeriesInDifferentSpansAreKept() throws {
        let first = StubEvent(id: "series", start: start.addingTimeInterval(10 * day), end: start.addingTimeInterval(10 * day + 3600))
        let later = StubEvent(id: "series", start: start.addingTimeInterval(1500 * day), end: start.addingTimeInterval(1500 * day + 3600))
        let end = start.addingTimeInterval(2000 * day)
        let found = try EventRangeQuery.collect(from: start, to: end, query: eventKitLikeQuery([first, later]), key: key)
        XCTAssertEqual(found, [first, later], "occurrences share the series identifier; the start keeps them apart")
    }

    // MARK: delete_events_batch by date range

    /// One bound given: the other side reaches 100 years out, not `distantPast` / `distantFuture`
    /// (about a thousand spans, refused by the ceiling), and the range fits the chunked query.
    func testDeletionRangeWithOnlyAfterDateReaches100YearsAhead() throws {
        let range = try XCTUnwrap(EventRangeQuery.deletionRange(after: start, before: nil))
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.end, Calendar.gregorian(in: TimeZone(identifier: "UTC")!).date(byAdding: .year, value: 100, to: start))
        XCTAssertNoThrow(try EventRangeQuery.spans(from: range.start, to: range.end))
    }

    func testDeletionRangeWithOnlyBeforeDateReaches100YearsBack() throws {
        let range = try XCTUnwrap(EventRangeQuery.deletionRange(after: nil, before: start))
        XCTAssertEqual(range.end, start)
        XCTAssertEqual(range.start, Calendar.gregorian(in: TimeZone(identifier: "UTC")!).date(byAdding: .year, value: -100, to: start))
        XCTAssertNoThrow(try EventRangeQuery.spans(from: range.start, to: range.end))
    }

    func testDeletionRangeWithBothBoundsIsUnchanged() throws {
        let end = start.addingTimeInterval(30 * day)
        let range = try XCTUnwrap(EventRangeQuery.deletionRange(after: start, before: end))
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.end, end)
    }

    func testDeletionRangeWithNoBoundIsNil() {
        XCTAssertNil(EventRangeQuery.deletionRange(after: nil, before: nil),
                     "the handler keeps its own error for this case")
    }

    func testDeletionOfUpToTheCeilingIsAccepted() throws {
        let range = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(30 * day))
        XCTAssertNoThrow(try EventRangeQuery.checkDeletionSize(EventRangeQuery.maxDeletionOccurrences, searched: range))
    }

    /// A one-sided range reaches 100 years, so an open-ended daily series alone gives about
    /// 36,500 occurrences — each its own delete and undo entry, and a dry-run preview of the same
    /// size (#325 verify round 1). Above the ceiling the call is refused, dry run included, with the
    /// count and the searched range, before anything is deleted.
    func testDeletionAboveTheCeilingIsRefusedWithTheCountAndTheRange() {
        let range = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(30 * day))
        XCTAssertThrowsError(try EventRangeQuery.checkDeletionSize(EventRangeQuery.maxDeletionOccurrences + 1, searched: range)) { error in
            XCTAssertTrue(error is TrustedErrorMessage, "the message must reach the caller unsanitized")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\(EventRangeQuery.maxDeletionOccurrences + 1)"), message)
            XCTAssertTrue(message.contains("\(EventRangeQuery.maxDeletionOccurrences)"), message)
            XCTAssertTrue(message.contains("2018-01-01"), "the searched range is named: \(message)")
        }
    }

    func testTooWideMessageStatesTheExactCeiling() {
        let message = EventRangeQuery.RangeError.tooWide(days: 200_000).localizedDescription
        XCTAssertTrue(message.contains("146,000 days"), message)
        XCTAssertTrue(message.contains("about 400 years"), message)
    }

    // MARK: wiring

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every range a caller gives (`list_events`, `list_events_quick`, `search_events`,
    /// `find_duplicate_events`, `check_conflicts`, `delete_events_batch` by date range, and the
    /// ±2-year `findSimilarEvents`) must reach EventKit through `events(from:to:calendars:)`.
    /// A direct `predicateForEvents(` anywhere in `Sources/` is allowed only in the functions
    /// listed here: the one-day lookups and the undo scans, whose windows are at most 1460 days
    /// and queried one per window. A new range path in any file cannot bypass the chunking
    /// unnoticed (verify round 1: the first guard read one file and missed generic functions).
    func testNoCallerRangePredicateIsBuiltOutsideTheAllowedFunctions() throws {
        let allowed: [String: Set<String>] = [
            "EventKit/EventRangeQuery.swift": ["events"],
            "EventKit/EventKitManager.swift": ["findDuplicateEvent", "findOccurrence"],
            "EventKit/EventKitManager+SeriesExceptions.swift": ["captureSeriesExceptions", "restoreSeriesExceptions", "seriesHoldsSlot"],
            "EventKit/UndoPostStateGuard.swift": ["modifiedOccurrenceCount"],
        ]
        let sources = repoRoot.appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "the scan must actually read the source tree")
        var offenders: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            var function = ""
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if let match = code.range(of: #"func\s+[A-Za-z0-9_]+\s*[<(]"#, options: .regularExpression) {
                    function = String(code[match].dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: " <("))
                } else if code.range(of: #"(^|\s)init\s*[<(?!]"#, options: .regularExpression) != nil {
                    function = "init"
                }
                if code.contains("predicateForEvents("), !(allowed[relative]?.contains(function) ?? false) {
                    offenders.append("\(relative):\(index + 1) in \(function)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "range queries must go through EventKitManager.events(from:to:calendars:)")
    }

    /// `delete_events_batch` by date range takes its range from `deletionRange`, checks the size,
    /// and reports the searched range on BOTH the dry-run and the deletion path. The handler is
    /// tied to the concrete manager, so its wiring is pinned in the source — inside that handler's
    /// body only, and with the `.distantPast` shorthand caught too (verify round 1).
    func testDeleteByDateRangeHandlerIsBoundedCheckedAndReportsTheRange() throws {
        let server = try String(contentsOf: repoRoot.appendingPathComponent("Sources/CheICalMCP/Server.swift"), encoding: .utf8)
        let start = try XCTUnwrap(server.range(of: "private func handleDeleteEventsBatch("))
        let rest = server[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertNil(body.range(of: #"\.distant(Past|Future)"#, options: .regularExpression),
                     "an open delete bound must not become an unbounded EventKit range")
        XCTAssertTrue(body.contains("EventRangeQuery.deletionRange("))
        XCTAssertTrue(body.contains("EventRangeQuery.checkDeletionSize("), "the size is checked before anything is deleted")
        XCTAssertTrue(body.contains("response.merge(searchedFields)"), "the dry run reports the searched range")
        XCTAssertTrue(body.contains("extraFields: searchedFields"), "the deletion reports the searched range")
    }

    func testOccurrenceKeyFallsBackWhenTheEventIdentifierIsMissing() {
        let a = EventRangeQuery.occurrenceKey(eventIdentifier: nil, fallbackIdentifier: "item-a", start: start)
        let b = EventRangeQuery.occurrenceKey(eventIdentifier: nil, fallbackIdentifier: "item-b", start: start)
        XCTAssertNotEqual(a, b, "two unsaved items at the same start must not collapse into one")
    }
}
