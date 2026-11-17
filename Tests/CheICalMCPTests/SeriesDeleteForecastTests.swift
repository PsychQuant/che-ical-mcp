import EventKit
import XCTest
@testable import CheICalMCP

/// #539 step 6: the forecast a whole-series delete makes before anything is removed
/// (`SeriesExceptionsPlanner.unplacedEdits`). PR #558 round 3: a capture holding a record of two readings (a
/// series with no time zone, a host not at offset 0) counts every recorded edit; otherwise a record whose
/// one reading is no slot of the rule expanded from the series' first slot is counted. A count above 0 means
/// the undo is expected to restore the series from its rules alone. Which rows of a call carry that forecast
/// is `RulesAloneForecast`. Each test names its host zone; none reads the process's.
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

    /// Weekly slots at the same local time in `zone` (a weekly rule's slots across a daylight-saving
    /// change, as the expander gives them).
    private func weekly(from first: Date, count: Int, in zone: TimeZone = TimeZone(identifier: "UTC")!) -> [Date] {
        (0..<count).map { Calendar.gregorian(in: zone).date(byAdding: .day, value: 7 * $0, to: first)! }
    }

    private func rule(_ frequency: EKRecurrenceFrequency = .weekly, count: Int = 0, end: Date? = nil,
                      daysOfWeek: [Int] = [], otherParts: Bool = false) -> DeletedOccurrenceCheck.Rule {
        DeletedOccurrenceCheck.Rule(frequency: frequency, interval: 1, daysOfWeek: daysOfWeek, daysOfMonth: [],
                                    endDate: end, occurrenceCount: count, hasOtherParts: otherParts)
    }

    /// The capture of a six-week series from `slots[0]`, with `edits` applied, as the delete records it.
    /// `floating`: the series has no time zone (PR #558 round 1, ruling A: only then two readings).
    private func captured(_ slots: [Date], zone: TimeZone, floating: Bool = true, file: StaticString = #filePath, line: UInt = #line,
                          edits: ([FakeSeriesExceptionsStore.Event]) -> Void) throws -> SeriesExceptions {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: floating)
        edits(occurrences)
        return try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: slots[0].addingTimeInterval(-30 * day), zone: zone),
                             file: file, line: line)
    }

    // MARK: - unplacedEdits

    /// F1's shape (the third retitled, the fourth moved, both while the series had no zone): away from
    /// offset 0 both records have two readings and both are counted (rounds 0 to 2 placed them and counted
    /// none); at UTC they have one reading each, on its slot, and none is counted.
    // spec-example: undo-history-discard / the delete counts every floating edit
    func testAFloatingSeriesWithEditsCountsEveryEditAwayFromOffsetZero() throws {
        for zone in [taipei, losAngeles, utc] {
            let slots = weekly(from: date(2027, 2, 11, 10, in: zone), count: 6, in: zone)
            let exceptions = try captured(slots, zone: zone) { occurrences in
                edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Retitled")
                edit(occurrences[3], rid: floatingRID(slots[3], in: zone), title: "Moved", moved: 3600)
            }
            XCTAssertEqual(exceptions.detached.count, 2, zone.identifier)
            let count = try XCTUnwrap(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                                            calendar: .gregorian(in: zone)), zone.identifier)
            XCTAssertEqual(count, zone == utc ? 0 : 2, zone.identifier)
            XCTAssertEqual(SeriesExceptionsPlanner.holdsAFloatingEdit(exceptions), zone != utc, zone.identifier)
        }
    }

    /// Z1's shape: the edits were made while the series kept its zone, so the instant reading is the slot.
    func testAZonedSeriesWithEditsIsPlaced() throws {
        for zone in [taipei, losAngeles] {
            let slots = weekly(from: date(2027, 2, 11, 9, in: zone), count: 6, in: zone)
            let exceptions = try captured(slots, zone: zone, floating: false) { occurrences in
                edit(occurrences[2], rid: zonedRID(slots[2]), title: "Retitled")
                edit(occurrences[3], rid: zonedRID(slots[3]), title: "Moved", moved: 3600)
            }
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                                calendar: .gregorian(in: zone)), 0, zone.identifier)
        }
    }

    /// A zoned series: an occurrence edited at 13:00 in a series whose rule now gives 10:00 (its time of day
    /// was changed after the edit, cell N1): its one reading is no slot, so it is counted; the one on its
    /// slot is not. Rewritten in round 3 (it was a floating series, whose records now all count).
    func testAnEditNoSlotOfTheRuleHoldsIsCounted() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei, floating: false) { occurrences in
            edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Retitled")
            edit(occurrences[3], rid: zonedRID(slots[3]), title: "Placed")
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

    /// No forecast where the expander cannot tell: the capture says nothing rather than guess. A zoned
    /// series (round 3: a floating record counts without the expander).
    func testNoForecastWhereTheRuleCannotBeExpanded() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei, floating: false) { occurrences in
            edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Off the rule")
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

    /// An open weekly series begun years before the delete, an occurrence edited on its own just before
    /// the window's start (4 hours, a host at +08:00). Floating, its instant reading is inside the
    /// window, so it is recorded, and as a record of two readings it is counted. Zoned, it has one reading,
    /// outside the window, and is not recorded, as before #539. Renamed in round 3 (no record is placed).
    func testARecordJustOutsideTheWindowIsCountedOnlyWhenFloating() throws {
        let now = date(2026, 11, 16, 9, in: taipei)
        let window = SeriesExceptionsPlanner.deleteWindow(firstStart: now.addingTimeInterval(-3000 * day), end: .open, deletedAt: now).window
        let edge = window.start.addingTimeInterval(-4 * 3600)
        let slots = (-260...260).map { edge.addingTimeInterval(Double($0) * 7 * day) }
        for floating in [true, false] {
            let store = FakeSeriesExceptionsStore()
            store.seriesEnd = .open
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: floating)
            edit(occurrences[260], rid: floating ? floatingRID(slots[260], in: taipei) : zonedRID(slots[260]), title: "Before the edge")
            let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now, zone: taipei))
            XCTAssertEqual(exceptions.detached.count, floating ? 1 : 0, "recorded by its instant reading only when floating")
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule()], firstSlot: slots[0],
                                                                calendar: .gregorian(in: taipei)), floating ? 1 : 0)
        }
    }

    /// Ruling G (the #503 verdict's own guard): a recorded occurrence not edited on its own that is no
    /// slot of the expander means the expander is wrong here, so no forecast.
    func testAKeptSlotOffTheExpanderGivesNoForecast() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei, floating: false) { occurrences in
            edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Off the rule")
            occurrences[4].occurrenceDate = slots[4].addingTimeInterval(3600)
        }
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                          calendar: .gregorian(in: taipei)))
    }

    /// Verify F33: the note does not count a record of one reading on its slot that ends before it starts
    /// (the restore stops for it and says so, the delete gives no note). DS1's shape (listed from 03:30 to
    /// 03:00 PDT) has two readings at Los Angeles and is counted since round 3, as a floating edit; the
    /// same occurrence without a `/RID=` (one reading, its `occurrenceDate`) is not counted.
    func testARecordOfOneReadingThatEndsBeforeItStartsIsNotCounted() throws {
        let calendar = Calendar.gregorian(in: losAngeles)
        let first = date(2027, 2, 28, 2, 30, in: losAngeles)
        let expected = try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule(count: 6), firstStart: first,
                                                                         until: first.addingTimeInterval(60 * day), calendar: calendar))
        let slots = Array(expected.prefix(6))
        let exceptions = try captured(slots, zone: losAngeles) { occurrences in
            edit(occurrences[2], rid: floatingRID(DateComponents(year: 2027, month: 3, day: 14, hour: 2, minute: 30, second: 0)),
                 title: "Edited on the change")
            occurrences[2].end = slots[2].addingTimeInterval(-30 * 60)
        }
        XCTAssertLessThan(try XCTUnwrap(exceptions.detached.first).snapshot.endDate, try XCTUnwrap(exceptions.detached.first).snapshot.startDate)
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: first, calendar: calendar), 1, "DS1: two readings")
        let oneReading = try captured(slots, zone: losAngeles) { occurrences in
            occurrences[2].detached = true
            occurrences[2].title = "Edited on the change"
            occurrences[2].end = slots[2].addingTimeInterval(-30 * 60)
        }
        XCTAssertNil(oneReading.detached.first?.readings.wallClock)
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(oneReading, rules: [rule(count: 6)], firstSlot: first, calendar: calendar), 0, "one reading")
    }

    // MARK: - RulesAloneForecast

    private func wholeSeries(_ title: String = "Standup") -> UndoOperation {
        .deleteEvent(id: "S", snapshot: UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 6, startDate: Date(timeIntervalSinceReferenceDate: 0)))
    }

    private func edits(_ count: Int, floating: Bool = false) -> RulesAloneOnUndo { RulesAloneOnUndo(edits: count, floatingEdit: floating) }

    /// Only a whole-series record with a forecast forecasts, in the order the rows were recorded, with its cause.
    func testOnlyAWholeSeriesRecordWithUnplacedEditsForecasts() {
        var forecast = RulesAloneForecast()
        forecast.recorded(wholeSeries(), identifier: "A", unplacedEdits: edits(2, floating: true))
        forecast.recorded(wholeSeries(), identifier: "B", unplacedEdits: nil)
        forecast.recorded(.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: []), identifier: "C", unplacedEdits: edits(3))
        forecast.recorded(wholeSeries(), identifier: "D", unplacedEdits: edits(1))
        XCTAssertEqual(forecast.expected, [.init(identifier: "A", forecast: edits(2, floating: true)), .init(identifier: "D", forecast: edits(1))])
    }

    /// A delete of an occurrence and the following ones makes the whole batch's undo refuse, so that
    /// undo restores no row: no row forecasts a restore, recorded before or after it.
    func testARecordThatRefusesTheCallsUndoClearsEveryForecast() {
        var forecast = RulesAloneForecast()
        forecast.recorded(wholeSeries(), identifier: "A", unplacedEdits: edits(2))
        forecast.recorded(.deleteFollowingOccurrences(title: "Standup"), identifier: "B", unplacedEdits: nil)
        forecast.recorded(wholeSeries(), identifier: "C", unplacedEdits: edits(1))
        XCTAssertEqual(forecast.expected, [])
    }

    /// `delete_event`: the forecast of the one record it made, nil unless that record is a whole-series delete.
    func testASingleDeleteForecastsOnlyForAWholeSeriesRecord() {
        XCTAssertEqual(RulesAloneForecast.expected(of: wholeSeries(), unplacedEdits: edits(2)), edits(2))
        XCTAssertNil(RulesAloneForecast.expected(of: .deleteFollowingOccurrences(title: "Standup"), unplacedEdits: edits(2)))
        XCTAssertNil(RulesAloneForecast.expected(of: .deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: []),
                                                 unplacedEdits: edits(2)))
    }

    // MARK: - Texts

    /// The texts, word for word, by cause. PR #558 round 3: a floating edit names its own reason; the
    /// other cause (a recorded slot off the rule) lists what is left of the plan's causes.
    func testTheNotesSayTheForecastWithItsCountAndCause() {
        XCTAssertEqual(CheICalMCPServer.rulesAloneUndoNote(edits(2, floating: true)),
                       "Undo is expected to bring this series back from its rules alone: the series has no time zone and 2 of its occurrences were edited on their own. The original slot of an occurrence of a series with no time zone edited on its own cannot be read reliably (its recorded time can be wall-clock time or an instant), so undo applies none of the recorded exceptions: the series comes back with the occurrences its rules give, without the edits and deletions made to single occurrences.")
        XCTAssertEqual(CheICalMCPServer.rulesAloneUndoNote(edits(2)),
                       "Undo is expected to bring this series back from its rules alone: 2 occurrence(s) edited on their own have a recorded original time that is no slot of the series' rule as it was read at the delete (for example the series was moved after they were edited), so undo applies none of the recorded exceptions: every occurrence edited on its own comes back without its edit, and one deleted on its own earlier comes back.")
        XCTAssertEqual(CheICalMCPServer.batchPreviewRulesAloneNote(edits(1, floating: true)),
                       "Undo of this row would be expected to bring the series back from its rules alone: the series has no time zone and 1 of its occurrences were edited on their own. " + CheICalMCPServer.floatingEditReason)
        XCTAssertEqual(CheICalMCPServer.batchPreviewRulesAloneNote(edits(1)),
                       "Undo of this row would be expected to bring the series back from its rules alone: 1 occurrence(s) edited on their own have a recorded original time that is no slot of the series' rule as it was read at the delete (for example the series was moved after they were edited), so undo applies none of the recorded exceptions: every occurrence edited on its own comes back without its edit, and one deleted on its own earlier comes back.")
    }
}
