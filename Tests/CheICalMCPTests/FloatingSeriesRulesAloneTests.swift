import EventKit
import XCTest
@testable import CheICalMCP

/// PR #558 round 3 (verify findings J1, J2; the placement of rounds 0 to 2 withdrawn): a whole-series
/// delete's record that holds an occurrence edited on its own whose recorded time has two readings (a series
/// with no time zone, a host not at offset 0) applies none of the series' exceptions on undo
/// (`SeriesExceptionsPlanner.holdsAFloatingEdit`, `Outcome.floatingEdit`), the undo says why, and the
/// forecast at the delete counts every recorded edit. A record of one reading keeps the restore of before
/// #539. The matrix over the shapes is `FloatingSeriesUndoMatrixTests`. Each test names its host zone;
/// none reads the process's.
final class FloatingSeriesRulesAloneTests: XCTestCase {
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
    /// The fourth occurrence edited while the series had no time zone, read at `+08:00`: its digits are the
    /// slot's wall-clock time written as UTC, so the instant reading is eight hours late.
    private var twoReadings: DetachedOccurrence { record(SlotReadings(instant: slots[3].addingTimeInterval(8 * hour), wallClock: slots[3])) }
    private var oneReading: DetachedOccurrence { record(SlotReadings(instant: slots[3])) }
    private var kept: [Date] { [slots[0], slots[1], slots[2], slots[4], slots[5]] }

    // MARK: - the condition (pure)

    /// Any record of two readings, wherever it would fall; never a record of one reading.
    // spec-example: undo-history-discard / a floating edit stops the restore
    func testARecordOfTwoReadingsHoldsAFloatingEdit() {
        XCTAssertTrue(SeriesExceptionsPlanner.holdsAFloatingEdit(SeriesExceptions(window: window, keptSlots: kept, detached: [twoReadings])))
        XCTAssertTrue(SeriesExceptionsPlanner.holdsAFloatingEdit(SeriesExceptions(window: window, keptSlots: kept, detached: [oneReading, twoReadings])))
        XCTAssertFalse(SeriesExceptionsPlanner.holdsAFloatingEdit(SeriesExceptions(window: window, keptSlots: kept, detached: [oneReading])))
        XCTAssertFalse(SeriesExceptionsPlanner.holdsAFloatingEdit(SeriesExceptions(window: window, keptSlots: kept, detached: [])))
    }

    // MARK: - the restore and its text

    /// Through the restorer: nothing removed or written although the record's wall-clock reading is the
    /// fourth slot, the outcome says why, and so does the text, alone and in a batch.
    func testTheRestoreAppliesNothingAndSaysWhy() throws {
        var removed = 0, created = 0
        let exceptions = SeriesExceptions(window: window, keptSlots: kept, detached: [twoReadings])
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: exceptions, seriesStart: slots[0], generated: slots.map { ($0, $0) },
            remove: { (_: Date) in removed += 1 }, createOneOff: { (_: DetachedOccurrence) -> Int in created += 1; return created },
            removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertEqual(outcome, .init(stayedDeleted: 0, oneOffs: 0, notApplied: true, floatingEdit: true))
        XCTAssertEqual(removed + created, 0)
        XCTAssertEqual(UndoOperation.seriesExceptionsRestoredNote(outcome, exceptions: exceptions), UndoOperation.seriesFloatingEditNote)
        XCTAssertTrue(UndoOperation.seriesFloatingEditNote.hasPrefix("Restored from the series rules alone: the series had no time zone"))
        XCTAssertTrue(UndoOperation.seriesFloatingEditNote.contains("whose original slot cannot be read reliably"))
        XCTAssertFalse(UndoOperation.seriesFloatingEditNote.contains("did not match"))
        // A batch names it apart from the series whose exceptions did not match.
        let note = try XCTUnwrap(UndoOperation.batchLossNote(events: [.seriesWithExceptions(outcome), .seriesWithExceptions(outcome),
                                                                      .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true))]))
        XCTAssertTrue(note.contains("2 series were restored from their rules alone: each had no time zone"), note)
        XCTAssertTrue(note.contains("1 series was restored from its rules alone: its recorded exceptions did not match"), note)
        let one = try XCTUnwrap(UndoOperation.batchLossNote(events: [.seriesWithExceptions(outcome)]))
        XCTAssertTrue(one.hasPrefix("1 series was restored from its rules alone: it had no time zone"), one)
        XCTAssertTrue(one.contains("whose original slot cannot be read reliably"), one)
        XCTAssertFalse(one.contains("did not match"), one)
    }

    /// The stop comes before ruling E: a floating edit that also ends before it starts gives the floating
    /// reason (device cell DS1 is such a record at America/Los_Angeles).
    func testAFloatingEditThatEndsBeforeItStartsGivesTheFloatingReason() throws {
        let inverted = DetachedOccurrence(slot: slots[3].addingTimeInterval(8 * hour),
                                          snapshot: UndoSnapshotFixtures.event(title: "Edited", startDate: slots[3], endDate: slots[3].addingTimeInterval(-hour)),
                                          readings: SlotReadings(instant: slots[3].addingTimeInterval(8 * hour), wallClock: slots[3]))
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: SeriesExceptions(window: window, keptSlots: kept, detached: [inverted]), seriesStart: slots[0],
            generated: slots.map { ($0, $0) }, remove: { (_: Date) in }, createOneOff: { (_: DetachedOccurrence) -> Int in 0 },
            removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertEqual(outcome, .init(stayedDeleted: 0, oneOffs: 0, notApplied: true, floatingEdit: true))
    }

    /// A record of one reading on its slot is applied as before #539.
    func testARecordOfOneReadingIsAppliedAsBefore() throws {
        var created: [Date] = []
        let outcome = try SeriesExceptionsRestorer.restore(
            exceptions: SeriesExceptions(window: window, keptSlots: kept, detached: [oneReading]), seriesStart: slots[0],
            generated: slots.map { ($0, $0) }, remove: { (_: Date) in },
            createOneOff: { (detached: DetachedOccurrence) -> Int in created.append(detached.slot); return created.count },
            removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertEqual(outcome, .init(stayedDeleted: 0, oneOffs: 1))
        XCTAssertEqual(created, [slots[3]])
    }

    // MARK: - the forecast

    /// The forecast counts every recorded edit when the record holds a floating edit, without the expander
    /// (here it has no rule to expand, and no first slot), and does not otherwise.
    func testTheForecastCountsEveryEditOfAFloatingRecord() {
        let calendar = Calendar.gregorian(in: taipei)
        let floating = SeriesExceptions(window: window, keptSlots: kept, detached: [twoReadings, oneReading])
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(floating, rules: [], firstSlot: nil, calendar: calendar), 2)
        let zoned = SeriesExceptions(window: window, keptSlots: kept, detached: [oneReading])
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(zoned, rules: [], firstSlot: nil, calendar: calendar),
                     "one reading: the expander decides, and with no rule it cannot")
    }
}
