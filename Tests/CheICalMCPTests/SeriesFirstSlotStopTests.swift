import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 round 2 (ruling I; verify findings H1, H4, H5): with a record of two readings, the undo of a
/// whole-series delete applies nothing when the delete reached the series through a stand-in, or when the
/// recreated series' first slot lies inside a window and was not a plain occurrence at the capture
/// (`SeriesExceptionsPlanner.firstSlotStopsTheRestore`), and the forecast at the delete counts it. The
/// matrix over the shapes is `FloatingSeriesUndoMatrixTests`; these pin each condition alone. Each test
/// names its host zone; none reads the process's.
final class SeriesFirstSlotStopTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private var slots: [Date] {
        let first = Calendar.gregorian(in: taipei).date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 6))!
        return (0..<6).map { first.addingTimeInterval(Double($0) * day) }
    }
    private var window: DateInterval { DateInterval(start: slots[0].addingTimeInterval(-day), end: slots[5].addingTimeInterval(day)) }

    private func record(_ readings: SlotReadings) -> DetachedOccurrence {
        DetachedOccurrence(slot: readings.instant, snapshot: UndoSnapshotFixtures.event(title: "Edited", startDate: readings.wallClock ?? readings.instant),
                           readings: readings)
    }
    private var twoReadings: DetachedOccurrence { record(SlotReadings(instant: slots[3].addingTimeInterval(8 * hour), wallClock: slots[3])) }
    private var oneReading: DetachedOccurrence { record(SlotReadings(instant: slots[3])) }

    // MARK: - the condition (pure)

    /// Each way of being true alone, and what does not make it true.
    // spec-example: undo-history-discard / the first slot stops the restore
    func testTheFirstSlotStopsTheRestoreOnlyWithARecordOfTwoReadings() {
        let plainFirst = SeriesExceptions(window: window, keptSlots: [slots[0], slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        XCTAssertFalse(SeriesExceptionsPlanner.firstSlotStopsTheRestore(plainFirst, seriesStart: slots[0]), "a plain first slot")
        // (b): the first slot inside the window, not a kept slot (deleted or edited on its own).
        let firstGone = SeriesExceptions(window: window, keptSlots: [slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        XCTAssertTrue(SeriesExceptionsPlanner.firstSlotStopsTheRestore(firstGone, seriesStart: slots[0]), "(b)")
        // (b) asks only inside a window (#319: a series begun before its window).
        let outside = SeriesExceptions(window: DateInterval(start: slots[1].addingTimeInterval(-hour), end: window.end),
                                       keptSlots: [slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        XCTAssertFalse(SeriesExceptionsPlanner.firstSlotStopsTheRestore(outside, seriesStart: slots[0]), "first slot outside the window")
        // (a): through a stand-in, whatever the first slot.
        var standIn = plainFirst
        standIn.throughStandIn = true
        XCTAssertTrue(SeriesExceptionsPlanner.firstSlotStopsTheRestore(standIn, seriesStart: slots[0]), "(a)")
        // A record of one reading is never the reason (as before #539).
        var oneOnly = SeriesExceptions(window: window, keptSlots: [slots[1], slots[2], slots[4], slots[5]], detached: [oneReading])
        oneOnly.throughStandIn = true
        XCTAssertFalse(SeriesExceptionsPlanner.firstSlotStopsTheRestore(oneOnly, seriesStart: slots[0]), "one reading")
    }

    /// `placeDetached` copies the record by hand; the stand-in fact goes with it.
    func testTheStandInFactSurvivesThePlacement() throws {
        var exceptions = SeriesExceptions(window: window, keptSlots: [slots[0], slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        exceptions.throughStandIn = true
        let placed = try XCTUnwrap(SeriesExceptionsPlanner.placeDetached(exceptions, among: slots))
        XCTAssertTrue(placed.throughStandIn)
    }

    /// The capture keeps the stand-in fact it is handed, and only that (`viaStandIn`).
    func testTheCaptureKeepsTheResolutionsStandInFact() throws {
        for viaStandIn in [false, true] {
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
            let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[1], in: store, now: slots[0].addingTimeInterval(-30 * day),
                                                                        zone: taipei, viaStandIn: viaStandIn))
            XCTAssertEqual(exceptions.throughStandIn, viaStandIn)
        }
    }

    // MARK: - the restore and its text

    /// Through the restorer: nothing removed or written, the outcome says why, and so does the text, alone
    /// and in a batch.
    func testTheRestoreAppliesNothingAndSaysWhy() throws {
        var removed = 0, created = 0
        let firstGone = SeriesExceptions(window: window, keptSlots: [slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: firstGone, seriesStart: slots[0], generated: slots.map { ($0, $0) },
            remove: { (_: Date) in removed += 1 }, createOneOff: { (_: DetachedOccurrence) -> Int in created += 1; return created },
            removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertEqual(outcome, .init(stayedDeleted: 0, oneOffs: 0, notApplied: true, firstSlotNotPlain: true))
        XCTAssertEqual(removed + created, 0)
        XCTAssertEqual(UndoOperation.seriesExceptionsRestoredNote(outcome, exceptions: firstGone), UndoOperation.seriesFirstSlotNotPlainNote)
        XCTAssertTrue(UndoOperation.seriesFirstSlotNotPlainNote.hasPrefix("Restored from the series rules alone: the series had no time zone"))
        XCTAssertFalse(UndoOperation.seriesFirstSlotNotPlainNote.contains("did not match"))
        // A batch names it apart from the series whose exceptions did not match.
        let note = try XCTUnwrap(UndoOperation.batchLossNote(events: [.seriesWithExceptions(outcome), .seriesWithExceptions(outcome),
                                                                      .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true))]))
        XCTAssertTrue(note.contains("2 series were restored from their rules alone: each had no time zone"), note)
        XCTAssertTrue(note.contains("1 series was restored from its rules alone: its recorded exceptions did not match"), note)
        let one = try XCTUnwrap(UndoOperation.batchLossNote(events: [.seriesWithExceptions(outcome)]))
        XCTAssertTrue(one.hasPrefix("1 series was restored from its rules alone: it had no time zone"), one)
        XCTAssertFalse(one.contains("did not match"), one)
    }

    // MARK: - the forecast

    /// The forecast counts every recorded edit when the first slot stops the restore, without the expander
    /// (here it has no rule to expand, and no first slot), and does not otherwise.
    func testTheForecastCountsEveryEditWhenTheFirstSlotStops() {
        let calendar = Calendar.gregorian(in: taipei)
        let firstGone = SeriesExceptions(window: window, keptSlots: [slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings, oneReading])
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(firstGone, rules: [], firstSlot: nil, seriesStart: slots[0], calendar: calendar), 2)
        var standIn = SeriesExceptions(window: window, keptSlots: [slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        standIn.throughStandIn = true
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(standIn, rules: [], firstSlot: nil, seriesStart: slots[1], calendar: calendar), 1)
        let plain = SeriesExceptions(window: window, keptSlots: [slots[0], slots[1], slots[2], slots[4], slots[5]], detached: [twoReadings])
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(plain, rules: [], firstSlot: nil, seriesStart: slots[0], calendar: calendar),
                     "no stop: the expander decides, and with no rule it cannot")
    }
}
