import EventKit
import XCTest
@testable import CheICalMCP

/// #539 fix round 1 (PR #558 verify F1-F3, F6, F8; ruling A): an occurrence of a series that has a
/// time zone has one reading of its `/RID=`, the instant, and every undo path for it is `main`'s.
/// The shapes are the device cells S1 (iCloud, 2026-11-17, a host at `+08:00`): a zoned daily series,
/// its second occurrence retitled, then the whole series moved later the same day. The edited
/// occurrence moves with the series and keeps its `/RID=` at the old slot (N1), so the `/RID=` digits
/// read as wall-clock time can be a slot of the moved series. On the PR's `3587d72e` build the
/// whole-series undo lost that occurrence and the undo of its own delete wrote nothing; `main` restored
/// the series from its rules and wrote the one-off. Each test names its host zone; none reads the
/// process's. Everything runs through the production capture and undo arms on the in-memory store.
final class ZonedSeriesUndoOnMainTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(identifier: "UTC")!
    private var zones: [TimeZone] { [taipei, losAngeles, utc] }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// The suffix of an occurrence edited while its series had a time zone: the slot's instant (#311).
    private func zonedRID(_ slot: Date) -> String { "/RID=\(Int(slot.timeIntervalSinceReferenceDate))" }

    /// A zoned series of `slots` whose occurrence `edited` was retitled at its slot, then the whole
    /// series moved by `move`: every occurrence moves, the edited one keeps its `/RID=` at the old slot.
    /// Returns the store and its occurrences, and the moved slots.
    private func movedSeries(slots: [Date], edited: Int, move: TimeInterval) -> (FakeSeriesExceptionsStore, [FakeSeriesExceptionsStore.Event], [Date]) {
        let store = FakeSeriesExceptionsStore()
        let moved = slots.map { $0.addingTimeInterval(move) }
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: moved)
        let occurrence = occurrences[edited]
        occurrence.id = "S" + zonedRID(slots[edited])
        occurrence.external = "X-S" + zonedRID(slots[edited])
        occurrence.detached = true
        occurrence.title = "Edited"
        return (store, occurrences, moved)
    }

    private func daily(from first: Date, count: Int) -> [Date] { (0..<count).map { first.addingTimeInterval(Double($0) * day) } }

    // MARK: - S1

    /// S1 (a): the whole series deleted and the delete undone. The record's one reading is the old
    /// slot, which the moved series does not generate, so the series comes back from its rules alone
    /// with every occurrence, as on `main` (the PR's build removed the second occurrence's slot and wrote
    /// no one-off, and said one occurrence deleted on its own stayed deleted).
    // spec-example: undo-history-discard / S1
    func testS1TheWholeSeriesUndoOfAZonedSeriesMovedLaterKeepsEveryOccurrence() throws {
        for zone in zones {
            let slots = daily(from: date(2027, 3, 1, 6, in: zone), count: 6)
            let (store, occurrences, moved) = movedSeries(slots: slots, edited: 1, move: 16 * 3600)
            let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: slots[0].addingTimeInterval(-30 * day)))

            let recorded = UndoSnapshotFixtures.event(title: "Standup", weeklyOccurrences: 6, startDate: moved[0]).withExceptions(exceptions)
                .withSeriesIdentity(.init(eventIdentifier: "S", externalIdentifier: "X-S"))
            let after = FakeSeriesExceptionsStore()
            after.zone = zone
            after.seriesSlots = moved
            let (text, outcome) = try SeriesExceptionsUndo.undoDeleteEvent(recorded, calendar: recorded.calendarIdentifier, in: after)

            XCTAssertEqual(outcome, .seriesWithExceptions(.init(stayedDeleted: 0, oneOffs: 0, notApplied: true)), zone.identifier)
            XCTAssertEqual(after.starts(of: "E1"), moved, "every occurrence is back, \(zone.identifier)")
            XCTAssertTrue(text.contains("Restored from the series rules alone: the recorded exceptions did not match"), text)
        }
    }

    /// S1 (b): the retitled occurrence deleted through its own identifier and that delete undone, with
    /// the series still in place. Its one reading is the old slot, where the series has no occurrence, so
    /// the one-off is written, as on `main` (the PR's build matched the series' first moved occurrence at
    /// the wall-clock reading, wrote nothing and used the entry up).
    func testS1TheOwnDeleteOfAStaleZonedOccurrenceIsWrittenBack() throws {
        for zone in zones {
            let slots = daily(from: date(2027, 3, 1, 6, in: zone), count: 6)
            let (store, occurrences, _) = movedSeries(slots: slots, edited: 1, move: 16 * 3600)
            store.zone = zone
            let edited = occurrences[1]
            let origin = try XCTUnwrap(OccurrenceOrigin.of(eventIdentifier: edited.id, externalIdentifier: edited.external,
                                                           occurrenceDate: edited.occurrenceDate, isAllDay: false, isDetached: true, zone: zone))
            store.drop(edited)
            let record = UndoSnapshotFixtures.event(title: "Edited", startDate: edited.start).withOccurrenceOrigin(origin)

            let (_, outcome) = try SeriesExceptionsUndo.undoDeleteOccurrence(record, notCarriedOver: [], calendar: "C", in: store)

            XCTAssertEqual(outcome, .occurrenceOneOff(notCarriedOver: []), zone.identifier)
            XCTAssertEqual(store.events.filter { $0.title == "Edited" }.count, 1, zone.identifier)
        }
    }

    // MARK: - the zoned production path is main's (F8)

    /// A zoned series' stale `/RID=` after a whole-series move by 24 hours minus the host's offset, by
    /// minus the offset, by three hours, and by none, on a daily and a weekly series, the edit at the
    /// second, third or fifth occurrence: the production capture records what `main`'s capture recorded
    /// (one reading each), and the store-level restore removes, creates and answers what `main`'s did.
    func testAZonedRecordIsCapturedAndRestoredAsOnMain() throws {
        var cases = 0, notApplied = 0, applied = 0, lostAsOnMain = 0
        for zone in zones {
            let offset = TimeInterval(zone.secondsFromGMT(for: date(2027, 3, 1, 6, in: zone)))
            for move: TimeInterval in [24 * 3600 - offset, -offset, 3 * 3600, 0] {
                for step: TimeInterval in [day, 7 * day] {
                    for edited: Int in [1, 2, 4] {
                        let first = date(2027, 3, 1, 6, in: zone)
                        let slots = (0..<6).map { first.addingTimeInterval(Double($0) * step) }
                        let (store, occurrences, moved) = movedSeries(slots: slots, edited: edited, move: move)
                        let now = slots[0].addingTimeInterval(-30 * day)
                        let label = "\(zone.identifier) move \(move / 3600) h, step \(step / day) d, edited \(edited)"

                        let current = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now), label)
                        let window = current.window
                        let observed = store.events.map(store.observed)
                        let onMain = try XCTUnwrap(SeriesExceptionsPlanner.captureOnMain(observed, of: .init(eventIdentifier: "S", externalIdentifier: "X-S"),
                                                                                         windows: [window]), label)
                        XCTAssertEqual(current.keptSlots, onMain.keptSlots, label)
                        XCTAssertEqual(current.detached.map { $0.slot }, onMain.detached.map { $0.slot }, label)

                        let (answer, log, left) = restore(current, slots: moved, zone: zone, onMain: false)
                        let main = restore(onMain, slots: moved, zone: zone, onMain: true)
                        XCTAssertEqual(answer, main.answer, label)
                        XCTAssertEqual(log, main.log, label)
                        XCTAssertEqual(left, main.left, label)
                        cases += 1
                        // PR #558 round 2 (H3, H28, H44): a move by one whole period puts the stale `/RID=` on the
                        // series' first slot, its anchor: `main` applies the record there, writes no one-off and
                        // removes the edited occurrence's true slot, so the occurrence is lost (#560). It is
                        // `main`'s path (ruling A) and counted apart, not as an applied edit.
                        if answer.contains("notApplied: true") {
                            notApplied += 1
                        } else if left.contains(where: { $0.hasPrefix("Edited@") }) {
                            applied += 1
                        } else {
                            lostAsOnMain += 1
                            XCTAssertEqual(move, step, "only a move by one whole period, \(label)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 72)
        // Both outcomes are reached: a move of none applies the edit, a move off the rule applies nothing.
        XCTAssertGreaterThan(applied, 10)
        XCTAssertGreaterThan(notApplied, 10)
        // #560: the daily move by 24 hours at UTC (24 hours minus an offset of 0), the second occurrence edited:
        // its stale `/RID=` is then the moved series' first slot.
        XCTAssertEqual(lostAsOnMain, 1)
        print("ZONED cases \(cases) applied \(applied) notApplied \(notApplied) lost as on main (#560) \(lostAsOnMain)")
    }

    /// The store-level restore of `exceptions` on a store whose recreated series ("R") generates `slots`.
    private func restore(_ exceptions: SeriesExceptions, slots: [Date], zone: TimeZone, onMain: Bool) -> (answer: String, log: [String], left: [String]) {
        let store = FakeSeriesExceptionsStore()
        store.zone = zone
        let restored = FakeSeriesExceptionsStore.Event(id: "R", external: "X-R", calendar: "C", title: "Standup", start: slots[0],
                                                      occurrenceDate: slots[0], hasRules: true)
        store.add(restored)
        for slot in slots.dropFirst() {
            store.add(FakeSeriesExceptionsStore.Event(id: "R", external: "X-R", calendar: "C", title: "Standup", start: slot,
                                                      occurrenceDate: slot, hasRules: true))
        }
        let answer: String
        do {
            let outcome = onMain ? try SeriesExceptionsUndo.restoreOnMain(exceptions, of: restored, in: store)
                                 : try SeriesExceptionsUndo.restore(exceptions, of: restored, in: store)
            answer = "\(outcome)"
        } catch {
            answer = "threw \(error)"
        }
        return (answer, store.log, store.events.map { "\($0.title)@\($0.start.timeIntervalSinceReferenceDate)" })
    }
}
