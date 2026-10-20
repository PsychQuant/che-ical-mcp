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
                           slotOffset: Double? = nil) -> FirstRemainingOccurrence.Candidate {
        .init(eventIdentifier: id, isDetached: detached, hasRecurrenceRules: rules,
              start: start.addingTimeInterval(dayOffset * day),
              slot: slotOffset.map { start.addingTimeInterval($0 * day) })
    }

    func testTheEarliestOccurrenceOfTheSeriesIsPicked() {
        let listed = [candidate("S", dayOffset: 14), candidate("S", dayOffset: 7), candidate("S", dayOffset: 21)]
        XCTAssertEqual(FirstRemainingOccurrence.pick(listed, identifier: "S"), 1)
    }

    func testAnotherSeriesAndAnEditedOccurrenceAreNotPicked() {
        let listed = [
            candidate("T", dayOffset: 1),                              // another series
            candidate("S/RID=1", detached: true, rules: false, dayOffset: 12, slotOffset: 12), // edited, after the stand-in
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

    /// An occurrence edited on its own whose slot is before the stand-in would be left behind by a
    /// write from the stand-in (a delete or update with `.futureEvents` covers its slot onward):
    /// the call would report success with part of the series untouched (verify round 1, #326). The
    /// series then stays not found, and the edited occurrence's own id is the way in.
    func testASeriesWithAnEditedOccurrenceBeforeTheStandInIsNotResolved() {
        let listed = [candidate("S", dayOffset: 14),
                      candidate("S/RID=5", detached: true, rules: false, dayOffset: 8, slotOffset: 7)]
        XCTAssertNil(FirstRemainingOccurrence.pick(listed, identifier: "S"))
    }

    /// Judged by its slot, not by where it was moved: moved later than the stand-in but originally
    /// before it still blocks; moved earlier but originally after it does not.
    func testTheEditedOccurrenceIsJudgedByItsSlot() {
        XCTAssertNil(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S/RID=5", detached: true, rules: false, dayOffset: 30, slotOffset: 7)], identifier: "S"))
        XCTAssertEqual(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S/RID=5", detached: true, rules: false, dayOffset: 3, slotOffset: 21)], identifier: "S"), 0)
        XCTAssertEqual(FirstRemainingOccurrence.pick(
            [candidate("S", dayOffset: 14), candidate("S/RID=5", detached: true, rules: false, dayOffset: 30, slotOffset: 21)], identifier: "S"), 0)
    }

    /// The resolution flow of `freshEvent`, with lookup, refresh and the stand-in injected
    /// (closure seam, #182): the cases a source-string check cannot tell apart (verify round 1).
    func testResolutionReturnsTheStoredObjectWhenItRefreshesAndNeverAsksForAStandIn() {
        var askedStandIn = false
        let result: String? = FirstRemainingOccurrence.resolve(stored: "series", refresh: { _ in true },
                                                               standIn: { _ in askedStandIn = true; return "occurrence" })
        XCTAssertEqual(result, "series")
        XCTAssertFalse(askedStandIn)
    }

    func testResolutionReturnsTheStandInWhenTheStoredObjectDoesNotRefresh() {
        XCTAssertEqual(FirstRemainingOccurrence.resolve(stored: "series", refresh: { _ in false }, standIn: { _ in "occurrence" }),
                       "occurrence")
    }

    func testResolutionIsNilWhenNothingIsStoredOrNoStandInExists() {
        XCTAssertNil(FirstRemainingOccurrence.resolve(stored: String?.none, refresh: { _ in true }, standIn: { _ in "occurrence" }))
        XCTAssertNil(FirstRemainingOccurrence.resolve(stored: "series", refresh: { _ in false }, standIn: { _ in nil }))
    }

    /// `freshEvent` and the dry-run preview (`getEvent`) both resolve through it; the preview used
    /// to read the unrefreshed object and so showed the deleted occurrence's date.
    func testGetEventResolvesThroughFreshEvent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func getEvent(identifier: String) async throws -> EKEvent {"))
        let to = try XCTUnwrap(source.range(of: "// MARK: - Search and Conflict Detection", range: from.upperBound..<source.endIndex))
        XCTAssertTrue(source[from.lowerBound..<to.lowerBound].contains("freshEvent(id: identifier)"))
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
        // The branches themselves are tested through `resolve`; this pins that freshEvent uses it.
        XCTAssertTrue(body.contains("FirstRemainingOccurrence.resolve("))
        XCTAssertTrue(body.contains("firstRemainingOccurrence(of:"))
    }
}
