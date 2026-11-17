import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 round 1 (rulings B, C, D, and F24): where the undo of a whole-series delete places a record
/// of two readings (`SeriesExceptionsPlanner.placement`), and the margins it lists the recreated series
/// over to place one (`placementMargins`). Each test names its host zone; none reads the process's.
final class SeriesPlacementTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func record(_ readings: SlotReadings, title: String = "Edited") -> DetachedOccurrence {
        DetachedOccurrence(slot: readings.instant, snapshot: UndoSnapshotFixtures.event(title: title, startDate: readings.wallClock ?? readings.instant),
                           readings: readings)
    }

    private var slots: [Date] { (0..<6).map { date(2027, 3, 1, 6, in: taipei).addingTimeInterval(Double($0) * day) } }
    private var window: DateInterval { DateInterval(start: slots[0].addingTimeInterval(-day), end: slots[5].addingTimeInterval(day)) }

    // MARK: - placement (pure)

    /// Ruling B: a record whose one slot reading is a kept slot is not placed (no slot has both a plain
    /// occurrence and an edit, so that reading is the wrong one), and nothing is applied.
    func testARecordOnAKeptSlotIsNotPlaced() {
        let kept = [slots[0], slots[2], slots[3], slots[4], slots[5]]
        let exceptions = SeriesExceptions(window: window, keptSlots: kept,
                                          detached: [record(SlotReadings(instant: slots[1].addingTimeInterval(8 * hour), wallClock: slots[0]))])
        XCTAssertEqual(SeriesExceptionsPlanner.placement(exceptions, among: InstantSet(slots)).unplaced, 1)
        XCTAssertNil(SeriesExceptionsPlanner.placeDetached(exceptions, among: slots))
        // Off a kept slot it is placed.
        let free = SeriesExceptions(window: window, keptSlots: kept,
                                    detached: [record(SlotReadings(instant: slots[1].addingTimeInterval(8 * hour), wallClock: slots[1]))])
        XCTAssertEqual(SeriesExceptionsPlanner.placeDetached(free, among: slots)?.detached.map(\.slot), [slots[1]])
    }

    /// Ruling D: two records placed on one slot are not placed, either of them; a record of one reading
    /// counts as placed on its slot. With no record of two readings nothing is checked (as before #539).
    func testTwoRecordsOnOneSlotAreNotPlaced() {
        let kept = [slots[0], slots[3], slots[4], slots[5]]
        let both = SeriesExceptions(window: window, keptSlots: kept, detached: [
            record(SlotReadings(instant: slots[1].addingTimeInterval(8 * hour), wallClock: slots[1])),
            record(SlotReadings(instant: slots[1], wallClock: slots[1].addingTimeInterval(-8 * hour))),
            record(SlotReadings(instant: slots[2].addingTimeInterval(8 * hour), wallClock: slots[2])),
        ])
        let placement = SeriesExceptionsPlanner.placement(both, among: InstantSet(slots))
        XCTAssertEqual(placement.unplaced, 2)
        XCTAssertEqual(placement.placed.map(\.slot), [slots[2]])
        XCTAssertNil(SeriesExceptionsPlanner.placeDetached(both, among: slots))
        let withOneReading = SeriesExceptions(window: window, keptSlots: kept, detached: [
            record(SlotReadings(instant: slots[1].addingTimeInterval(8 * hour), wallClock: slots[1])),
            record(SlotReadings(instant: slots[1])),
        ])
        // PR #558 round 2 (H27): the record of two readings is not placed; the record of one reading is
        // kept as it is (the restore's consistency check decides it), never counted as the reason.
        let mixed = SeriesExceptionsPlanner.placement(withOneReading, among: InstantSet(slots))
        XCTAssertEqual(mixed.unplaced, 1)
        XCTAssertEqual(mixed.placed.map(\.readings), [SlotReadings(instant: slots[1])])
        XCTAssertNil(SeriesExceptionsPlanner.placeDetached(withOneReading, among: slots))
        let oneReadingOnly = SeriesExceptions(window: window, keptSlots: kept,
                                              detached: [record(SlotReadings(instant: slots[1])), record(SlotReadings(instant: slots[1]))])
        XCTAssertEqual(SeriesExceptionsPlanner.placement(oneReadingOnly, among: InstantSet(slots)).unplaced, 0, "as before #539")
    }

    /// PR #558 round 2 (H27, H38): a record of one reading is never the reason a record is not placed, beside
    /// a record of two readings that is placed: one on a kept slot passes (rulings B and C ask only records of
    /// two readings), and two that share a slot only with each other pass (ruling D likewise), as before #539.
    func testARecordOfOneReadingIsNeverTheReason() {
        let kept = [slots[0], slots[3], slots[4], slots[5]]
        let placedTwo = record(SlotReadings(instant: slots[1].addingTimeInterval(8 * hour), wallClock: slots[1]))
        let onKept = SeriesExceptions(window: window, keptSlots: kept, detached: [placedTwo, record(SlotReadings(instant: slots[3]))])
        let first = SeriesExceptionsPlanner.placement(onKept, among: InstantSet(slots))
        XCTAssertEqual(first.unplaced, 0)
        XCTAssertEqual(first.placed.map(\.slot), [slots[1], slots[3]])
        let sharing = SeriesExceptions(window: window, keptSlots: kept,
                                       detached: [placedTwo, record(SlotReadings(instant: slots[2])), record(SlotReadings(instant: slots[2]))])
        let second = SeriesExceptionsPlanner.placement(sharing, among: InstantSet(slots))
        XCTAssertEqual(second.unplaced, 0)
        XCTAssertEqual(second.placed.map(\.slot), [slots[1], slots[2], slots[2]])
    }

    /// Ruling C: a record of two readings placed outside every window applies nothing; one placed inside
    /// with the rest is placed.
    func testARecordPlacedOutsideEveryWindowIsNotPlaced() {
        let outside = window.end.addingTimeInterval(2 * hour)
        let exceptions = SeriesExceptions(window: window, keptSlots: slots, detached: [
            record(SlotReadings(instant: outside.addingTimeInterval(-8 * hour), wallClock: outside)),
        ])
        XCTAssertEqual(SeriesExceptionsPlanner.placement(exceptions, among: InstantSet(slots + [outside])).unplaced, 1)
        XCTAssertNil(SeriesExceptionsPlanner.placeDetached(exceptions, among: slots + [outside]))
    }

    // MARK: - the margins (F24)

    /// The margins are `SlotReadings.largestOffset` (14 hours) before each window's start and after its
    /// end, the one after starting at the end itself (a query's end is exclusive, so the end is in no
    /// window and must be in the margin).
    func testTheMarginsAreFourteenHoursOnEachSideOfEachWindow() {
        let a = DateInterval(start: date(2027, 3, 1, 0, in: utc), end: date(2027, 3, 10, 0, in: utc))
        let b = DateInterval(start: date(2027, 4, 1, 0, in: utc), end: date(2027, 4, 2, 0, in: utc))
        XCTAssertEqual(SlotReadings.largestOffset, 14 * hour)
        XCTAssertEqual(SeriesExceptionsPlanner.placementMargins(for: [a, b]), [
            DateInterval(start: a.start.addingTimeInterval(-14 * hour), end: a.start), DateInterval(start: a.end, end: a.end.addingTimeInterval(14 * hour)),
            DateInterval(start: b.start.addingTimeInterval(-14 * hour), end: b.start), DateInterval(start: b.end, end: b.end.addingTimeInterval(14 * hour)),
        ])
    }

    /// Through the store-level restore: a record whose wall-clock reading is a slot inside the window and
    /// whose instant reading is a slot in the margin after it (both readings slots: not placed, nothing
    /// applied). The margin's slot is found only when the margin is listed far enough, from the window's
    /// end on: at `end + 7 h` (a margin narrower than the 8 hours between the readings would miss it) and
    /// at the end itself (a margin starting after the end would miss it). Missed, the record would be
    /// placed on the slot inside and applied.
    func testTheRestoreListsTheMarginFromTheWindowEndForFourteenHours() throws {
        for afterEnd in [7 * hour, 0] {
            let window = DateInterval(start: date(2027, 3, 1, 0, in: taipei), end: date(2027, 3, 10, 0, in: taipei))
            let instant = window.end.addingTimeInterval(afterEnd)
            let wallClock = instant.addingTimeInterval(-8 * hour)
            let slots = [date(2027, 3, 2, 0, in: taipei), wallClock, instant]
            let exceptions = SeriesExceptions(window: window, keptSlots: [slots[0]],
                                              detached: [record(SlotReadings(instant: instant, wallClock: wallClock))])
            let store = FakeSeriesExceptionsStore()
            let restored = FakeSeriesExceptionsStore.Event(id: "R", external: "X-R", calendar: "C", title: "Standup", start: slots[0],
                                                          occurrenceDate: slots[0], hasRules: true)
            store.add(restored)
            for slot in slots.dropFirst() {
                store.add(FakeSeriesExceptionsStore.Event(id: "R", external: "X-R", calendar: "C", title: "Standup", start: slot,
                                                          occurrenceDate: slot, hasRules: true))
            }
            let outcome = try SeriesExceptionsUndo.restore(exceptions, of: restored, in: store)
            XCTAssertEqual(outcome, .init(stayedDeleted: 0, oneOffs: 0, notApplied: true), "\(afterEnd / hour) h after the end")
        }
    }

    // MARK: - a floating series moved whole (F2, F3 on a series without a time zone)

    /// A floating daily series at 06:00 local, its second occurrence retitled, then the whole series moved
    /// a day later: the edited occurrence moves and keeps its `/RID=` at the old slot, whose wall-clock
    /// reading is now the series' first slot, its anchor (and kept). Before round 1 the record was placed on
    /// the anchor, the second slot removed as surplus and no one-off written: the occurrence was lost.
    /// Ruling B: not placed, so the series comes back from its rules with every occurrence (the edit lost).
    func testAFloatingRecordOnTheAnchorAfterAWholeSeriesMoveAppliesNothing() throws {
        for edited in [1, 2] {
            let old = slots
            let moved = old.map { $0.addingTimeInterval(day) }
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: moved, floating: true)
            var utcCalendar = Calendar.gregorian(in: utc)
            utcCalendar.timeZone = utc
            let parts = Calendar.gregorian(in: taipei).dateComponents([.year, .month, .day, .hour, .minute, .second], from: old[edited])
            let digits = utcCalendar.date(from: parts)!
            let occurrence = occurrences[edited]
            occurrence.id = "S/RID=\(Int(digits.timeIntervalSinceReferenceDate))"
            occurrence.external = "X-" + occurrence.id!
            occurrence.detached = true
            occurrence.title = "Edited"
            let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: old[0].addingTimeInterval(-30 * day), zone: taipei))
            XCTAssertNotNil(exceptions.detached.first?.readings.wallClock)

            let recorded = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 6, startDate: moved[0]).withExceptions(exceptions)
                .withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
            let after = FakeSeriesExceptionsStore()
            after.seriesSlots = moved
            let (_, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(recorded, calendar: recorded.calendarIdentifier, in: after)

            XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true)), "edited \(edited)")
            XCTAssertEqual(after.starts(of: "E1"), moved, "every occurrence, edited \(edited)")
        }
    }
}
