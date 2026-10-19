import XCTest
@testable import CheICalMCP

/// Pure-unit tests for skipping the listed occurrences a span "future" delete already removed
/// (#325 verify rounds 3-4).
///
/// Removing an occurrence with `.futureEvents` removes the rest of its series, so each later
/// listed occurrence used to cost one EventKit lookup and come back as a failure: about 36,500
/// for a daily series over the 100-year one-sided horizon. Round 3 sent only the earliest
/// occurrence of each series, which dropped the old fallback: when that one failed, or
/// `findOccurrence` (which matches by day) removed a later occurrence of the same day, the rest
/// was left while the call reported success. Every occurrence is sent again now; one is skipped
/// only when a removal of exactly the requested occurrence already reached its slot.
final class FutureDeletionCoverageTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testNothingIsCoveredBeforeARemoval() {
        let coverage = FutureDeletionCoverage()
        XCTAssertFalse(coverage.covers(identifier: "s", slot: start))
        XCTAssertFalse(coverage.covers(identifier: "s", slot: nil))
    }

    func testRemovalOfTheRequestedOccurrenceCoversItsSlotAndLater() {
        var coverage = FutureDeletionCoverage()
        coverage.recordRemoval(identifier: "s", requested: start, removedStart: start, removedSlot: start)
        XCTAssertTrue(coverage.covers(identifier: "s", slot: start))
        XCTAssertTrue(coverage.covers(identifier: "s", slot: start.addingTimeInterval(day)))
        XCTAssertFalse(coverage.covers(identifier: "s", slot: start.addingTimeInterval(-day)), "an earlier slot is not removed")
        XCTAssertFalse(coverage.covers(identifier: "other", slot: start.addingTimeInterval(day)), "another series is not removed")
    }

    /// `findOccurrence` matches by day: on a series with two occurrences that day it can return the
    /// later one. Nothing is recorded then, so the earlier one is still tried.
    func testRemovalOfAnotherOccurrenceThanRequestedCoversNothing() {
        var coverage = FutureDeletionCoverage()
        let later = start.addingTimeInterval(3600)
        coverage.recordRemoval(identifier: "s", requested: start, removedStart: later, removedSlot: later)
        XCTAssertFalse(coverage.covers(identifier: "s", slot: later))
        XCTAssertFalse(coverage.covers(identifier: "s", slot: start.addingTimeInterval(day)))
    }

    /// An occurrence moved earlier from a later slot (on a store that keeps the series identifier
    /// for it): its removal reaches from its slot on, not from its new start, so the occurrences
    /// listed between the two are still tried.
    /// An occurrence whose slot is before the covered one but which was moved past it (a store that
    /// keeps the series identifier for it) is not reached by the removal, and is tried (round 5).
    func testAnOccurrenceMovedPastTheCoveredSlotIsJudgedByItsSlot() {
        var coverage = FutureDeletionCoverage()
        coverage.recordRemoval(identifier: "s", requested: start.addingTimeInterval(5 * day),
                               removedStart: start.addingTimeInterval(5 * day), removedSlot: start.addingTimeInterval(5 * day))
        XCTAssertFalse(coverage.covers(identifier: "s", slot: start.addingTimeInterval(3 * day)), "slot day 3, moved to day 20")
        XCTAssertTrue(coverage.covers(identifier: "s", slot: start.addingTimeInterval(6 * day)))
    }

    func testAMovedOccurrenceCoversFromItsSlotNotItsStart() {
        var coverage = FutureDeletionCoverage()
        let movedTo = start, slot = start.addingTimeInterval(10 * day)
        coverage.recordRemoval(identifier: "s", requested: movedTo, removedStart: movedTo, removedSlot: slot)
        XCTAssertFalse(coverage.covers(identifier: "s", slot: start.addingTimeInterval(2 * day)))
        XCTAssertTrue(coverage.covers(identifier: "s", slot: slot))
    }

    /// An occurrence edited on its own (`<series>/RID=<slot seconds>` on iCloud) is removed with its
    /// series when the series was removed from an earlier slot (device, 2026-10-20: it came back as
    /// a failed "Event not found"). A slot before the covered one, or another series, is not.
    func testAnOccurrenceEditedOnItsOwnIsCoveredByItsSeriesSlot() {
        var coverage = FutureDeletionCoverage()
        coverage.recordRemoval(identifier: "S", requested: start, removedStart: start, removedSlot: start)
        let later = Int(start.addingTimeInterval(7 * day).timeIntervalSinceReferenceDate)
        let earlier = Int(start.addingTimeInterval(-7 * day).timeIntervalSinceReferenceDate)
        XCTAssertTrue(coverage.covers(identifier: "S/RID=\(later)", slot: start.addingTimeInterval(-30 * day)),
                      "the slot decides, not where the edited occurrence was moved")
        XCTAssertFalse(coverage.covers(identifier: "S/RID=\(earlier)", slot: start.addingTimeInterval(day)))
        XCTAssertFalse(coverage.covers(identifier: "T/RID=\(later)", slot: start.addingTimeInterval(7 * day)))
        XCTAssertFalse(coverage.covers(identifier: "S/RID=x", slot: start.addingTimeInterval(7 * day)))
    }

    func testTheEarliestCoveredSlotIsKept() {
        var coverage = FutureDeletionCoverage()
        coverage.recordRemoval(identifier: "s", requested: start.addingTimeInterval(5 * day),
                               removedStart: start.addingTimeInterval(5 * day), removedSlot: start.addingTimeInterval(5 * day))
        coverage.recordRemoval(identifier: "s", requested: start, removedStart: start, removedSlot: start)
        XCTAssertTrue(coverage.covers(identifier: "s", slot: start.addingTimeInterval(day)))
    }

    /// The span "future" path of deleteEventsBatch consults the coverage before any EventKit lookup
    /// and records only after a successful removal.
    func testDeleteEventsBatchSkipsCoveredItemsBeforeLookingThemUp() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let from = try XCTUnwrap(source.range(of: "func deleteEventsBatch("))
        let to = try XCTUnwrap(source.range(of: "func findDuplicateEvents(", range: from.upperBound..<source.endIndex))
        let body = String(source[from.lowerBound..<to.lowerBound])
        let skip = try XCTUnwrap(body.range(of: "coverage.covers("))
        let lookup = try XCTUnwrap(body.range(of: "freshEvent(id: item.identifier)"))
        XCTAssertLessThan(skip.lowerBound, lookup.lowerBound)
        let remove = try XCTUnwrap(body.range(of: "try eventStore.remove(occurrence, span: span)"))
        let record = try XCTUnwrap(body.range(of: "coverage.recordRemoval("))
        XCTAssertLessThan(remove.lowerBound, record.lowerBound)
    }
}
