import XCTest
@testable import CheICalMCP

/// #520: the series listing and the #503 verdict reach their comparisons through `FirstSeen` and
/// `InstantSet`. The listing runs only against an event store, and a scan written beside the sets
/// would not pass through the counter the scaling tests read, so these pins read the source.
final class LinearListingWiringTests: XCTestCase {
    /// `seriesOccurrences` takes each occurrence once through the set, reading its identifier and
    /// start once, and scans nothing it has listed.
    func testTheListingDeduplicatesThroughTheSet() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "private func seriesOccurrences(", in: file))
        XCTAssertEqual(SourcePins.ranges(of: "var seen = FirstSeen<ListedOccurrenceKey>()", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(
            of: "guard seen.insert(ListedOccurrenceKey(calendarItemIdentifier: event.calendarItemIdentifier, start: event.startDate)) else { return }",
            in: body).count, 1)
        XCTAssertFalse(body.contains("listed.contains"), "no scan of what was listed")
        XCTAssertFalse(body.contains("listed.first"), "no scan of what was listed")
        XCTAssertEqual(SourcePins.ranges(of: "event.calendarItemIdentifier", in: body).count, 1)
        // The set is declared before the ranges are listed, so it spans all of them (an occurrence
        // overlapping two ranges is listed by both), and the insert comes after the series filter and
        // before the occurrence is appended.
        let declared = try XCTUnwrap(body.range(of: "var seen = FirstSeen<ListedOccurrenceKey>()"))
        let loop = try XCTUnwrap(body.range(of: "for range in ranges ?? SeriesExceptionsPlanner.listingRanges(for: window) {"))
        let filter = try XCTUnwrap(body.range(of: "guard UndoPostState.isOccurrence(ids, of: series) else { return }"))
        let insert = try XCTUnwrap(body.range(of: "guard seen.insert("))
        let append = try XCTUnwrap(body.range(of: "listed.append(event)"))
        XCTAssertLessThan(declared.lowerBound, loop.lowerBound)
        XCTAssertLessThan(filter.lowerBound, insert.lowerBound)
        XCTAssertLessThan(insert.lowerBound, append.lowerBound)
    }

    /// `verdict` builds one set per list and asks it; no `sameInstant` scan of a list is left in it.
    func testTheVerdictComparesSlotsThroughTheSets() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/DeletedOccurrenceCheck.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "static func verdict(", in: file))
        XCTAssertFalse(body.contains("sameInstant"), "every slot comparison goes through an InstantSet")
        XCTAssertEqual(SourcePins.ranges(of: "InstantSet(expected, counter: comparisons)", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "InstantSet(observedSlots, counter: comparisons)", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "InstantSet(uneditedSlots, counter: comparisons)", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "InstantSet(", in: body).count, 3)
        // The lists themselves are scanned only once each, never per slot of another list.
        XCTAssertFalse(body.contains("observedSlots.contains {"))
        XCTAssertFalse(body.contains("uneditedSlots.contains"))
        XCTAssertEqual(SourcePins.ranges(of: "expected.contains", in: body).count, 1, "the all-day end check, one pass")
        XCTAssertEqual(SourcePins.ranges(of: "observedSlots.contains(where:", in: body).count, 1, "the off-rule check, one pass")
    }

    /// The set itself compares with `UndoPostState.sameInstant`, element first, as the scans did.
    func testTheSetUsesTheSameComparison() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/InstantSet.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "func contains(_ query: Date) -> Bool", in: file))
        XCTAssertEqual(SourcePins.ranges(of: "UndoPostState.sameInstant(sorted[", in: body).count, 2)
        XCTAssertTrue(body.contains("UndoPostState.sameInstant(sorted[low], query)"))
        XCTAssertTrue(body.contains("UndoPostState.sameInstant(sorted[low - 1], query)"))
    }

    /// The production callers pass no counter: it is the tests' probe.
    func testNoProductionCallerPassesACounter() throws {
        for file in ["EventKit/FirstRemainingOccurrence.swift", "EventKit/EventKitManager.swift", "EventKit/EventKitManager+UndoGuard.swift"] {
            let code = SourcePins.code(try SourcePins.source(file))
            XCTAssertFalse(code.contains("comparisons:"), file)
            XCTAssertFalse(code.contains("ComparisonCounter"), file)
        }
    }
}
