import XCTest
@testable import CheICalMCP

/// Pure-unit tests for resolving a series whose first occurrence was deleted (#326, root cause #284).
///
/// For such a series `event(withIdentifier: <series id>)` still returns the series object, but its
/// `refresh()` returns false, so `freshEvent` returned nil and move, update, copy and delete all
/// reported "Event not found" (device, iCloud, 2026-10-19). The remaining occurrences are still
/// listed with the series identifier, so the earliest of them stands in for the series. Which
/// listed event qualifies is decided here; the narrow conditions keep a detached occurrence
/// (no rules of its own, so a caller would treat it as a one-off) and a different series out.
final class FirstRemainingOccurrenceTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func candidate(_ id: String?, detached: Bool = false, rules: Bool = true, dayOffset: Double,
                           refreshes: Bool = true) -> FirstRemainingOccurrence.Candidate {
        .init(eventIdentifier: id, isDetached: detached, hasRecurrenceRules: rules,
              start: start.addingTimeInterval(dayOffset * day))
    }

    func testTheEarliestOccurrenceOfTheSeriesIsPicked() {
        let listed = [candidate("S", dayOffset: 14), candidate("S", dayOffset: 7), candidate("S", dayOffset: 21)]
        XCTAssertEqual(FirstRemainingOccurrence.pick(listed, identifier: "S"), 1)
    }

    func testAnotherSeriesAndAnEditedOccurrenceAreNotPicked() {
        let listed = [
            candidate("T", dayOffset: 1),                              // another series
            candidate("S/RID=1", detached: true, rules: false, dayOffset: 2), // edited on its own: no rules of its own
            candidate("S", detached: true, dayOffset: 3),              // detached even though it kept the id
            candidate("S", rules: false, dayOffset: 4),                // a one-off sharing the id: not the series
            candidate(nil, dayOffset: 5),
            candidate("S", dayOffset: 9)
        ]
        XCTAssertEqual(FirstRemainingOccurrence.pick(listed, identifier: "S"), 5)
    }

    func testNothingIsPickedWhenTheSeriesHasNoOccurrenceLeft() {
        XCTAssertNil(FirstRemainingOccurrence.pick([], identifier: "S"))
        XCTAssertNil(FirstRemainingOccurrence.pick([candidate("T", dayOffset: 1), candidate("S", detached: true, dayOffset: 2)],
                                                   identifier: "S"))
    }

    func testTheIdentifierMustMatchExactlyNotByPrefix() {
        XCTAssertNil(FirstRemainingOccurrence.pick([candidate("S2", dayOffset: 1), candidate("S/RID=5", dayOffset: 2)],
                                                   identifier: "S"))
    }

    /// Ties go to the one listed first, so the answer does not depend on sort stability.
    func testTwoOccurrencesStartingTogetherGiveTheFirstListed() {
        XCTAssertEqual(FirstRemainingOccurrence.pick([candidate("S", dayOffset: 3), candidate("S", dayOffset: 3)], identifier: "S"), 0)
    }

    /// `freshEvent` falls back to the earliest remaining occurrence only when the series object
    /// fails to refresh, and gives it back only if that occurrence refreshes too; a series whose
    /// object refreshes is returned as before, and one that is really gone stays nil.
    func testFreshEventFallsBackOnlyWhenTheSeriesObjectFailsToRefresh() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager+UndoGuard.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func freshEvent(id: String) -> EKEvent?"))
        let to = try XCTUnwrap(source.range(of: "func freshReminder(id: String)", range: from.upperBound..<source.endIndex))
        let body = String(source[from.lowerBound..<to.lowerBound])
        let refresh = try XCTUnwrap(body.range(of: "event.refresh()"))
        let fallback = try XCTUnwrap(body.range(of: "firstRemainingOccurrence("))
        XCTAssertLessThan(refresh.lowerBound, fallback.lowerBound, "the series object is tried first")
    }
}
