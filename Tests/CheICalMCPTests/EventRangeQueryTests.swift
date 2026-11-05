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

    /// A zero-length event exactly on a span boundary overlaps neither half-open span under a strict
    /// overlap test (verify round 3); each span after the first reaches one second back, and the
    /// key drops what both spans return. Nothing before the caller's start is queried.
    func testZeroLengthEventOnASpanBoundaryIsFound() throws {
        let boundary = start.addingTimeInterval(1460 * day)
        let instant = StubEvent(id: "z", start: boundary, end: boundary)
        let before = StubEvent(id: "b", start: start.addingTimeInterval(-2), end: start.addingTimeInterval(-1))
        let end = start.addingTimeInterval(2000 * day)
        var queried: [Date] = []
        let found = try EventRangeQuery.collect(from: start, to: end,
                                                query: { queried.append($0); return self.eventKitLikeQuery([instant, before])($0, $1) },
                                                key: key)
        XCTAssertEqual(found, [instant])
        XCTAssertEqual(queried.first, start)
        XCTAssertTrue(queried.allSatisfy { $0 >= start })
    }

    func testOccurrencesOfOneSeriesInDifferentSpansAreKept() throws {
        let first = StubEvent(id: "series", start: start.addingTimeInterval(10 * day), end: start.addingTimeInterval(10 * day + 3600))
        let later = StubEvent(id: "series", start: start.addingTimeInterval(1500 * day), end: start.addingTimeInterval(1500 * day + 3600))
        let end = start.addingTimeInterval(2000 * day)
        let found = try EventRangeQuery.collect(from: start, to: end, query: eventKitLikeQuery([first, later]), key: key)
        XCTAssertEqual(found, [first, later], "occurrences share the series identifier; the start keeps them apart")
    }

    // MARK: delete_events_batch by date range

    // MARK: #332: the read bound

    /// `count` distinct occurrences per span, each starting inside its span.
    private func perSpan(_ count: Int) -> (Date, Date) -> [StubEvent] {
        { from, to in
            (0..<count).map { StubEvent(id: "\(from.timeIntervalSince1970)-\($0)", start: from.addingTimeInterval(Double($0) + 2),
                                        end: from.addingTimeInterval(Double($0) + 3)) }
        }
    }

    /// Over a range wider than `previousCutDays`, the read passes one below and exactly at
    /// `maxEventsRead` and stops at one over.
    func testTheReadBoundBoundaryOverAWideRange() throws {
        // Three spans: the first holds the count, the others nothing, so "after the span" is exact.
        let end = start.addingTimeInterval(Double(EventRangeQuery.maxSpanDays * 3) * day)
        func read(_ count: Int) throws -> [StubEvent] {
            var calls = 0
            return try EventRangeQuery.collect(from: start, to: end, query: { from, to in
                calls += 1
                return calls == 1 ? self.perSpan(count)(from, to) : []
            }, key: key)
        }
        XCTAssertEqual(try read(EventRangeQuery.maxEventsRead - 1).count, EventRangeQuery.maxEventsRead - 1)
        XCTAssertEqual(try read(EventRangeQuery.maxEventsRead).count, EventRangeQuery.maxEventsRead)
        XCTAssertThrowsError(try read(EventRangeQuery.maxEventsRead + 1)) { error in
            guard case .tooManyEvents(let limit, let from, let to, let readThrough)? = error as? EventRangeQuery.RangeError else {
                return XCTFail("expected tooManyEvents, got \(error)")
            }
            XCTAssertEqual(limit, EventRangeQuery.maxEventsRead)
            XCTAssertEqual(from, self.start)
            XCTAssertEqual(to, end)
            XCTAssertEqual(readThrough, self.start.addingTimeInterval(Double(EventRangeQuery.maxSpanDays) * self.day))
        }
    }

    /// The read stops after the span that passed the bound, not at the end of the range, and a span
    /// is read whole: the count can pass the bound by up to one span's worth.
    func testTheReadStopsAfterTheSpanThatPassesTheBound() throws {
        let end = start.addingTimeInterval(Double(EventRangeQuery.maxSpanDays * 50) * day)
        let perSpanCount = EventRangeQuery.maxEventsRead / 4
        var queried = 0
        XCTAssertThrowsError(try EventRangeQuery.collect(from: start, to: end, query: { queried += 1; return self.perSpan(perSpanCount)($0, $1) }, key: key))
        XCTAssertEqual(queried, 5, "4 × \(perSpanCount) is the bound, not over it; the fifth span passes it")
    }

    /// An occurrence two spans both return counts once toward the bound.
    func testTheReadBoundCountsEachOccurrenceOnce() throws {
        let end = start.addingTimeInterval(Double(EventRangeQuery.maxSpanDays * 2) * day)
        let same = perSpan(EventRangeQuery.maxEventsRead)(start, end)
        XCTAssertEqual(try EventRangeQuery.collect(from: start, to: end, query: { _, _ in same }, key: key).count,
                       EventRangeQuery.maxEventsRead)
    }

    /// The refusal is a trusted message that states the range, the bound, that it is approximate,
    /// that nothing was returned or deleted, and both ways out, on the tool that spells it differently too.
    func testTheReadBoundMessage() {
        let end = start.addingTimeInterval(36_500 * day)
        let through = start.addingTimeInterval(1460 * day)
        let error = EventRangeQuery.RangeError.tooManyEvents(limit: 20_000, from: start, to: end, readThrough: through)
        XCTAssertTrue((error as Error) is TrustedErrorMessage)
        let text = error.localizedDescription
        for phrase in ["more than 20,000", "at most about", "Nothing was returned or deleted", "Narrow the range",
                       "calendar_name", "calendar_names on find_duplicate_events",
                       EventRangeQuery.localText(start), EventRangeQuery.localText(end), EventRangeQuery.localText(through)] {
            XCTAssertTrue(text.contains(phrase), "\(phrase): \(text)")
        }
    }

    /// A range of at most `previousCutDays` is not bounded, whatever it holds (as before #325).
    func testANarrowRangeIsNotBoundedOnTheRead() throws {
        // 1461 days: two spans, each returning more than the bound on its own.
        let end = start.addingTimeInterval(Double(EventRangeQuery.previousCutDays) * day)
        let found = try EventRangeQuery.collect(from: start, to: end, query: perSpan(EventRangeQuery.maxEventsRead + 5), key: key)
        XCTAssertEqual(found.count, 2 * (EventRangeQuery.maxEventsRead + 5))
    }

    /// One second past `previousCutDays` is the first range the bound applies to.
    func testTheReadBoundStartsJustPastThePreviousCut() {
        let end = start.addingTimeInterval(Double(EventRangeQuery.previousCutDays) * day + 1)
        XCTAssertThrowsError(try EventRangeQuery.collect(from: start, to: end, query: perSpan(EventRangeQuery.maxEventsRead + 1), key: key))
    }

    // MARK: #332: the output bound of list_events / search_events

    func testTheOutputBoundAppliesOnlyToAWideRangeWithoutACallerLimit() {
        let narrow = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(Double(EventRangeQuery.previousCutDays) * day))
        let wide = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(Double(EventRangeQuery.previousCutDays + 1) * day))
        let over = Array(0...EventRangeQuery.defaultWideOutput)   // one more than the default
        let exact = Array(over.dropLast())

        XCTAssertEqual(EventRangeQuery.bounded(over, requested: nil, searched: narrow).rows.count, over.count)
        XCTAssertNil(EventRangeQuery.bounded(over, requested: nil, searched: narrow).defaultLimit)

        let cut = EventRangeQuery.bounded(over, requested: nil, searched: wide)
        XCTAssertEqual(cut.rows, exact)
        XCTAssertEqual(cut.defaultLimit, EventRangeQuery.defaultWideOutput)

        XCTAssertEqual(EventRangeQuery.bounded(exact, requested: nil, searched: wide).rows, exact)
        XCTAssertNil(EventRangeQuery.bounded(exact, requested: nil, searched: wide).defaultLimit, "nothing was left out")

        let large = EventRangeQuery.bounded(over, requested: 2000, searched: wide)
        XCTAssertEqual(large.rows, over, "the caller's limit wins")
        XCTAssertNil(large.defaultLimit)
        let small = EventRangeQuery.bounded(over, requested: 3, searched: narrow)
        XCTAssertEqual(small.rows, [0, 1, 2])
        XCTAssertNil(small.defaultLimit)

        XCTAssertEqual(EventRangeQuery.defaultWideOutput, 500)
        XCTAssertEqual(EventRangeQuery.maxEventsRead, 20_000)
    }

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

    private let wide = 3000.0   // days: wider than EventKit's old 1461-day cut
    private let narrow = 1461.0 // days: what EventKit already returned in full before #325

    /// Ranges of at most 1461 days were complete before #325 and are not limited now: the
    /// ceiling applies only where #325 widened what a call reaches (verify round 2).
    func testNarrowRangeIsNotLimitedWhateverItsSize() {
        let range = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(narrow * day))
        XCTAssertNoThrow(try EventRangeQuery.checkDeletionSize(operations: 50_000, searched: range))
        XCTAssertNil(EventRangeQuery.previewLimit(searched: range))
    }

    func testWideRangeAcceptsUpToTheCeiling() {
        let range = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(wide * day))
        XCTAssertNoThrow(try EventRangeQuery.checkDeletionSize(operations: EventRangeQuery.maxDeletionOccurrences, searched: range))
        XCTAssertEqual(EventRangeQuery.previewLimit(searched: range), EventRangeQuery.maxDeletionOccurrences)
    }

    /// Above the ceiling a wide range is refused, dry run included, with the count and the range
    /// in the same local form as `searched_from` / `searched_to`, and only "narrow the range" as
    /// advice: pointing at a whole-series delete would invite deleting more than was asked.
    func testWideRangeAboveTheCeilingIsRefusedWithTheCountAndTheRange() {
        let range = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(wide * day))
        let count = EventRangeQuery.maxDeletionOccurrences + 1
        XCTAssertThrowsError(try EventRangeQuery.checkDeletionSize(operations: count, searched: range)) { error in
            XCTAssertTrue(error is TrustedErrorMessage, "the message must reach the caller unsanitized")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\(count)"), message)
            XCTAssertTrue(message.contains("\(EventRangeQuery.maxDeletionOccurrences)"), message)
            XCTAssertTrue(message.contains(EventRangeQuery.localText(range.start)) && message.contains(EventRangeQuery.localText(range.end)), message)
            XCTAssertFalse(message.contains("delete_event") || message.contains("span 'all'"), "no advice to delete more: \(message)")
        }
    }

    /// What is counted is what the call would delete: events without an identifier are skipped by
    /// the delete path; span "all" deletes each series once, and span "future" too (verify round 3),
    /// What is counted is what the call would delete, at most: events without an identifier are
    /// skipped by the delete path; span "all" deletes each series once, and span "future" too, from
    /// its earliest listed slot (verify rounds 3-6).
    func testDeletionOperationsCountWhatTheCallWouldDelete() {
        let listed: [(identifier: String?, start: Date, slot: Date?)] = [
            ("s1", start.addingTimeInterval(2 * day), nil), ("s1", start, nil), ("s1", start.addingTimeInterval(day), nil),
            ("s2", start, nil), (nil, start, nil), ("one-off", start, nil)
        ]
        func count(_ span: String) -> Int {
            EventRangeQuery.deletionOperations(EventRangeQuery.deletionItems(listed, span: span).map(\.identifier), span: span)
        }
        XCTAssertEqual(count("this"), 5)
        XCTAssertEqual(count("all"), 3)
        XCTAssertEqual(count("future"), 3)
    }

    /// Span "future" sends every listed occurrence in slot order (verify rounds 4-5): the removal
    /// from a series' earliest slot reaches all the rest, so each series is deleted once, as
    /// counted. An occurrence moved earlier than its slot sorts by its slot. Other spans keep the
    /// listed order.
    func testFutureSpanSendsEveryOccurrenceInSlotOrder() {
        let movedSlot = start.addingTimeInterval(9 * day)
        let listed: [(identifier: String?, start: Date, slot: Date?)] = [
            ("s1", start.addingTimeInterval(2 * day), start.addingTimeInterval(2 * day)),
            ("one-off", start, nil),
            ("s1", start.addingTimeInterval(-day), movedSlot),          // moved from day 9 to day -1
            ("s1", start.addingTimeInterval(day), start.addingTimeInterval(day)),
            (nil, start, nil)
        ]
        let future = EventRangeQuery.deletionItems(listed, span: "future")
        XCTAssertEqual(future.map(\.slot), [nil, start.addingTimeInterval(day), start.addingTimeInterval(2 * day), movedSlot])
        XCTAssertEqual(future.map(\.occurrenceDate), [start, start.addingTimeInterval(day), start.addingTimeInterval(2 * day), start.addingTimeInterval(-day)],
                       "the lookup still uses each occurrence's start")
        XCTAssertEqual(EventRangeQuery.deletionItems(listed, span: "this").map(\.identifier), ["s1", "one-off", "s1", "s1"])
    }

    /// The local form the handler reports `searched_from` / `searched_to` in, so the refusal and
    /// those fields cannot disagree.
    /// #304: the host-zone wall clock, Gregorian with ASCII digits whatever the host locale.
    func testLocalTextIsTheResponseDateForm() {
        XCTAssertEqual(EventRangeQuery.localText(start), GregorianLocalText.of(start))
    }

    /// find_duplicate_events over a range wider than the old cut stops at about the old worst case
    /// (verify round 3): two calendars of the same daily series over four years, any tolerance.
    func testDuplicateComparisonLimitAppliesOnlyToWideRanges() {
        let narrow = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(self.narrow * day))
        let wide = EventRangeQuery.Span(start: start, end: start.addingTimeInterval(self.wide * day))
        XCTAssertNil(EventRangeQuery.comparisonLimit(searched: narrow))
        XCTAssertEqual(EventRangeQuery.comparisonLimit(searched: wide), EventRangeQuery.maxDuplicateComparisons)
        let oldWorstCase = Double(1461 * 1461)
        XCTAssertEqual(Double(EventRangeQuery.maxDuplicateComparisons), oldWorstCase, accuracy: 0.1 * oldWorstCase,
                       "about what a four-year range could already compare")
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
            // #322: the delete-undo exceptions layer's two EventKit queries, moved here from
            // EventKitManager+SeriesExceptions.swift. `slotHolders` builds its range from one
            // occurrence; `events(in:inCalendarOf:)` takes one, and
            // `testTheExceptionsRangePrimitiveOnlyGetsTheBoundedWindows` pins what its callers pass.
            "EventKit/SeriesExceptionsStoreSource.swift": ["events", "slotHolders"],
            // #326: the stand-in search lists the series' own scan window and a year each side, a
            // range the server derives from the series, not one a caller gave.
            "EventKit/FirstRemainingOccurrence.swift": ["seriesOccurrences"],
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
                } else if let member = code.range(of: #"^    (?:(?:static|private|fileprivate|internal|public|lazy|override|nonisolated)\s+)*(?:var|let)\s+[A-Za-z0-9_]+|^\s*(?:subscript|deinit)\b"#, options: .regularExpression) {
                    // A type member that is not a function (verify round 2): reset the attribution
                    // so code in it is not credited to the function above it.
                    function = String(code[member]).trimmingCharacters(in: .whitespaces)
                }
                if code.contains("predicateForEvents("), !(allowed[relative]?.contains(function) ?? false) {
                    offenders.append("\(relative):\(index + 1) in \(function)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "range queries must go through EventKitManager.events(from:to:calendars:)")
    }

    /// #322 (PR #400 verify round 1): `SeriesExceptionsStoreSource.events(in:inCalendarOf:)` runs
    /// one EventKit query over whatever range it is given, so the allow-list above would admit a
    /// caller range through it. Its only callers are the two in `SeriesExceptionsUndo`, and each
    /// passes a bounded form: a listing range of the series' scan window
    /// (`SeriesExceptionsPlanner.listingRanges(for:)`: the window, at most 1460 days, and 366 days on
    /// each side) or the recorded window (`exceptions.window`, a scan window). A new caller, or a
    /// caller passing another range, fails here.
    func testTheExceptionsRangePrimitiveOnlyGetsTheBoundedWindows() throws {
        // PR #400 verify round 2: every `inCalendarOf:` label in Sources is enumerated (comments and
        // strings blanked), so a call whose range is itself a call, or an unqualified call inside a
        // store, cannot slip past a pattern. Each label is a declaration of the requirement or a
        // call of it; for a call, the range argument is the text between its `events(in:` and its
        // `, inCalendarOf:`, sliced by position, so nested parentheses do not matter.
        let sources = repoRoot.appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var declarations: [String] = []
        var calls: [String] = []
        for file in files {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            for label in SourcePins.ranges(of: "inCalendarOf", in: code) {
                let before = code[..<label.lowerBound]
                let open = try XCTUnwrap(before.range(of: "events(in", options: .backwards),
                                         "\(file.lastPathComponent): `inCalendarOf` outside an `events(in` call or declaration")
                var argument = String(code[open.upperBound..<label.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if argument.hasPrefix(":") { argument = String(argument.dropFirst()).trimmingCharacters(in: .whitespaces) }
                let isDeclaration = code[..<open.lowerBound].hasSuffix("func ")
                if isDeclaration {
                    declarations.append(file.lastPathComponent + ": " + argument)
                } else {
                    calls.append(file.lastPathComponent + ": " + argument)
                }
            }
        }
        XCTAssertEqual(declarations.sorted(), [
            "SeriesExceptionsStoreSource.swift: range: DateInterval,",
            "SeriesExceptionsStoreSource.swift: range: DateInterval,",
        ], "the requirement and the EventKit adapter only")
        XCTAssertEqual(calls.sorted(), [
            "SeriesExceptionsUndo.swift: exceptions.window,",
            "SeriesExceptionsUndo.swift: range,",
        ], "a listing range of the scan window, or the recorded window")
        let undo = SourcePins.code(try String(contentsOf: sources.appendingPathComponent("EventKit/SeriesExceptionsUndo.swift"), encoding: .utf8))
        let capture = try XCTUnwrap(SourcePins.body(of: "static func capture<", in: undo))
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"for range in SeriesExceptionsPlanner\.listingRanges\(for: window\) \{\s*for occurrence in store\.events\(in: range, inCalendarOf: series\)"#, in: capture).count, 1,
                       "the capture's range is a listing range of the series' scan window")
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"let window = store\.scanWindow\(of: series\)"#, in: capture).count, 1)
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
        let check = try XCTUnwrap(body.range(of: "EventRangeQuery.checkDeletionSize("), "the size is checked")
        let dryRunBranch = try XCTUnwrap(body.range(of: "if dryRun {", range: body.range(of: "deletionRange(")!.upperBound..<body.endIndex))
        XCTAssertLessThan(check.lowerBound, dryRunBranch.lowerBound, "the size is checked before the dry run returns")
        XCTAssertTrue(body.contains("\"deletions\""), "the dry run reports the number the ceiling is compared against")
        XCTAssertTrue(body.contains("EventRangeQuery.deletionItems("), "the deletion and its count come from one item list")
        XCTAssertTrue(body.contains("slots: deletionItems.map(\\.slot)"), "the slots reach deleteEventsBatch (round 6)")
        XCTAssertTrue(body.contains("response.merge(searchedFields)"), "the dry run reports the searched range")
        XCTAssertTrue(body.contains("extraFields: searchedFields"), "the deletion reports the searched range")
    }

    /// Two occurrences of one series at the same start (one edited onto the other's slot, on a store
    /// that keeps the series identifier) are different occurrences; the same occurrence seen by two
    /// spans is one (verify round 2).
    func testOccurrenceKeyKeepsDifferentOccurrencesAtTheSameStartApart() {
        let slotA = start.addingTimeInterval(day), slotB = start.addingTimeInterval(2 * day)
        let edited = EventRangeQuery.occurrenceKey(eventIdentifier: "s", fallbackIdentifier: "", start: slotB, occurrenceDate: slotA)
        let own = EventRangeQuery.occurrenceKey(eventIdentifier: "s", fallbackIdentifier: "", start: slotB, occurrenceDate: slotB)
        XCTAssertNotEqual(edited, own)
        XCTAssertEqual(own, EventRangeQuery.occurrenceKey(eventIdentifier: "s", fallbackIdentifier: "", start: slotB, occurrenceDate: slotB))
    }

    func testOccurrenceKeyFallsBackWhenTheEventIdentifierIsMissing() {
        let a = EventRangeQuery.occurrenceKey(eventIdentifier: nil, fallbackIdentifier: "item-a", start: start)
        let b = EventRangeQuery.occurrenceKey(eventIdentifier: nil, fallbackIdentifier: "item-b", start: start)
        XCTAssertNotEqual(a, b, "two unsaved items at the same start must not collapse into one")
    }
}
