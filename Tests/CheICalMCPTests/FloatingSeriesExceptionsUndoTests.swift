import EventKit
import XCTest
@testable import CheICalMCP

/// #539: the undo of a whole-series delete on a series whose edited
/// occurrences carry a `/RID=` written while it had no time zone (the slot's wall-clock time as UTC),
/// run against the in-memory store under three host zones. The shapes are the device cells of #539
/// (F1, D2, R2, DS1, the window-edge path). PR #558 fix round 4: the whole-series undo is `main`'s, so
/// each of those shapes is run through `main`'s capture and restore too (`SeriesUndoOnMain`) and must give
/// the same answer and calendar: away from offset 0 the `/RID=` read as an instant is no slot of the
/// recreated series, so the series comes back from its rules alone ("did not match"); at UTC the edits come
/// back. The undo of one occurrence's delete is `main`'s too (fix round 5 removed ruling F); MA's chain, the
/// whole-series undo and then that occurrence's, is in `WholeSeriesUndoChainOnMainTests`. Each test names its
/// host zone; none reads the process's.
final class FloatingSeriesExceptionsUndoTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(identifier: "UTC")!
    private var zones: [TimeZone] { [taipei, losAngeles, utc] }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The `/RID=` suffix an occurrence edited while its series had no time zone reads back with: the
    /// slot's wall-clock time in `zone` written as UTC (iCloud, #539 cells F1-F3).
    private func floatingRID(_ slot: Date, in zone: TimeZone) -> String {
        var local = Calendar(identifier: .gregorian); local.timeZone = zone
        var utcCalendar = Calendar(identifier: .gregorian); utcCalendar.timeZone = utc
        let digits = utcCalendar.date(from: local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot))!
        return "/RID=\(Int(digits.timeIntervalSinceReferenceDate))"
    }

    /// The suffix of an occurrence edited while its series had a time zone: the slot's instant (#311).
    private func zonedRID(_ slot: Date) -> String { "/RID=\(Int(slot.timeIntervalSinceReferenceDate))" }

    /// Marks `occurrence` as edited on its own with `rid`, retitled, and moved by `moved`.
    private func edit(_ occurrence: FakeSeriesExceptionsStore.Event, rid: String, title: String, moved: TimeInterval = 0) {
        occurrence.id = "S" + rid
        occurrence.external = "X-S" + rid
        occurrence.detached = true
        occurrence.title = title
        occurrence.start = occurrence.start.addingTimeInterval(moved)
        occurrence.occurrenceDate = occurrence.start
    }

    /// What one undo left: its answer and the calendar.
    struct Undone: Equatable {
        let outcome: UndoEventOutcome?
        let calendar: [String]
    }

    private func key(_ event: FakeSeriesExceptionsStore.Event) -> String { "\(Int(event.start.timeIntervalSinceReferenceDate)) \(event.title)" }

    /// Captures the series in `store` at `now`, then undoes its delete in a fresh store whose recreated
    /// series generates `slots`; the same through `main`'s capture and undo, each in its own fresh store.
    private func deleteAndUndo(_ first: FakeSeriesExceptionsStore.Event, in store: FakeSeriesExceptionsStore, slots: [Date],
                               now: Date, zone: TimeZone, file: StaticString = #filePath, line: UInt = #line) throws
        -> (outcome: UndoEventOutcome?, after: FakeSeriesExceptionsStore, calendar: String, main: Undone) {
        func series(_ exceptions: SeriesExceptions) -> EventSnapshot {
            UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: slots.count, startDate: slots[0]).withExceptions(exceptions)
                .withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
        }
        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: first, in: store, now: now), file: file, line: line)
        let undone = try undo(series(exceptions), slots: slots, zone: zone)
        let onMain = try XCTUnwrap(SeriesUndoOnMain.capture(of: first, in: store, now: now), file: file, line: line)
        let recorded = series(onMain)
        let mainAfter = FakeSeriesExceptionsStore()
        mainAfter.zone = zone
        mainAfter.seriesSlots = slots
        let mainOutcome = try SeriesUndoOnMain.recreateDeletedEvent(recorded, calendar: recorded.calendarIdentifier, in: mainAfter).outcome
        return (undone.outcome, undone.after, undone.calendar, Undone(outcome: mainOutcome, calendar: mainAfter.events.map(key).sorted()))
    }

    /// Undoes the delete of `series` (recorded as series S) in a fresh store whose recreated series
    /// generates `slots`.
    private func undo(_ series: EventSnapshot, slots: [Date], zone: TimeZone) throws
        -> (outcome: UndoEventOutcome?, after: FakeSeriesExceptionsStore, calendar: String) {
        let recorded = series.withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
        let after = FakeSeriesExceptionsStore()
        after.zone = zone
        after.seriesSlots = slots
        let (_, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(recorded, calendar: recorded.calendarIdentifier, in: after)
        return (outcome, after, recorded.calendarIdentifier)
    }

    /// The production undo left what `main`'s did.
    private func assertAsOnMain(_ run: (outcome: UndoEventOutcome?, after: FakeSeriesExceptionsStore, calendar: String, main: Undone),
                                _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Undone(outcome: run.outcome, calendar: run.after.events.map(key).sorted()), run.main, label, file: file, line: line)
    }

    private func weekly(from first: Date, count: Int) -> [Date] { (0..<count).map { first.addingTimeInterval(Double($0) * 7 * day) } }

    private let notApplied = UndoEventOutcome.seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true))

    // MARK: - F1, D2, R2

    /// F1: six weekly occurrences at 10:00 local; the third retitled and the fourth moved an hour,
    /// both while the series had no zone. Away from offset 0 the undo brings the series back from its
    /// rules alone, both edits lost, saying the recorded exceptions did not match, as on `main`; at UTC
    /// both come back. Rewritten in PR #558 fix round 4 (rounds 0 to 2 brought both back as one-off
    /// events, round 3 gave its own reason).
    // spec-example: undo-history-discard / a floating edit comes back as on main
    func testFloatingEditsComeBackOnlyAtOffsetZero() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 10, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
            edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Retitled")
            edit(occurrences[3], rid: floatingRID(slots[3], in: zone), title: "Moved", moved: 3600)

            let run = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            assertAsOnMain(run, zone.identifier)
            if zone == utc {
                XCTAssertEqual(run.outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)), zone.identifier)
                XCTAssertEqual(run.after.starts(of: "E1"), [slots[0], slots[1], slots[4], slots[5]], zone.identifier)
                XCTAssertEqual(Set(run.after.events.filter { $0.id != "E1" }.map(\.title)), ["Retitled", "Moved"], zone.identifier)
            } else {
                XCTAssertEqual(run.outcome, notApplied, zone.identifier)
                XCTAssertEqual(run.after.starts(of: "E1"), slots, zone.identifier)
                XCTAssertEqual(run.after.events.count, 6, zone.identifier)
            }
        }
    }

    /// D2: the third retitled floating and the fifth deleted on its own: away from offset 0 both come back
    /// from the rules (the deletion undone, the edit lost), as on `main`; at UTC the deletion stays and the
    /// edit comes back.
    func testAFloatingEditAndADeletionComeBackFromTheRulesAlone() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 6, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
            edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Retitled")
            store.drop(occurrences[4])

            let run = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            assertAsOnMain(run, zone.identifier)
            if zone == utc {
                XCTAssertEqual(run.outcome, .seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 1)), zone.identifier)
                XCTAssertEqual(run.after.starts(of: "E1"), [slots[0], slots[1], slots[3], slots[5]], zone.identifier)
            } else {
                XCTAssertEqual(run.outcome, notApplied, zone.identifier)
                XCTAssertEqual(run.after.starts(of: "E1"), slots, zone.identifier)
            }
        }
    }

    /// R2: one series holding both kinds: the third edited while it had a zone (an instant), the fourth
    /// after `clear_timezone` (a wall-clock time). Away from offset 0 the fourth's `/RID=` read as an instant
    /// is no slot, so nothing is applied, as on `main`; at UTC both come back.
    func testOneSeriesHoldingBothKindsOfRIDComesBackFromTheRulesAlone() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 12, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
            edit(occurrences[2], rid: zonedRID(slots[2]), title: "Zoned edit")
            edit(occurrences[3], rid: floatingRID(slots[3], in: zone), title: "Floating edit", moved: 3600)

            let run = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            assertAsOnMain(run, zone.identifier)
            XCTAssertEqual(run.outcome, zone == utc ? .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)) : notApplied, zone.identifier)
        }
    }

    /// L1, L3 (PR #558 verify round 4): an occurrence edited while the series had its zone, then
    /// `clear_timezone` at the same wall-clock time, no move, another occurrence deleted on its own. Its
    /// `/RID=` is an instant and a slot of the recreated series, so the edit comes back and the deletion
    /// stays, in every host zone, as on `main` (round 3 stopped the restore here away from offset 0).
    func testAnEditMadeWhileTheSeriesHadItsZoneComesBackAfterClearTimezone() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 12, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
            edit(occurrences[2], rid: zonedRID(slots[2]), title: "Zoned edit")
            store.drop(occurrences[4])

            let run = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            assertAsOnMain(run, zone.identifier)
            XCTAssertEqual(run.outcome, .seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 1)), zone.identifier)
            XCTAssertEqual(run.after.starts(of: "E1"), [slots[0], slots[1], slots[3], slots[5]], zone.identifier)
        }
    }

    /// DS1 (iCloud, 2026-11-17, a server with `TZ=America/Los_Angeles`): a floating weekly series at
    /// 02:30, 30 minutes long, its occurrence of 2027-03-14 (no 02:30 that day there) retitled. The store
    /// listed it from 03:30 to 03:00 PDT. Its `/RID=` read as an instant is no slot at Los Angeles, so the
    /// series comes back from its rules alone, saying the recorded exceptions did not match, as on `main`.
    func testDS1ComesBackFromTheRulesAloneAsOnMain() throws {
        let zone = losAngeles
        let first = date(2027, 2, 28, 2, in: zone).addingTimeInterval(30 * 60)
        let rule = DeletedOccurrenceCheck.Rule(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                               occurrenceCount: 6, hasOtherParts: false)
        let slots = Array(try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule, firstStart: first, until: first.addingTimeInterval(60 * day),
                                                                             calendar: .gregorian(in: zone))).prefix(6))
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        let nominal = Calendar.gregorian(in: utc).date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 2, minute: 30))!
        edit(occurrences[2], rid: "/RID=\(Int(nominal.timeIntervalSinceReferenceDate))", title: "Retitled")
        occurrences[2].end = slots[2].addingTimeInterval(-30 * 60)

        let run = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

        assertAsOnMain(run, "DS1")
        XCTAssertEqual(run.outcome, notApplied)
        XCTAssertEqual(run.after.starts(of: "E1"), slots)
        XCTAssertFalse(run.after.events.contains { $0.title == "Retitled" }, "nothing written for it")
    }

    /// C2 (PR #558 verify round 4): a record that ends before it starts is treated as on `main` (round 3's
    /// ruling E, which stopped the restore, is removed). On its own slot it is written as a one-off (on a
    /// device such a save failed, `EKErrorDatesInverted`, and the restore rolled back, as on `main`); on the
    /// series' first slot it is kept from the rule and a later record is still applied.
    func testARecordThatEndsBeforeItStartsIsRestoredAsOnMain() throws {
        let window = DateInterval(start: date(2027, 2, 10, 0, in: taipei), end: date(2027, 3, 21, 0, in: taipei))
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let generated = slots.map { (slot: $0, occurrence: $0) }
        func record(at slot: Date, end: Date) -> DetachedOccurrence {
            DetachedOccurrence(slot: slot, snapshot: UndoSnapshotFixtures.event(title: "Edited", startDate: slot, endDate: end))
        }
        func restore(_ detached: [DetachedOccurrence], onMain: Bool) throws -> SeriesExceptionsRestorer.Outcome {
            let kept = slots.filter { slot in !detached.contains { UndoPostState.sameInstant($0.slot, slot) } }
            let exceptions = SeriesExceptions(window: window, keptSlots: kept, detached: detached)
            return onMain
                ? try SeriesExceptionsRestorer.restoreAtBase(exceptions: exceptions, seriesStart: slots[0], generated: generated, remove: { _ in },
                                                              createOneOff: { _ in 0 }, removeOneOff: { _ in }, rollbackSeries: {})
                : try SeriesExceptionsRestorer.restore(exceptions: exceptions, seriesStart: slots[0], generated: generated, remove: { _ in },
                                                       createOneOff: { _ in 0 }, removeOneOff: { _ in }, rollbackSeries: {})
        }
        let shapes: [(String, [DetachedOccurrence], SeriesExceptionsRestorer.Outcome)] = [
            ("ends where it starts", [record(at: slots[2], end: slots[2])], .init(stayedDeleted: 0, oneOffs: 1)),
            ("ends before it starts", [record(at: slots[2], end: slots[2].addingTimeInterval(-60))], .init(stayedDeleted: 0, oneOffs: 1)),
            ("on the first slot, a later record beside it",
             [record(at: slots[0], end: slots[0].addingTimeInterval(-60)), record(at: slots[3], end: slots[3].addingTimeInterval(3600))],
             .init(stayedDeleted: 0, oneOffs: 1, firstOccurrenceKeptFromRule: true)),
        ]
        for (label, detached, expected) in shapes {
            XCTAssertEqual(try restore(detached, onMain: false), try restore(detached, onMain: true), label)
            XCTAssertEqual(try restore(detached, onMain: false), expected, label)
        }
    }

    // MARK: - the window-edge path (read in the Diagnosis; cannot be made on a device)

    /// An open weekly series begun years before the delete, so its window is cut at 1460 days around
    /// the delete (`SeriesExceptionsPlanner.deleteWindow`), with one occurrence edited on its own at
    /// `edgeSlot` and one well inside.
    private func edgeCase(zone: TimeZone, floating: Bool, edgeSlot: (DateInterval) -> Date) throws
        -> (outcome: UndoEventOutcome?, after: FakeSeriesExceptionsStore, calendar: String, main: Undone) {
        let now = date(2026, 11, 16, 9, in: zone)
        let window = SeriesExceptionsPlanner.deleteWindow(firstStart: now.addingTimeInterval(-3000 * day), end: .open, deletedAt: now).window
        let edge = edgeSlot(window)
        let slots = (-260...260).map { edge.addingTimeInterval(Double($0) * 7 * day) }
        let store = FakeSeriesExceptionsStore()
        store.seriesEnd = .open
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        let edgeIndex = 260
        let insideIndex = slots.firstIndex { $0 > now }!
        func rid(_ slot: Date) -> String { floating ? floatingRID(slot, in: zone) : zonedRID(slot) }
        edit(occurrences[edgeIndex], rid: rid(slots[edgeIndex]), title: "At the edge")
        edit(occurrences[insideIndex], rid: rid(slots[insideIndex]), title: "Inside")
        return try deleteAndUndo(occurrences[0], in: store, slots: slots, now: now, zone: zone)
    }

    /// The four shapes of the plan, at +08:00 and -08:00, each restored as on `main`. East of UTC a floating
    /// `/RID=` read as an instant is later than its slot, west of it earlier, so each shape is built at the
    /// edge where it arises. Rewritten in PR #558 round 1 and round 3, and in fix round 4 (the capture and
    /// the restore are `main`'s). This shows that each shape gives `main`'s calendar and answer, and that the
    /// zoned edit inside the window comes back; it does not show what `main` does with a floating edit whose
    /// true slot is inside the window and whose instant reading is outside (fix round 5, verify finding P8):
    /// in these shapes the other floating edit already makes the check apply nothing.
    func testTheFourWindowEdgeShapesAreAsOnMain() throws {
        let hours: TimeInterval = 3600
        for zone in [taipei, losAngeles] {
            let east = zone.secondsFromGMT() > 0
            let shapes: [(String, Bool, (DateInterval) -> Date)] = [
                ("floating inside", true, { east ? $0.end.addingTimeInterval(-4 * hours) : $0.start.addingTimeInterval(4 * hours) }),
                ("floating outside", true, { east ? $0.start.addingTimeInterval(-4 * hours) : $0.end.addingTimeInterval(4 * hours) }),
                ("zoned inside", false, { east ? $0.start.addingTimeInterval(4 * hours) : $0.end.addingTimeInterval(-4 * hours) }),
                ("zoned outside", false, { east ? $0.end.addingTimeInterval(4 * hours) : $0.start.addingTimeInterval(-4 * hours) }),
            ]
            for (label, floating, edge) in shapes {
                assertAsOnMain(try edgeCase(zone: zone, floating: floating, edgeSlot: edge), "\(label), \(zone.identifier)")
            }
            let zonedInside = try edgeCase(zone: zone, floating: false, edgeSlot: shapes[2].2)
            XCTAssertEqual(zonedInside.outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)), "zoned inside, \(zone.identifier)")
        }
    }
}
