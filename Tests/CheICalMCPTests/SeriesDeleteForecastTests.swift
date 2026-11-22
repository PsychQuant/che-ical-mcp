import EventKit
import XCTest
@testable import CheICalMCP

/// #539 step 6: the forecast a whole-series delete makes before anything is removed
/// (`SeriesExceptionsPlanner.unplacedEdits`): a record whose slot (its `/RID=` read as an instant) is no slot
/// of the rule expanded from the series' first slot is counted, as the restore's check (`main`'s, PR #558 fix
/// round 4) applies none of the exceptions for it. A count above 0 means the undo is expected to restore the
/// series from its rules alone. Which rows of a call carry that forecast is `RulesAloneForecast`. Each test
/// names its host zone; none reads the process's.
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
    private func captured(_ slots: [Date], zone: TimeZone, file: StaticString = #filePath, line: UInt = #line,
                          edits: ([FakeSeriesExceptionsStore.Event]) -> Void) throws -> SeriesExceptions {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        edits(occurrences)
        return try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: slots[0].addingTimeInterval(-30 * day)),
                             file: file, line: line)
    }

    // MARK: - unplacedEdits

    /// F1's shape (the third retitled, the fourth moved, both while the series had no zone): away from
    /// offset 0 each `/RID=` read as an instant is off its slot by the host's offset, no slot of the rule,
    /// and both are counted (the restore, `main`'s, applies nothing for them); at UTC each is on its slot and
    /// none is counted. Rewritten in PR #558 fix round 4 (round 3 counted them as records of two readings).
    // spec-example: undo-history-discard / the delete forecasts a floating edit
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
        }
    }

    /// Z1's shape: the edits were made while the series kept its zone, so the instant reading is the slot.
    func testAZonedSeriesWithEditsIsPlaced() throws {
        for zone in [taipei, losAngeles] {
            let slots = weekly(from: date(2027, 2, 11, 9, in: zone), count: 6, in: zone)
            let exceptions = try captured(slots, zone: zone) { occurrences in
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
        let exceptions = try captured(slots, zone: taipei) { occurrences in
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
        let exceptions = try captured(slots, zone: taipei) { occurrences in
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
    /// the window's start (4 hours, a host at +08:00). Floating, its `/RID=` read as an instant is 8 hours
    /// later, inside the window, so it is recorded and, off the rule, counted. Zoned, its instant is outside
    /// the window and it is not recorded. Renamed in round 3; fix round 4: the capture is `main`'s, which
    /// gives these answers by the instant alone.
    func testARecordJustOutsideTheWindowIsCountedOnlyWhenFloating() throws {
        let now = date(2026, 11, 16, 9, in: taipei)
        let window = SeriesExceptionsPlanner.deleteWindow(firstStart: now.addingTimeInterval(-3000 * day), end: .open, deletedAt: now).window
        let edge = window.start.addingTimeInterval(-4 * 3600)
        let slots = (-260...260).map { edge.addingTimeInterval(Double($0) * 7 * day) }
        for floating in [true, false] {
            let store = FakeSeriesExceptionsStore()
            store.seriesEnd = .open
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
            edit(occurrences[260], rid: floating ? floatingRID(slots[260], in: taipei) : zonedRID(slots[260]), title: "Before the edge")
            let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now))
            XCTAssertEqual(exceptions.detached.count, floating ? 1 : 0, "recorded by its instant reading only when floating")
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule()], firstSlot: slots[0],
                                                                calendar: .gregorian(in: taipei)), floating ? 1 : 0)
        }
    }

    /// Ruling G (the #503 verdict's own guard): a recorded occurrence not edited on its own that is no
    /// slot of the expander means the expander is wrong here, so no forecast.
    func testAKeptSlotOffTheExpanderGivesNoForecast() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let exceptions = try captured(slots, zone: taipei) { occurrences in
            edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Off the rule")
            occurrences[4].occurrenceDate = slots[4].addingTimeInterval(3600)
        }
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0],
                                                          calendar: .gregorian(in: taipei)))
    }

    /// Verify F33: the note does not count a record on its slot that ends before it starts (the restore,
    /// `main`'s, writes its one-off; on a device that save failed and the undo rolled back). DS1's shape
    /// (listed from 03:30 to 03:00 PDT) has a `/RID=` that read as an instant is no slot at Los Angeles, so it
    /// is counted, and the restore applies nothing; the same occurrence without a `/RID=` (its
    /// `occurrenceDate`) is on its slot and is not counted. Rewritten in fix round 4.
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
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: first, calendar: calendar), 1, "DS1: off the rule")
        let oneReading = try captured(slots, zone: losAngeles) { occurrences in
            occurrences[2].detached = true
            occurrences[2].title = "Edited on the change"
            occurrences[2].end = slots[2].addingTimeInterval(-30 * 60)
        }
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(oneReading, rules: [rule(count: 6)], firstSlot: first, calendar: calendar), 0, "one reading")
    }

    // MARK: - RulesAloneForecast

    private func wholeSeries(_ title: String = "Standup") -> UndoOperation {
        .deleteEvent(id: "S", snapshot: UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 6, startDate: Date(timeIntervalSinceReferenceDate: 0)))
    }

    private func edits(_ count: Int) -> RulesAloneOnUndo { RulesAloneOnUndo(edits: count) }

    /// Only a whole-series record with a forecast forecasts, in the order the rows were recorded.
    func testOnlyAWholeSeriesRecordWithUnplacedEditsForecasts() {
        var forecast = RulesAloneForecast()
        forecast.recorded(wholeSeries(), identifier: "A", unplacedEdits: edits(2))
        forecast.recorded(wholeSeries(), identifier: "B", unplacedEdits: nil)
        forecast.recorded(.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: []), identifier: "C", unplacedEdits: edits(3))
        forecast.recorded(wholeSeries(), identifier: "D", unplacedEdits: edits(1))
        XCTAssertEqual(forecast.expected, [.init(identifier: "A", forecast: edits(2)), .init(identifier: "D", forecast: edits(1))])
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

    // MARK: - C3: the dry run leaves out what earlier rows delete

    /// The dry run's capture of the series in `store`, leaving out the occurrences `gone` names, as
    /// `EventKitManager.captureSeriesExceptionsForDryRun` captures through `DryRunCaptureStore` (PR #558 fix
    /// round 5, verify finding Q2: by identity, before the capture reduces an occurrence to a slot; round 4 cut
    /// the record afterwards by a slot read from each identifier, which kept an opaque one and dropped a second
    /// occurrence at the same slot).
    private func dryRun(_ store: FakeSeriesExceptionsStore, _ first: FakeSeriesExceptionsStore.Event, now: Date,
                        gone: Set<String>) -> SeriesExceptions? {
        SeriesExceptionsUndo.capture(of: first, in: DryRunCaptureStore(base: store, gone: gone), now: now)
    }

    /// Two stores of the same six-week series: `shape` edits it; the second then has the occurrences at
    /// `goneIndices` removed, as the real call's earlier rows remove them before its series row captures.
    /// Asserts that the dry run's capture (before anything is removed, less `gone`) is the real call's, and
    /// returns the forecasts of the capture without the cut, of the dry run and of the real call.
    private func dryRunAgreesWithTheRealCall(goneIndices: [Int], file: StaticString = #filePath, line: UInt = #line,
                                             shape: ([FakeSeriesExceptionsStore.Event], [Date]) -> Void) throws
        -> (uncut: Int?, dryRun: Int?, real: Int?) {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        func store(dropping: Bool) -> (FakeSeriesExceptionsStore, FakeSeriesExceptionsStore.Event, Set<String>) {
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
            shape(occurrences, slots)
            let gone = Set(goneIndices.compactMap { occurrences[$0].id })
            if dropping { goneIndices.forEach { store.drop(occurrences[$0]) } }
            return (store, occurrences[0], gone)
        }
        let now = slots[0].addingTimeInterval(-30 * day)
        let (dry, first, gone) = store(dropping: false)
        let uncut = try XCTUnwrap(SeriesExceptionsUndo.capture(of: first, in: dry, now: now), file: file, line: line)
        let preview = try XCTUnwrap(dryRun(dry, first, now: now, gone: gone), file: file, line: line)
        let (real, realFirst, _) = store(dropping: true)
        let after = try XCTUnwrap(SeriesExceptionsUndo.capture(of: realFirst, in: real, now: now), file: file, line: line)
        XCTAssertEqual(preview.keptSlots, after.keptSlots, file: file, line: line)
        XCTAssertEqual(preview.detached.map(\.slot), after.detached.map(\.slot), file: file, line: line)
        XCTAssertEqual(preview.detached.map(\.snapshot.title), after.detached.map(\.snapshot.title), file: file, line: line)
        XCTAssertEqual(preview.windows, after.windows, file: file, line: line)
        let calendar = Calendar.gregorian(in: taipei)
        func forecast(_ exceptions: SeriesExceptions) -> Int? {
            SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 6)], firstSlot: slots[0], calendar: calendar)
        }
        return (forecast(uncut), forecast(preview), forecast(after))
    }

    /// PR #558 fix round 4 (verify finding C3): a `delete_events_batch` call with span `all` naming an edited
    /// occurrence's own identifier and its series runs the occurrence's row first, so the real call captures
    /// the series without it. The dry run captures before anything is deleted and leaves that occurrence out:
    /// the record, and so the forecast, are the real call's.
    // spec-example: undo-history-discard / the dry run leaves out what an earlier row deletes
    func testTheDryRunLeavesOutAnOccurrenceAnEarlierRowDeletes() throws {
        let forecasts = try dryRunAgreesWithTheRealCall(goneIndices: [2]) { occurrences, slots in
            // The third edited off the rule (a stale `/RID=`, cell N1), the fourth on its slot.
            edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Off the rule")
            edit(occurrences[3], rid: zonedRID(slots[3]), title: "On its slot")
        }
        XCTAssertEqual(forecasts.uncut, 1, "without the cut the dry run would forecast the rules alone")
        XCTAssertEqual(forecasts.dryRun, forecasts.real)
        XCTAssertEqual(forecasts.dryRun, 0)
    }

    /// PR #558 fix round 5 (verify finding Q2): an occurrence whose identifier is opaque, its `/RID=` only in
    /// its external identifier, is tied to the series by the capture, and an earlier row that deletes it by that
    /// identifier takes it out of the real call's capture. The dry run leaves it out by its identity.
    // spec-example: undo-history-discard / the dry run leaves out an opaque occurrence
    func testTheDryRunLeavesOutAnOpaqueOccurrenceAnEarlierRowDeletes() throws {
        let forecasts = try dryRunAgreesWithTheRealCall(goneIndices: [2]) { occurrences, slots in
            edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Off the rule")
            occurrences[2].id = "OPAQUE-3"
        }
        XCTAssertEqual(forecasts.uncut, 1)
        XCTAssertEqual(forecasts.dryRun, forecasts.real)
        XCTAssertEqual(forecasts.dryRun, 0)
    }

    /// PR #558 fix round 5 (verify finding Q2): two distinct occurrences recorded at one slot (one by its
    /// `<series id>/RID=` identifier, the other opaque with the same `/RID=` in its external identifier). An
    /// earlier row deletes the first; the real call still records the second, so the dry run keeps it.
    // spec-example: undo-history-discard / the dry run keeps another occurrence at the same slot
    func testTheDryRunKeepsAnotherOccurrenceRecordedAtTheSameSlot() throws {
        let forecasts = try dryRunAgreesWithTheRealCall(goneIndices: [2]) { occurrences, slots in
            let rid = zonedRID(slots[2].addingTimeInterval(3 * 3600))
            edit(occurrences[2], rid: rid, title: "Off the rule")
            edit(occurrences[4], rid: rid, title: "Same recorded slot")
            occurrences[4].id = "OPAQUE-5"
        }
        XCTAssertEqual(forecasts.uncut, 2)
        XCTAssertEqual(forecasts.dryRun, forecasts.real)
        XCTAssertEqual(forecasts.dryRun, 1)
    }

    /// An identifier of another series, or the series' own (a row that names it twice fails in both runs),
    /// leaves the record as it is.
    func testOtherIdentifiersCutNothing() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3 * 3600)), title: "Off the rule")
        edit(occurrences[3], rid: zonedRID(slots[3]), title: "On its slot")
        let now = slots[0].addingTimeInterval(-30 * day)
        let other = "T" + occurrences[2].id!.dropFirst()
        XCTAssertEqual(try XCTUnwrap(dryRun(store, occurrences[0], now: now, gone: [other])).detached.count, 2)
        let own = try XCTUnwrap(dryRun(store, occurrences[0], now: now, gone: ["S"]))
        XCTAssertEqual(own.detached.count, 2)
        XCTAssertEqual(own.keptSlots.count, 4)
    }

    // MARK: - Texts

    /// The text, word for word (PR #558 fix round 4: one cause, the restore's check; L7: the count is of the
    /// recorded edits; fix round 5, Q9: only what that check establishes).
    func testTheNotesSayTheForecastWithItsCount() {
        XCTAssertEqual(CheICalMCPServer.rulesAloneUndoNote(edits(2)),
                       "Undo is expected to bring this series back from its rules alone: 2 recorded occurrence(s) edited on their own have an original time, as this server reads it from their identifier, that is no slot of the series' rule as it was read at the delete, so the undo's check is expected to apply none of the exceptions recorded with it: the series is expected to be recreated from its rule, with no edited occurrence written back as a one-off event and no slot of it removed.")
        XCTAssertEqual(CheICalMCPServer.batchPreviewRulesAloneNote(edits(1)),
                       "Undo of this row would be expected to bring the series back from its rules alone: 1 recorded occurrence(s) edited on their own have an original time, as this server reads it from their identifier, that is no slot of the series' rule as it was read at the delete, so the undo's check is expected to apply none of the exceptions recorded with it: the series is expected to be recreated from its rule, with no edited occurrence written back as a one-off event and no slot of it removed.")
    }
}
