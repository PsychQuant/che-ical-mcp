import EventKit
import XCTest
@testable import CheICalMCP

/// #539 step 6: the forecast a whole-series delete makes before anything is removed. The capture's
/// records of occurrences edited on their own are placed on the slots the series' rule gives, expanded
/// from its first slot (`SeriesExceptionsPlanner.unplacedEdits`); a record that cannot be placed means
/// the undo is expected to restore the series from its rules alone. Which rows of a call carry that
/// forecast is `RulesAloneForecast`. Each test names its host zone; none reads the process's.
final class SeriesDeleteForecastTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ minute: Int = 0, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute))!
    }

    /// The suffix of an occurrence edited while its series had no time zone: the wall-clock time
    /// `parts` written as UTC (iCloud, #539 cells F1-F3).
    private func floatingRID(_ parts: DateComponents) -> String {
        "/RID=\(Int(Calendar.gregorian(in: utc).date(from: parts)!.timeIntervalSinceReferenceDate))"
    }

    private func floatingRID(_ slot: Date, in zone: TimeZone) -> String {
        floatingRID(Calendar.gregorian(in: zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot))
    }

    private func zonedRID(_ slot: Date) -> String { "/RID=\(Int(slot.timeIntervalSinceReferenceDate))" }

    private func edit(_ occurrence: FakeSeriesExceptionsStore.Event, rid: String, title: String, moved: TimeInterval = 0) {
        occurrence.id = "S" + rid
        occurrence.external = "X-S" + rid
        occurrence.detached = true
        occurrence.title = title
        occurrence.start = occurrence.start.addingTimeInterval(moved)
        occurrence.occurrenceDate = occurrence.start
    }

    private func weekly(from first: Date, count: Int) -> [Date] { (0..<count).map { first.addingTimeInterval(Double($0) * 7 * day) } }

    private func rule(_ frequency: EKRecurrenceFrequency = .weekly, count: Int = 0, end: Date? = nil,
                      daysOfWeek: [Int] = [], otherParts: Bool = false) -> DeletedOccurrenceCheck.Rule {
        DeletedOccurrenceCheck.Rule(frequency: frequency, interval: 1, daysOfWeek: daysOfWeek, daysOfMonth: [],
                                    endDate: end, occurrenceCount: count, hasOtherParts: otherParts)
    }

    /// The capture of a six-week series from `slots[0]`, with `edits` applied, as the delete records it.
    private func captured(_ slots: [Date], zone: TimeZone, file: StaticString = #filePath, line: UInt = #line,
                          edits: ([FakeSeriesExceptionsStore.Event]) -> Void) throws -> SeriesExceptions {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        edits(occurrences)
        return try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: slots[0].addingTimeInterval(-30 * day), zone: zone),
                             file: file, line: line)
    }

    // MARK: - unplacedEdits

    /// F1's shape (the third retitled, the fourth moved, both while the series had no zone) is placed
    /// now in every host zone: no forecast of a restore from the rules alone.
    // spec-example: undo-history-discard / no note once the edit is placed
    func testAFloatingSeriesWithEditsIsPlacedInEveryHostZone() throws {
        for zone in [taipei, losAngeles, utc] {
            let slots = weekly(from: date(2027, 2, 11, 10, in: zone), count: 6)
            let exceptions = try captured(slots, zone: zone) { occurrences in
                edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Retitled")
                edit(occurrences[3], rid: floatingRID(slots[3], in: zone), title: "Moved", moved: 3600)
            }
            XCTAssertEqual(exceptions.detached.count, 2, zone.identifier)
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                                calendar: .gregorian(in: zone)), 0, zone.identifier)
        }
    }

    /// Z1's shape: the edits were made while the series kept its zone, so the instant reading is the slot.
    func testAZonedSeriesWithEditsIsPlaced() throws {
        for zone in [taipei, losAngeles] {
            let slots = weekly(from: date(2027, 2, 11, 9, in: zone), count: 6)
            let exceptions = try captured(slots, zone: zone) { occurrences in
                edit(occurrences[2], rid: zonedRID(slots[2]), title: "Retitled")
                edit(occurrences[3], rid: zonedRID(slots[3]), title: "Moved", moved: 3600)
            }
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                                calendar: .gregorian(in: zone)), 0, zone.identifier)
        }
    }

    /// An occurrence edited floating at 13:00 in a series whose rule now gives 10:00 (its time of day
    /// was changed after the edit): neither reading is a slot, so it is counted; the placed one is not.
    func testAnEditNoSlotOfTheRuleHoldsIsCounted() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei) { occurrences in
            edit(occurrences[2], rid: floatingRID(slots[2].addingTimeInterval(3 * 3600), in: taipei), title: "Retitled")
            edit(occurrences[3], rid: floatingRID(slots[3], in: taipei), title: "Placed")
        }
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                            calendar: .gregorian(in: taipei)), 1)
    }

    /// A record with one reading (no `/RID=`: its `occurrenceDate`, here the moved time) is counted when
    /// that reading is no slot, as the restore's consistency check would not apply it either.
    func testARecordWithOneReadingOffTheRuleIsCounted() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei) { occurrences in
            occurrences[2].detached = true
            occurrences[2].start = slots[2].addingTimeInterval(3600)
            occurrences[2].occurrenceDate = occurrences[2].start
        }
        XCTAssertEqual(exceptions.detached.first?.readings.wallClock, nil)
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                            calendar: .gregorian(in: taipei)), 1)
    }

    func testNoEditedOccurrenceCountsNothing() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei) { _ in }
        XCTAssertTrue(exceptions.detached.isEmpty)
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                            calendar: .gregorian(in: taipei)), 0)
    }

    /// No forecast where the expander cannot tell: the capture says nothing rather than guess.
    func testNoForecastWhereTheRuleCannotBeExpanded() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei) { occurrences in
            edit(occurrences[2], rid: floatingRID(slots[2].addingTimeInterval(3 * 3600), in: taipei), title: "Off the rule")
        }
        let calendar = Calendar.gregorian(in: taipei)
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [], firstSlot: slots[0], calendar: calendar), "no rule")
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6), rule(.daily)], firstSlot: slots[0],
                                                          calendar: calendar), "two rules")
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(otherParts: true)], firstSlot: slots[0],
                                                          calendar: calendar), "a rule the expander does not follow")
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: nil, calendar: calendar),
                     "the first slot cannot be shown")
        // A daily rule from 60 years back gives more slots than the expander takes.
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)], firstSlot: slots[0].addingTimeInterval(-60 * 365 * day),
                                                          calendar: calendar), "too many slots")
    }

    /// A zoned record whose true slot is just past the window's end, recorded by its wall-clock reading:
    /// the restore places it outside the window and drops it, so it is placed, not counted. The rule is
    /// expanded past the window's end by the largest offset to see that slot.
    func testARecordPlacedOutsideTheWindowIsNotCounted() throws {
        let now = date(2026, 11, 16, 9, in: taipei)
        let window = SeriesExceptionsPlanner.deleteWindow(firstStart: now.addingTimeInterval(-3000 * day), end: .open, deletedAt: now).window
        let edge = window.end.addingTimeInterval(4 * 3600)
        let slots = (-260...260).map { edge.addingTimeInterval(Double($0) * 7 * day) }
        let store = FakeSeriesExceptionsStore()
        store.seriesEnd = .open
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        edit(occurrences[260], rid: zonedRID(slots[260]), title: "Past the edge")
        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now, zone: taipei))
        XCTAssertEqual(exceptions.detached.count, 1, "recorded by its wall-clock reading, inside the window")
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule()], firstSlot: slots[0],
                                                            calendar: .gregorian(in: taipei)), 0)
    }

    /// The daylight-saving cells of the plan, on a host at America/Los_Angeles: an occurrence of a
    /// floating weekly series at 02:30 edited on 2027-03-14 (the time does not exist that day) and one
    /// at 01:30 edited on 2027-11-07 (it exists twice). The store's `/RID=` for them was not measured;
    /// with the nominal wall-clock time as its digits, the expander and the wall-clock reading both go
    /// through Foundation and agree, so the record is placed and there is no forecast. Whether the store
    /// gave those occurrences that instant is a device question (the release gate of #539).
    func testOnDaylightSavingDaysTheExpanderAndTheWallClockReadingAgree() throws {
        for (first, edited, hour, minute) in [(date(2027, 2, 28, 2, 30, in: losAngeles), DateComponents(year: 2027, month: 3, day: 14), 2, 30),
                                              (date(2027, 10, 24, 1, 30, in: losAngeles), DateComponents(year: 2027, month: 11, day: 7), 1, 30)] {
            let calendar = Calendar.gregorian(in: losAngeles)
            let expected = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule(count: 6), firstStart: first,
                                                                             until: first.addingTimeInterval(60 * day), calendar: calendar))
            let slots = Array(expected.prefix(6))
            var parts = edited
            parts.hour = hour; parts.minute = minute; parts.second = 0
            let exceptions = try captured(slots, zone: losAngeles) { occurrences in
                edit(occurrences[2], rid: floatingRID(parts), title: "Edited on the change")
            }
            XCTAssertEqual(exceptions.detached.count, 1)
            XCTAssertEqual(exceptions.detached.first?.readings.wallClock, slots[2], "Foundation's instant for that wall-clock time")
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: first, calendar: calendar), 0)
        }
    }

    // MARK: - RulesAloneForecast

    private func wholeSeries(_ title: String = "Standup") -> UndoOperation {
        .deleteEvent(snapshot: UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 6, startDate: Date(timeIntervalSinceReferenceDate: 0)))
    }

    /// Only a whole-series record with a count above 0 forecasts, in the order the rows were recorded.
    func testOnlyAWholeSeriesRecordWithUnplacedEditsForecasts() {
        var forecast = RulesAloneForecast()
        forecast.recorded(wholeSeries(), identifier: "A", unplacedEdits: 2)
        forecast.recorded(wholeSeries(), identifier: "B", unplacedEdits: 0)
        forecast.recorded(.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: []), identifier: "C", unplacedEdits: 3)
        forecast.recorded(wholeSeries(), identifier: "D", unplacedEdits: 1)
        XCTAssertEqual(forecast.expected, [.init(identifier: "A", unplacedEdits: 2), .init(identifier: "D", unplacedEdits: 1)])
    }

    /// A delete of an occurrence and the following ones makes the whole batch's undo refuse, so that
    /// undo restores no row: no row forecasts a restore, recorded before or after it.
    func testARecordThatRefusesTheCallsUndoClearsEveryForecast() {
        var forecast = RulesAloneForecast()
        forecast.recorded(wholeSeries(), identifier: "A", unplacedEdits: 2)
        forecast.recorded(.deleteFollowingOccurrences(title: "Standup"), identifier: "B", unplacedEdits: 0)
        forecast.recorded(wholeSeries(), identifier: "C", unplacedEdits: 1)
        XCTAssertEqual(forecast.expected, [])
    }

    /// `delete_event`: the count of the one record it made, 0 unless that record is a whole-series delete.
    func testASingleDeleteForecastsOnlyForAWholeSeriesRecord() {
        XCTAssertEqual(RulesAloneForecast.unplacedEdits(of: wholeSeries(), unplacedEdits: 2), 2)
        XCTAssertEqual(RulesAloneForecast.unplacedEdits(of: .deleteFollowingOccurrences(title: "Standup"), unplacedEdits: 2), 0)
        XCTAssertEqual(RulesAloneForecast.unplacedEdits(of: .deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: []),
                                                        unplacedEdits: 2), 0)
    }

    // MARK: - Texts

    /// The plan's texts (#539, "4. The note at the delete"), word for word.
    func testTheNotesSayTheForecastWithItsCount() {
        XCTAssertEqual(CheICalMCPServer.rulesAloneUndoNote(unplacedEdits: 2),
                       "Undo is expected to bring this series back from its rules alone: 2 occurrence(s) edited on their own carry an original time that matches no slot of the series' rule as it was read at the delete, so undo cannot place their edits, and an occurrence deleted on its own earlier would come back with them.")
        XCTAssertEqual(CheICalMCPServer.batchPreviewRulesAloneNote(unplacedEdits: 1),
                       "Undo of this row would be expected to bring the series back from its rules alone: 1 occurrence(s) edited on their own carry an original time that matches no slot of the series' rule as it was read at the delete, so undo cannot place their edits, and an occurrence deleted on its own earlier would come back with them.")
    }
}
