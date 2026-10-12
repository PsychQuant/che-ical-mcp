import XCTest
import EventKit
@testable import CheICalMCP

/// #285: what a whole-series delete records about the series' exceptions (occurrences deleted or
/// edited on their own), and which slots undo must remove again from the series it recreates.
/// Pure value tests: no store, no EventKit round trip. Expected values are literals.
final class SeriesExceptionsTests: XCTestCase {

    // MARK: - literals

    private func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private let series = UndoPostState.OccurrenceIDs(eventIdentifier: "SERIES", externalIdentifier: "UID")

    /// A weekly series at 10:00 +08:00 on 2028-04-03, 04-10, 04-17, 04-24.
    private let slot1 = "2028-04-03T10:00:00+08:00"
    private let slot2 = "2028-04-10T10:00:00+08:00"
    private let slot3 = "2028-04-17T10:00:00+08:00"
    private let slot4 = "2028-04-24T10:00:00+08:00"

    private func snapshot(title: String, start: String) -> EventSnapshot {
        UndoSnapshotFixtures.event(title: title, startDate: at(start))
    }

    private func observed(ids: UndoPostState.OccurrenceIDs? = nil, detached: Bool, start: String,
                          occurrenceDate: String? = nil, title: String = "Standup") -> SeriesExceptionsPlanner.ObservedOccurrence {
        SeriesExceptionsPlanner.ObservedOccurrence(
            ids: ids ?? series, isDetached: detached, occurrenceDate: occurrenceDate.map(at),
            startDate: at(start), snapshot: snapshot(title: title, start: start))
    }

    private var window: DateInterval {
        DateInterval(start: at("2028-04-02T10:00:00+08:00"), end: at("2028-04-25T10:00:00+08:00"))
    }

    // MARK: - snapshot default

    func testSnapshotCarriesNoExceptionsByDefault() {
        XCTAssertNil(UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4).exceptions)
    }

    func testWithExceptionsReturnsACopyAndLeavesTheOriginalAlone() {
        let original = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 4)
        let exceptions = SeriesExceptions(window: window, keptSlots: [at(slot1)], detached: [])
        let copy = original.withExceptions(exceptions)
        XCTAssertNil(original.exceptions)
        XCTAssertEqual(copy.exceptions?.keptSlots, [at(slot1)])
        XCTAssertEqual(copy.title, "Standup")
    }

    // MARK: - capture

    func testCaptureKeepsUndetachedSlotsAndSeparatesDetachedOnes() {
        // Four slots; the 3rd was deleted on its own (absent), the 2nd edited on its own.
        let edited = observed(ids: .init(eventIdentifier: "SERIES/RID=860637600", externalIdentifier: "UID/RID=860637600"),
                              detached: true, start: slot2, occurrenceDate: slot2, title: "Standup (moved room)")
        let result = SeriesExceptionsPlanner.capture(
            [observed(detached: false, start: slot1, occurrenceDate: slot1),
             edited,
             observed(detached: false, start: slot4, occurrenceDate: slot4)],
            of: series, window: window)
        XCTAssertEqual(result.keptSlots, [at(slot1), at(slot4)])
        XCTAssertEqual(result.detached.count, 1)
        XCTAssertEqual(result.detached[0].snapshot.title, "Standup (moved room)")
        XCTAssertEqual(result.window, window)
    }

    func testCaptureTakesADetachedOccurrencesSlotFromItsRIDNotItsMovedStart() {
        // `/RID=` is the slot in seconds since 2001-01-01 00:00 UTC: 837050400 is 2027-07-12T10:00:00+08:00
        // (the literal UndoPostState.originalSlot's own doc records from the device).
        let moved = observed(ids: .init(eventIdentifier: "SERIES/RID=837050400", externalIdentifier: nil),
                             detached: true, start: "2027-07-12T10:30:00+08:00", occurrenceDate: "2027-07-12T10:30:00+08:00")
        let result = SeriesExceptionsPlanner.capture([moved], of: series,
                                                     window: DateInterval(start: at("2027-07-01T00:00:00+08:00"), end: at("2027-08-01T00:00:00+08:00")))
        XCTAssertEqual(result.detached[0].slot, at("2027-07-12T10:00:00+08:00"))
    }

    func testCaptureFallsBackToOccurrenceDateWithoutARID() {
        let edited = observed(ids: .init(eventIdentifier: "SERIES/other", externalIdentifier: nil),
                              detached: true, start: slot2, occurrenceDate: slot2)
        let result = SeriesExceptionsPlanner.capture([edited], of: series, window: window)
        XCTAssertEqual(result.detached[0].slot, at(slot2))
    }

    func testCaptureIgnoresOccurrencesOfOtherSeries() {
        let other = UndoPostState.OccurrenceIDs(eventIdentifier: "OTHER", externalIdentifier: "OTHERUID")
        let result = SeriesExceptionsPlanner.capture(
            [observed(ids: other, detached: false, start: slot1, occurrenceDate: slot1),
             observed(detached: false, start: slot4, occurrenceDate: slot4)],
            of: series, window: window)
        XCTAssertEqual(result.keptSlots, [at(slot4)])
        XCTAssertTrue(result.detached.isEmpty)
    }

    func testCaptureOfNothingIsEmptyNotAbsent() {
        let result = SeriesExceptionsPlanner.capture([], of: series, window: window)
        XCTAssertEqual(result.keptSlots, [])
        XCTAssertTrue(result.detached.isEmpty)
    }

    // MARK: - surplus

    func testInteriorDeleteLeavesTheDeletedSlotAsSurplus() {
        let exceptions = SeriesExceptions(window: window, keptSlots: [at(slot1), at(slot2), at(slot4)], detached: [])
        let surplus = SeriesExceptionsPlanner.surplusSlots(
            generated: [at(slot1), at(slot2), at(slot3), at(slot4)], exceptions: exceptions)
        XCTAssertEqual(surplus, [at(slot3)])
    }

    func testTailDeleteAlreadyCarriedByTheRuleLeavesNoSurplus() {
        // iCloud shortened the rule to count 3 (spike 2026-10-12): the recreated series has three slots.
        let exceptions = SeriesExceptions(window: window, keptSlots: [at(slot1), at(slot2), at(slot3)], detached: [])
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(
            generated: [at(slot1), at(slot2), at(slot3)], exceptions: exceptions), [])
    }

    func testEditedSlotIsSurplusBecauseItReturnsAsAOneOff() {
        let edited = DetachedOccurrence(slot: at(slot2), snapshot: snapshot(title: "Standup (moved room)", start: slot2))
        let exceptions = SeriesExceptions(window: window, keptSlots: [at(slot1), at(slot4)], detached: [edited])
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(
            generated: [at(slot1), at(slot2), at(slot3), at(slot4)], exceptions: exceptions), [at(slot2), at(slot3)])
    }

    func testSlotsOutsideTheCheckedWindowAreNeverSurplus() {
        // Window ends 2028-04-25 10:00; a slot a week later is outside it and must be left to the rule.
        let outside = "2028-05-01T10:00:00+08:00"
        let exceptions = SeriesExceptions(window: window, keptSlots: [at(slot1)], detached: [])
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(
            generated: [at(slot1), at(outside)], exceptions: exceptions), [])
    }

    func testWindowEdgesAreInclusiveAndOneSecondOutsideIsNot() {
        let exceptions = SeriesExceptions(window: window, keptSlots: [], detached: [])
        let atEnd = at("2028-04-25T10:00:00+08:00")
        let afterEnd = atEnd.addingTimeInterval(1)
        let atStart = at("2028-04-02T10:00:00+08:00")
        let beforeStart = atStart.addingTimeInterval(-1)
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(generated: [beforeStart, atStart, atEnd, afterEnd],
                                                            exceptions: exceptions), [atStart, atEnd])
    }

    func testSlotsAreComparedAsInstantsAcrossADaylightSavingChange() {
        // New York, weekly 10:00 local: 2028-03-12 is the spring-forward day, so the slots are
        // 7 days apart in wall-clock time and 7 days minus one hour apart as instants.
        let a = at("2028-03-05T10:00:00-05:00"), b = at("2028-03-12T10:00:00-04:00"), c = at("2028-03-19T10:00:00-04:00")
        let ny = DateInterval(start: at("2028-03-04T10:00:00-05:00"), end: at("2028-03-20T10:00:00-04:00"))
        let exceptions = SeriesExceptions(window: ny, keptSlots: [a, c], detached: [])
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(generated: [a, b, c], exceptions: exceptions), [b])
        XCTAssertEqual(b.timeIntervalSince(a), 7 * 86_400 - 3_600)   // literal check of the premise
    }

    func testSubSecondDriftOfAKeptSlotIsStillTheSameSlot() {
        let exceptions = SeriesExceptions(window: window, keptSlots: [at(slot1).addingTimeInterval(0.4)], detached: [])
        XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(generated: [at(slot1)], exceptions: exceptions), [])
    }
    // MARK: - listing range and window classification (PR #318 verify B1)

    func testListingRangeWidensANarrowWindowByAYearEachSide() {
        let narrow = DateInterval(start: at("2028-04-02T10:00:00+08:00"), end: at("2028-04-25T10:00:00+08:00"))
        let range = SeriesExceptionsPlanner.listingRange(for: narrow)
        XCTAssertEqual(range.start, narrow.start.addingTimeInterval(-366 * 86_400))
        XCTAssertEqual(range.end, narrow.end.addingTimeInterval(366 * 86_400))
    }

    func testListingRangeNeverExceedsTheFourYearQueryLimit() {
        let full = DateInterval(start: at("2028-04-02T10:00:00+08:00"), duration: 1460 * 86_400)
        XCTAssertEqual(SeriesExceptionsPlanner.listingRange(for: full), full)
        let long = DateInterval(start: at("2028-04-02T10:00:00+08:00"), duration: 1000 * 86_400)
        XCTAssertLessThanOrEqual(SeriesExceptionsPlanner.listingRange(for: long).duration, 1460 * 86_400)
        XCTAssertTrue(SeriesExceptionsPlanner.listingRange(for: long).contains(long.start))
        XCTAssertTrue(SeriesExceptionsPlanner.listingRange(for: long).contains(long.end))
    }

    func testAnOccurrenceMovedOutOfTheWindowIsStillCapturedByItsSlot() {
        // Its slot (04-17) is inside the window; it was moved to 05-20, past the window end. The
        // widened listing sees it, and its RID slot puts it in the window.
        let moved = observed(ids: .init(eventIdentifier: "SERIES/RID=830000000", externalIdentifier: nil),
                             detached: true, start: "2028-05-20T10:00:00+08:00", occurrenceDate: "2028-05-20T10:00:00+08:00", title: "Moved")
        let slotInWindow = Date(timeIntervalSinceReferenceDate: 830_000_000)
        let w = DateInterval(start: slotInWindow.addingTimeInterval(-86_400 * 10), end: slotInWindow.addingTimeInterval(86_400 * 10))
        let result = SeriesExceptionsPlanner.capture([moved], of: series, window: w)
        XCTAssertEqual(result.detached.map(\.slot), [slotInWindow])
    }

    func testAnOccurrenceWhoseSlotIsOutsideTheWindowIsLeftToTheRule() {
        // Slot outside the window, moved into it: restoring it as a one-off would duplicate the
        // occurrence the rule regenerates outside the window.
        let moved = observed(ids: .init(eventIdentifier: "SERIES/RID=830000000", externalIdentifier: nil),
                             detached: true, start: slot2, occurrenceDate: slot2, title: "Moved in")
        let result = SeriesExceptionsPlanner.capture([moved], of: series, window: window)
        XCTAssertTrue(result.detached.isEmpty)
        XCTAssertEqual(result.keptSlots, [])
    }

    func testUndetachedOccurrencesOutsideTheWindowAreNotKeptSlots() {
        let result = SeriesExceptionsPlanner.capture(
            [observed(detached: false, start: "2028-09-01T10:00:00+08:00", occurrenceDate: "2028-09-01T10:00:00+08:00"),
             observed(detached: false, start: slot1, occurrenceDate: slot1)], of: series, window: window)
        XCTAssertEqual(result.keptSlots, [at(slot1)])
    }
}
