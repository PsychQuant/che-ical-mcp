import EventKit
import XCTest
@testable import CheICalMCP

/// #539: the undo of a whole-series delete, and of one occurrence's delete, on a series whose edited
/// occurrences carry a `/RID=` written while it had no time zone (the slot's wall-clock time as UTC),
/// run against the in-memory store under three host zones. The shapes are the device cells of #539
/// (F1, D2, R2, MA, the window-edge path). Each test names its host zone; none reads the process's.
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

    /// Captures the series in `store` at `now`, then undoes its delete in a fresh store whose recreated
    /// series generates `slots`.
    private func deleteAndUndo(_ first: FakeSeriesExceptionsStore.Event, in store: FakeSeriesExceptionsStore, slots: [Date],
                               now: Date, zone: TimeZone, file: StaticString = #filePath, line: UInt = #line) throws
        -> (outcome: UndoEventOutcome?, after: FakeSeriesExceptionsStore, calendar: String) {
        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: first, in: store, now: now, zone: zone), file: file, line: line)
        return try undo(UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: slots.count, startDate: slots[0]).withExceptions(exceptions),
                        slots: slots, zone: zone)
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

    private func weekly(from first: Date, count: Int) -> [Date] { (0..<count).map { first.addingTimeInterval(Double($0) * 7 * day) } }

    // MARK: - F1, D2, R2

    /// F1: six weekly occurrences at 10:00 local; the third retitled and the fourth moved an hour,
    /// both while the series had no zone. Undo brings both back as one-off events (before #539: from
    /// the rules alone, both edits lost), in every host zone.
    // spec-example: undo-history-discard / a floating edit comes back
    func testFloatingEditsComeBackInEveryHostZone() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 10, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
            edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Retitled")
            edit(occurrences[3], rid: floatingRID(slots[3], in: zone), title: "Moved", moved: 3600)

            let (outcome, after, _) = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)), zone.identifier)
            XCTAssertEqual(after.starts(of: "E1"), [slots[0], slots[1], slots[4], slots[5]], zone.identifier)
            XCTAssertEqual(Set(after.events.filter { $0.id != "E1" }.map(\.title)), ["Retitled", "Moved"], zone.identifier)
        }
    }

    /// D2: the third retitled floating and the fifth deleted on its own: the deletion stays and the
    /// edit comes back (before #539 both were lost: the deleted occurrence came back from the rules).
    func testAFloatingEditAndADeletionAreBothRestored() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 6, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
            edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Retitled")
            store.drop(occurrences[4])

            let (outcome, after, _) = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 1)), zone.identifier)
            XCTAssertEqual(after.starts(of: "E1"), [slots[0], slots[1], slots[3], slots[5]], zone.identifier)
        }
    }

    /// R2: one series holding both kinds: the third edited while it had a zone (an instant), the fourth
    /// after `clear_timezone` (a wall-clock time). Both come back.
    func testOneSeriesHoldingBothKindsOfRIDIsRestored() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 12, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
            edit(occurrences[2], rid: zonedRID(slots[2]), title: "Zoned edit")
            edit(occurrences[3], rid: floatingRID(slots[3], in: zone), title: "Floating edit", moved: 3600)

            let (outcome, _, _) = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)

            XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)), zone.identifier)
        }
    }

    /// A record neither reading of which is a slot of the recreated series (an edit whose series' time
    /// was changed afterwards, or a `/RID=` in a unit not seen yet) applies nothing, as before #539:
    /// all or nothing, so the occurrence deleted on its own comes back with the rest.
    func testARecordThatCannotBePlacedAppliesNothing() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
        edit(occurrences[2], rid: floatingRID(slots[2].addingTimeInterval(3 * 3600), in: taipei), title: "Retitled")
        edit(occurrences[3], rid: floatingRID(slots[3], in: taipei), title: "Placed")
        store.drop(occurrences[4])

        let (outcome, after, _) = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: taipei)

        XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true)))
        XCTAssertEqual(after.starts(of: "E1"), slots)
    }

    /// DS1 (iCloud, 2026-11-17, a server with `TZ=America/Los_Angeles`): a floating weekly series at
    /// 02:30, 30 minutes long, its occurrence of 2027-03-14 (no 02:30 that day there) retitled. The store
    /// listed it from 03:30 to 03:00 PDT: both readings put it on its slot, so it was placed, and the
    /// one-off save failed (`eventkit_error_4`, its end before its start), so the undo restored nothing
    /// and the series stayed deleted. Such a record now applies nothing, as before #539, and the series
    /// comes back from its rules.
    // spec-example: undo-history-discard / DS1
    func testAPlacedRecordThatEndsBeforeItStartsAppliesNothing() throws {
        let zone = losAngeles
        let first = date(2027, 2, 28, 2, in: zone).addingTimeInterval(30 * 60)
        let rule = DeletedOccurrenceCheck.Rule(frequency: .weekly, interval: 1, daysOfWeek: [], daysOfMonth: [], endDate: nil,
                                               occurrenceCount: 6, hasOtherParts: false)
        let slots = Array(try XCTUnwrap(DeletedOccurrenceCheck.expectedSlots(of: rule, firstStart: first, until: first.addingTimeInterval(60 * day),
                                                                             calendar: .gregorian(in: zone))).prefix(6))
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
        let nominal = Calendar.gregorian(in: utc).date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 2, minute: 30))!
        edit(occurrences[2], rid: "/RID=\(Int(nominal.timeIntervalSinceReferenceDate))", title: "Retitled")
        occurrences[2].end = slots[2].addingTimeInterval(-30 * 60)

        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: slots[0].addingTimeInterval(-30 * day), zone: zone))
        let recorded = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: slots.count, startDate: slots[0]).withExceptions(exceptions)
            .withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
        let after = FakeSeriesExceptionsStore()
        after.zone = zone
        after.seriesSlots = slots
        let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(recorded, calendar: recorded.calendarIdentifier, in: after)

        XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true, endsBeforeStart: true)))
        XCTAssertEqual(after.starts(of: "E1"), slots)
        XCTAssertFalse(after.events.contains { $0.title == "Retitled" }, "nothing written for it")
        // The text the undo returns, from the production arm.
        XCTAssertTrue(text.hasSuffix(". Restored from the series rules alone: an occurrence edited on its own ends before it starts as this Mac's time zone reads it (its time falls in a daylight-saving change), so it cannot be written as a one-off event, and none of the recorded exceptions was applied (an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit)"), text)
    }

    /// The check reads every record the restore places: one that ends where it starts is written; one
    /// that ends before it starts stops the restore whatever its number of readings (PR #558 round 1,
    /// ruling E: a record of one reading used to be attempted and fail, F7); a record of two readings
    /// placed outside every window applies nothing before the check is read (ruling C). Rewritten in
    /// round 1: before it, the one-reading record was attempted and the outside one was dropped.
    func testEveryPlacedRecordThatEndsBeforeItStartsStopsTheRestore() throws {
        let window = DateInterval(start: date(2027, 2, 10, 0, in: taipei), end: date(2027, 3, 21, 0, in: taipei))
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let generated = slots.map { (slot: $0, occurrence: $0) }
        func record(at slot: Date, end: Date, twoReadings: Bool) -> DetachedOccurrence {
            let readings = twoReadings ? SlotReadings(instant: slot.addingTimeInterval(8 * 3600), wallClock: slot) : SlotReadings(instant: slot)
            return DetachedOccurrence(slot: readings.instant, snapshot: UndoSnapshotFixtures.event(title: "Edited", startDate: slot, endDate: end),
                                      readings: readings)
        }
        func restore(_ detached: [DetachedOccurrence], margins: [Date] = []) throws -> SeriesExceptionsRestorer.Outcome {
            let kept = slots.filter { slot in !detached.contains { UndoPostState.sameInstant($0.snapshot.startDate, slot) } }
            return try SeriesExceptionsRestorer.restore(
                exceptions: SeriesExceptions(window: window, keptSlots: kept, detached: detached), seriesStart: slots[0],
                generated: generated, marginSlots: margins, remove: { _ in }, createOneOff: { _ in 0 }, removeOneOff: { _ in },
                rollbackSeries: {})
        }
        XCTAssertEqual(try restore([record(at: slots[2], end: slots[2], twoReadings: true)]),
                       .init(stayedDeleted: 0, oneOffs: 1), "ends where it starts: written")
        XCTAssertEqual(try restore([record(at: slots[2], end: slots[2].addingTimeInterval(-60), twoReadings: false)]),
                       .init(stayedDeleted: 0, oneOffs: 0, notApplied: true, endsBeforeStart: true), "one reading")
        let outside = window.end.addingTimeInterval(2 * 3600)
        XCTAssertEqual(try restore([record(at: slots[2], end: slots[2].addingTimeInterval(3600), twoReadings: true),
                                    record(at: outside, end: outside.addingTimeInterval(3600), twoReadings: true)], margins: [outside]),
                       .init(stayedDeleted: 0, oneOffs: 0, notApplied: true), "placed outside the window: nothing applied")
        // PR #558 round 2 (H17): the check reads placed records only, after the placement: a record that is not
        // placed (outside every window) and ends before it starts gives the placement's answer, not the
        // daylight-saving one.
        XCTAssertEqual(try restore([record(at: slots[2], end: slots[2].addingTimeInterval(3600), twoReadings: true),
                                    record(at: outside, end: outside.addingTimeInterval(-60), twoReadings: true)], margins: [outside]),
                       .init(stayedDeleted: 0, oneOffs: 0, notApplied: true), "not placed, ends before it starts: not the daylight-saving answer")
        XCTAssertEqual(try restore([record(at: slots[2], end: slots[2].addingTimeInterval(-60), twoReadings: true)]),
                       .init(stayedDeleted: 0, oneOffs: 0, notApplied: true, endsBeforeStart: true))
    }

    // MARK: - the window-edge path (read in the Diagnosis; cannot be made on a device)

    /// An open weekly series begun years before the delete, so its window is cut at 1460 days around
    /// the delete (`SeriesExceptionsPlanner.deleteWindow`), with one occurrence edited on its own at
    /// `edgeSlot` and one well inside. Returns the outcome and the recreated series' starts.
    private func edgeCase(zone: TimeZone, floating: Bool, edgeSlot: (DateInterval) -> Date) throws
        -> (outcome: UndoEventOutcome?, starts: [Date], edge: Date, window: DateInterval) {
        let now = date(2026, 11, 16, 9, in: zone)
        let window = SeriesExceptionsPlanner.deleteWindow(firstStart: now.addingTimeInterval(-3000 * day), end: .open, deletedAt: now).window
        let edge = edgeSlot(window)
        let slots = (-260...260).map { edge.addingTimeInterval(Double($0) * 7 * day) }
        let store = FakeSeriesExceptionsStore()
        store.seriesEnd = .open
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: floating)
        let edgeIndex = 260
        let insideIndex = slots.firstIndex { $0 > now }!
        func rid(_ slot: Date) -> String { floating ? floatingRID(slot, in: zone) : zonedRID(slot) }
        edit(occurrences[edgeIndex], rid: rid(slots[edgeIndex]), title: "At the edge")
        edit(occurrences[insideIndex], rid: rid(slots[insideIndex]), title: "Inside")
        let (outcome, after, _) = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: now, zone: zone)
        return (outcome, after.starts(of: "E1"), edge, window)
    }

    /// The four shapes of the plan, at +08:00 and -08:00. East of UTC a floating `/RID=` read as an
    /// instant is later than its slot, west of it earlier, so each shape is built at the edge where it
    /// arises. Rewritten in PR #558 round 1 (rulings A and C): the floating record placed outside applies
    /// nothing, and the zoned one is not recorded.
    func testTheFourWindowEdgeShapes() throws {
        let hours: TimeInterval = 3600
        for zone in [taipei, losAngeles] {
            let east = zone.secondsFromGMT() > 0
            // Floating, true slot inside, instant reading outside: recorded and applied (before #539 its
            // slot was removed as surplus: the occurrence was lost, not only its edit).
            let inside = try edgeCase(zone: zone, floating: true) { east ? $0.end.addingTimeInterval(-4 * hours) : $0.start.addingTimeInterval(4 * hours) }
            XCTAssertEqual(inside.outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)), "floating inside, \(zone.identifier)")
            XCTAssertFalse(inside.starts.contains(inside.edge), "it comes back as a one-off, not from the rule")
            // Floating, true slot just outside, instant reading inside: placed in the margin, so nothing
            // is applied (PR #558 round 1, ruling C; round 0 dropped it and applied the rest; before #539
            // it was recorded under the wrong slot and nothing was applied).
            let outside = try edgeCase(zone: zone, floating: true) { east ? $0.start.addingTimeInterval(-4 * hours) : $0.end.addingTimeInterval(4 * hours) }
            XCTAssertEqual(outside.outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true)), "floating outside, \(zone.identifier)")
            XCTAssertTrue(outside.starts.contains(outside.edge), "left to the rule")
            // Zoned, true slot inside: applied, as before #539.
            let zonedInside = try edgeCase(zone: zone, floating: false) { east ? $0.start.addingTimeInterval(4 * hours) : $0.end.addingTimeInterval(-4 * hours) }
            XCTAssertEqual(zonedInside.outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 2)), "zoned inside, \(zone.identifier)")
            // Zoned, true slot just outside, its wall-clock reading inside: one reading (ruling A), so it is
            // not recorded and the rest is applied, as before #539.
            let zonedOutside = try edgeCase(zone: zone, floating: false) { east ? $0.end.addingTimeInterval(4 * hours) : $0.start.addingTimeInterval(-4 * hours) }
            XCTAssertEqual(zonedOutside.outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 1)), "zoned outside, \(zone.identifier)")
            XCTAssertTrue(zonedOutside.starts.contains(zonedOutside.edge))
        }
    }

    // MARK: - MA: the slot guard of #321 on a floating series

    /// MA: the third occurrence, edited floating, is deleted through its own identifier; then the whole
    /// series; undo of the series, then undo of the occurrence. With the series restored with its
    /// exceptions the third slot stays empty and the second undo writes one one-off: one event there.
    // spec-example: undo-history-discard / MA writes one event
    func testTheChainOfMAWritesNoDuplicate() throws {
        for zone in zones {
            let slots = weekly(from: date(2027, 2, 11, 5, in: zone), count: 6)
            let store = FakeSeriesExceptionsStore()
            store.zone = zone
            let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots, floating: true)
            edit(occurrences[2], rid: floatingRID(slots[2], in: zone), title: "Third")
            edit(occurrences[4], rid: floatingRID(slots[4], in: zone), title: "Fifth")
            let third = occurrences[2]
            let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: third.id, externalIdentifier: third.external,
                                                           occurrenceDate: third.occurrenceDate, isAllDay: false, isDetached: true, floating: true, zone: zone))
            store.drop(third)
            let (seriesOutcome, after, calendar) = try deleteAndUndo(occurrences[0], in: store, slots: slots, now: slots[0].addingTimeInterval(-30 * day), zone: zone)
            XCTAssertEqual(seriesOutcome, .seriesWithExceptions(.init(stayedDeleted: 1, oneOffs: 1)), zone.identifier)

            let record = UndoSnapshotFixtures.event(title: "Third", startDate: slots[2]).withOccurrenceOrigin(origin)
            let (_, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(record, notCarriedOver: [], calendar: calendar, in: after)

            XCTAssertEqual(outcome, .occurrenceOneOff(notCarriedOver: []), zone.identifier)
            XCTAssertEqual(after.events.filter { UndoPostState.sameInstant($0.start, slots[2]) }.count, 1, "one event there, \(zone.identifier)")
        }
    }

    /// MA's second undo after a restore from the rules alone (no exceptions recorded): the recreated
    /// series has a plain occurrence at the third slot, the wall-clock reading of the record's `/RID=`,
    /// and none at its instant reading. Before #539 the undo wrote a second event there; round 0 of PR
    /// #558 answered "already restored" and used the entry up. Round 1 (ruling F): this server cannot tell
    /// which reading is the slot, so the undo is refused, nothing is written and the entry is kept (the
    /// error is not an `UnrecoverableUndoError`). Rewritten in round 1.
    // spec-example: undo-history-discard / the restored series holds the wall-clock reading
    func testAfterARulesAloneRestoreTheFloatingOccurrenceIsRefusedAndKept() throws {
        for zone in [taipei, losAngeles] {
            let slots = weekly(from: date(2027, 2, 11, 5, in: zone), count: 6)
            let (_, after, calendar) = try undo(UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 6, startDate: slots[0]),
                                                slots: slots, zone: zone)
            let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + floatingRID(slots[2], in: zone), externalIdentifier: nil,
                                                           occurrenceDate: nil, isAllDay: false, isDetached: true, floating: true, zone: zone))
            let record = UndoSnapshotFixtures.event(title: "Third", startDate: slots[2]).withOccurrenceOrigin(origin)
            let before = after.events.count

            XCTAssertThrowsError(try SeriesExceptionsUndo.undoDeleteOccurrence(record, notCarriedOver: [], calendar: calendar, in: after)) { error in
                XCTAssertEqual((error as? OccurrenceSlotWallClockRefusal)?.message,
                               OccurrenceSlotWallClockRefusal(title: "Third", kind: .recreateDeletedOccurrence).message)
                XCTAssertEqual(UndoFailureDisposition.of(error), .restore, "the entry is kept")
            }
            XCTAssertEqual(after.events.count, before, "nothing written, \(zone.identifier)")
            // The rule-less record of a whole-series delete of that occurrence through its own identifier
            // (PR #318 round 3, finding 22) is refused the same way.
            XCTAssertThrowsError(try SeriesExceptionsUndo.undoDeleteEvent(record, calendar: calendar, in: after)) { error in
                XCTAssertEqual((error as? OccurrenceSlotWallClockRefusal)?.message,
                               OccurrenceSlotWallClockRefusal(title: "Third", kind: .recreateDeleted).message)
            }
            XCTAssertEqual(after.events.count, before)
            // PR #558 round 2 (H19): the split move's kind, through the store-level slot check, gives the
            // move's words (`slotCheck` passes its kind on).
            XCTAssertThrowsError(try SeriesExceptionsUndo.undoDeleteOccurrence(record, notCarriedOver: [], calendar: calendar,
                                                                               kind: .undoMoveByCopy, in: after)) { error in
                XCTAssertEqual((error as? OccurrenceSlotWallClockRefusal)?.message,
                               OccurrenceSlotWallClockRefusal(title: "Third", kind: .undoMoveByCopy).message)
            }
            XCTAssertEqual(after.events.count, before)
        }
    }

    /// The refusal's text, in a deletion's and a move's words (fixed words and the title only). PR #558
    /// round 2: the move's slot is the moved occurrence's (H16), and each says what giving it up keeps (H23).
    func testTheWallClockRefusalText() {
        XCTAssertEqual(OccurrenceSlotWallClockRefusal(title: "Third", kind: .recreateDeletedOccurrence).message,
                       "Cannot undo the deletion of an occurrence of 'Third': its series had no time zone when it was deleted, so its recorded time can be wall-clock time or an instant, and its series holds an occurrence at the time this Mac's time zone reads it as, but none at the instant. This server cannot tell whether that occurrence is at the deleted occurrence's slot (a one-off event beside it would be a second event there), so nothing was written and this history entry was kept. Giving it up leaves the calendar as it is: this entry holds the only copy of the deleted occurrence and of any edit it had, and this server has no other way to write it back (it can be made again by hand in Calendar). To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.")
        XCTAssertEqual(OccurrenceSlotWallClockRefusal(title: "Third", kind: .undoMoveByCopy).message,
                       "Cannot undo the move of an occurrence of 'Third': its series had no time zone when it was moved, so its recorded time can be wall-clock time or an instant, and its series holds an occurrence at the time this Mac's time zone reads it as, but none at the instant. This server cannot tell whether that occurrence is at the moved occurrence's original slot (a one-off event beside it would be a second event there), so nothing was written, the copy the move made stays in the calendar it was moved to, and this history entry was kept. Giving it up leaves the calendar as it is: the copy keeps the occurrence and its edits. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.")
        XCTAssertEqual(OccurrenceSlotWallClockRefusal(title: "", kind: .recreateDeleted).message.prefix(51),
                       "Cannot undo the deletion of an occurrence of: its s")
    }

    /// The guard on its own (MA after a restore from the rules alone): a plain occurrence of the series
    /// at the true slot is seen at the wall-clock reading, though the record's `/RID=` read as an instant
    /// is hours away; the answer is the refusal (ruling F), not held. Rewritten in PR #558 round 1.
    func testAPlainOccurrenceAtTheWallClockReadingIsSeenThere() throws {
        for zone in [taipei, losAngeles] {
            let slot = date(2027, 2, 25, 5, in: zone)
            let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: "S" + floatingRID(slot, in: zone), externalIdentifier: nil,
                                                           occurrenceDate: nil, isAllDay: false, isDetached: true, floating: true, zone: zone))
            XCTAssertNotEqual(origin.slot, slot, "the instant reading is off by the host's offset")
            let holder = OccurrenceSlotGuard.SeriesHolder(ids: .init(eventIdentifier: "S", externalIdentifier: nil), slot: slot)
            XCTAssertEqual(OccurrenceSlotGuard.answer(origin, recreatedAs: [], by: [holder]), .heldAtWallClockOnly, zone.identifier)
            let elsewhere = OccurrenceSlotGuard.SeriesHolder(ids: .init(eventIdentifier: "S", externalIdentifier: nil), slot: slot.addingTimeInterval(7 * day))
            XCTAssertEqual(OccurrenceSlotGuard.answer(origin, recreatedAs: [], by: [elsewhere]), .free, zone.identifier)
        }
    }
}
