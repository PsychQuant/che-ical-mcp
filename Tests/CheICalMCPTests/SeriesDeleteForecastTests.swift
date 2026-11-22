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
            let slots = weekly(from: date(2027, 1, 11, 10, in: zone), count: 6, in: zone)
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
            let slots = weekly(from: date(2027, 1, 11, 9, in: zone), count: 6, in: zone)
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

    /// The forecast abstains at a daylight-saving gap with either source of the recorded slot.
    func testForecastAbstainsAcrossTheDSTGapWithOrWithoutARID() throws {
        let calendar = Calendar.gregorian(in: losAngeles)
        let first = date(2027, 2, 28, 2, 30, in: losAngeles)
        let shifted = date(2027, 3, 14, 3, 30, in: losAngeles)
        let slots = [first, date(2027, 3, 7, 2, 30, in: losAngeles), shifted, date(2027, 3, 21, 2, 30, in: losAngeles)]
        for hasRID in [true, false] {
            let exceptions = try captured(slots, zone: losAngeles) { occurrences in
                let edited = occurrences[2]
                if hasRID {
                    self.edit(edited, rid: floatingRID(DateComponents(year: 2027, month: 3, day: 14, hour: 2, minute: 30)),
                         title: "Edited on the change")
                } else {
                    edited.detached = true
                }
            }
            XCTAssertEqual(exceptions.detached.count, 1)
            XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 4)],
                                                              firstSlot: first, calendar: calendar))
        }
    }

    func testForecastAbstainsWhenOnlyTheEditedDSTSlotDiffersFromTheRecreatedListing() throws {
        let first = date(2027, 3, 7, 2, 30, in: losAngeles)
        // Independent store inputs. The provider puts the March 14 occurrence at 03:00.
        let shifted = date(2027, 3, 14, 3, in: losAngeles)
        let last = date(2027, 3, 21, 2, 30, in: losAngeles)
        let exceptions = try captured([first, shifted, last], zone: losAngeles) { occurrences in
            edit(occurrences[1], rid: zonedRID(shifted), title: "Edited on the transition")
        }
        let restored = try SeriesExceptionsRestorer.restore(
            exceptions: exceptions, seriesStart: first, generated: [first, shifted, last].map { ($0, $0) },
            remove: { _ in }, createOneOff: { _ in () }, removeOneOff: { _ in }, rollbackSeries: {})
        XCTAssertFalse(restored.notApplied)
        XCTAssertEqual(restored.oneOffs, 1)
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(count: 3)],
                                                          firstSlot: first, calendar: .gregorian(in: losAngeles)))
    }

    func testForecastAbstainsForALoneEditAtEitherWindowEdge() {
        let first = date(2027, 2, 1, 10, in: utc)
        let window = DateInterval(start: first.addingTimeInterval(day + 10_800), end: first.addingTimeInterval(4 * day + 10_800))
        for slot in [window.start, window.end.addingTimeInterval(-0.5)] {
            let edit = DetachedOccurrence(slot: slot, snapshot: UndoSnapshotFixtures.event(startDate: slot))
            let exceptions = SeriesExceptions(window: window, keptSlots: [], detached: [edit])
            XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)],
                                                              firstSlot: first, calendar: .gregorian(in: utc)))
        }
    }

    func testForecastAbstainsWhenAProjectedOccurrenceTouchesAWindowBoundary() {
        let first = date(2027, 2, 1, 10, in: utc)
        let middle = first.addingTimeInterval(3 * day)
        let edit = DetachedOccurrence(slot: middle.addingTimeInterval(3600),
                                      snapshot: UndoSnapshotFixtures.event(startDate: middle))
        let windows = [
            DateInterval(start: first.addingTimeInterval(day), end: first.addingTimeInterval(5 * day + 1800)),
            DateInterval(start: first.addingTimeInterval(day + 1800), end: first.addingTimeInterval(5 * day + 0.5)),
            DateInterval(start: first.addingTimeInterval(day + 3600), end: first.addingTimeInterval(5 * day + 1800))
        ]
        for window in windows {
            let exceptions = SeriesExceptions(window: window, keptSlots: [middle], detached: [edit])
            XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)],
                                                              firstSlot: first, calendar: .gregorian(in: utc)))
        }
    }

    func testAnOpenDailyRuleForecastsThroughTheRealDeleteWindow() throws {
        let first = date(2027, 2, 1, 10, in: utc)
        let store = FakeSeriesExceptionsStore()
        store.seriesEnd = .open
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Daily",
                                          slots: (0...3).map { first.addingTimeInterval(Double($0) * day) })
        edit(occurrences[1], rid: zonedRID(occurrences[1].start.addingTimeInterval(3600)), title: "Off the rule")
        let exceptions = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: first))
        XCTAssertEqual(exceptions.window.end, first.addingTimeInterval(1459 * day))
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)],
                                                              firstSlot: first, calendar: .gregorian(in: utc)), 1)
    }

    func testForecastAbstainsOnTheLocalRuleEndDayWhenTheRuleCouldHaveASlot() {
        let first = date(2027, 2, 1, 10, in: taipei)
        let last = first.addingTimeInterval(14 * day)
        let offRule = last.addingTimeInterval(3600)
        let edit = DetachedOccurrence(slot: offRule, snapshot: UndoSnapshotFixtures.event(startDate: offRule))
        let window = DateInterval(start: first.addingTimeInterval(-day), end: last.addingTimeInterval(2 * day))
        let exceptions = SeriesExceptions(window: window, keptSlots: [first], detached: [edit])
        for end in [last.addingTimeInterval(-3600), last, last.addingTimeInterval(3600)] {
            XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(end: end)],
                                                              firstSlot: first, calendar: .gregorian(in: taipei)))
        }
        let sameDayEnd = last.addingTimeInterval(7200)
        let endingWindow = DateInterval(start: window.start, end: sameDayEnd)
        let endingExceptions = SeriesExceptions(window: endingWindow, keptSlots: [first], detached: [edit])
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(endingExceptions, rules: [rule(end: sameDayEnd)],
                                                          firstSlot: first, calendar: .gregorian(in: taipei)))
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(end: last.addingTimeInterval(day))],
                                                              firstSlot: first, calendar: .gregorian(in: taipei)), 1)
    }

    func testForecastAbstainsOutsideTheSupportedRecurrenceOrDuration() {
        let first = date(2027, 2, 1, 10, in: utc)
        let slot = first.addingTimeInterval(5 * day + 3600)
        let edit = DetachedOccurrence(slot: slot, snapshot: UndoSnapshotFixtures.event(startDate: slot))
        let window = DateInterval(start: first.addingTimeInterval(-day), end: first.addingTimeInterval(7 * day + 1800))
        let exceptions = SeriesExceptions(window: window, keptSlots: [first], detached: [edit])
        let calendar = Calendar.gregorian(in: utc)
        XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)],
                                                            firstSlot: first, calendar: calendar), 1)
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.monthly)],
                                                          firstSlot: first, calendar: calendar))
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)],
                                                          firstSlot: first, calendar: calendar, duration: 0))
    }

    func testForecastChecksTheExactExpansionCapAndAdjacentCounts() {
        let first = date(2027, 2, 1, 10, in: utc)
        let window = DateInterval(start: first.addingTimeInterval(-day), duration: 20_003 * day)
        let edit = DetachedOccurrence(slot: first.addingTimeInterval(day + 3600),
                                      snapshot: UndoSnapshotFixtures.event(startDate: first))
        let exceptions = SeriesExceptions(window: window, keptSlots: [first], detached: [edit])
        for count in [19_999, 20_000, 20_001] {
            XCTAssertEqual(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily, count: count)],
                                                                firstSlot: first, calendar: .gregorian(in: utc)),
                           count > 20_000 ? nil : 1, "count \(count)")
        }
    }

    func testPreviewSkipsListingsForKnownAbstentions() {
        let first = date(2027, 2, 28, 2, 30, in: losAngeles)
        let shapes: [(EKRecurrenceFrequency, TimeZone, Date)] = [
            (.monthly, utc, first),
            (.weekly, losAngeles, first),
            (.weekly, utc, first.addingTimeInterval(5000 * day + 1800))
        ]
        for (frequency, zone, now) in shapes {
            let store = FakeSeriesExceptionsStore()
            store.seriesEnd = .open
            let series = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: [first])[0]
            let snapshot = UndoSnapshotFixtures.event(startDate: first,
                recurrence: EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil))
            let anchor = SeriesDeleteAnchor(start: first, occurrenceDate: first, isAllDay: false, zone: zone)
            store.observeForForecast = anchor.observe
            let result = anchor.preview(of: series, in: store, snapshot: snapshot, remainingListings: 16, now: now)
            XCTAssertEqual(result.listings, 0, "\(frequency) \(zone) \(now)")
            XCTAssertNil(result.note)
            XCTAssertEqual(store.log, [])
        }
    }

    func testPreviewChargesActualListingsForBothCaptureWindows() throws {
        let first = date(2027, 2, 1, 10, in: utc)
        let slots = weekly(from: first, count: 6)
        let now = first.addingTimeInterval(5000 * day + 1800)
        let store = FakeSeriesExceptionsStore()
        store.seriesEnd = .endsBy(first.addingTimeInterval(7000 * day))
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        edit(occurrences[1], rid: zonedRID(slots[1].addingTimeInterval(3600)), title: "Off the rule")
        let series = occurrences[0]
        let baseline = try XCTUnwrap(SeriesUndoOnMain.capture(of: series, in: store, now: now))
        XCTAssertEqual(baseline.windows.count, 2)
        XCTAssertEqual(store.log, Array(repeating: "list", count: 4))

        let snapshot = UndoSnapshotFixtures.event(weeklyOccurrences: 1000, startDate: first)
        let anchor = SeriesDeleteAnchor(start: first, occurrenceDate: first, isAllDay: false, zone: utc)
        store.observeForForecast = anchor.observe
        let denied = anchor.preview(of: series, in: store, snapshot: snapshot, remainingListings: 3, now: now)
        XCTAssertEqual(denied.listings, 0)
        XCTAssertNil(denied.note)
        XCTAssertEqual(store.log.count, 4, "no partial capture")
        let admitted = anchor.preview(of: series, in: store, snapshot: snapshot, remainingListings: 4, now: now)
        XCTAssertEqual(admitted.listings, 4)
        XCTAssertEqual(admitted.note, edits(1))
        XCTAssertEqual(store.log.count, 8, "exactly four additional store queries")

        let realAnchor = SeriesDeleteAnchor(start: first, occurrenceDate: first, isAllDay: false, zone: utc)
        store.observeForForecast = realAnchor.observe
        let live = try XCTUnwrap(SeriesExceptionsUndo.capture(of: series, in: store, now: now))
        XCTAssertEqual(live.windows, baseline.windows)
        XCTAssertEqual(live.keptSlots, baseline.keptSlots)
        XCTAssertEqual(live.detached.map(\.slot), baseline.detached.map(\.slot))
        XCTAssertEqual(realAnchor.forecast(for: snapshot.withExceptions(live)), edits(1))
        XCTAssertEqual(store.log.count - 8, 4, "the real delete adds no queries to main's four")

        let before = store.log.count
        // Main's ordinary span-all preview reaches this guard. Its neighbours query is lazy.
        func listNeighbours() -> DetachedOccurrenceSpan.Neighbours? {
            _ = store.events(in: baseline.window, inCalendarOf: series)
            return nil
        }
        for index in 0..<5 {
            XCTAssertNil(DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: "S\(index)", isDetached: false,
                                                                    batch: true, neighbours: listNeighbours()))
        }
        XCTAssertEqual(store.log.count - before, 0, "the ordinary preview does not query the calendar")
        var context = BatchDeletionForecastContext()
        for index in 0..<5 {
            let identity = BatchForecastIdentity(requested: "S\(index)", resolved: "S\(index)", external: nil)
            let forecast = context.read(identity) { remaining in
                let rowAnchor = SeriesDeleteAnchor(start: first, occurrenceDate: first, isAllDay: false, zone: utc)
                store.observeForForecast = rowAnchor.observe
                return rowAnchor.preview(of: series, in: store, snapshot: snapshot, remainingListings: remaining, now: now)
            }
            XCTAssertEqual(forecast.listings, index < 4 ? 4 : 0)
            context.record(identity, listings: forecast.listings)
        }
        XCTAssertEqual(store.log.count - before, 16, "four complete captures, with no fifth capture")

    }

    func testExpansionCapAlsoCoversHistoryOutsideANarrowWindow() {
        let first = date(1964, 2, 1, 10, in: utc)
        let nearEnd = first.addingTimeInterval(20_015 * day)
        let window = DateInterval(start: nearEnd.addingTimeInterval(-1.5 * day), duration: 3 * day)
        let edit = DetachedOccurrence(slot: nearEnd.addingTimeInterval(3600),
                                      snapshot: UndoSnapshotFixtures.event(startDate: nearEnd))
        let exceptions = SeriesExceptions(window: window, keptSlots: [nearEnd], detached: [edit])
        XCTAssertNil(SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: [rule(.daily)], firstSlot: first,
                                                          calendar: .gregorian(in: utc)))
    }

    // MARK: - RulesAloneForecast

    private func wholeSeries(_ title: String = "Standup") -> UndoOperation {
        .deleteEvent(id: "S", snapshot: UndoSnapshotFixtures.event(title: title, weeklyOccurrences: 6, startDate: Date(timeIntervalSinceReferenceDate: 0)))
    }

    private func edits(_ count: Int) -> RulesAloneOnUndo { RulesAloneOnUndo(edits: count) }

    private func candidate(edits count: Int, identifier: String) -> (UndoOperation, SeriesDeleteAnchor) {
        let first = date(2027, 1, 11, 10, in: utc)
        let slots = weekly(from: first, count: 6)
        let store = FakeSeriesExceptionsStore()
        let rows = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        for index in 0..<count {
            self.edit(rows[index + 1], rid: zonedRID(slots[index + 1].addingTimeInterval(3600)), title: "Off the rule")
        }
        let anchor = SeriesDeleteAnchor(start: first, occurrenceDate: first, isAllDay: false, zone: utc)
        store.observeForForecast = anchor.observe
        let capture = SeriesExceptionsUndo.capture(of: rows[0], in: store, now: first)
        let snapshot = UndoSnapshotFixtures.event(weeklyOccurrences: 6, startDate: first).withExceptions(capture)
        return (.deleteEvent(id: identifier, snapshot: snapshot), anchor)
    }

    /// Only a whole-series record with a forecast forecasts, in the order the rows were recorded.
    func testOnlyAWholeSeriesRecordWithUnplacedEditsForecasts() {
        var forecast = RulesAloneForecast()
        let (a, anchorA) = candidate(edits: 2, identifier: "A")
        let (b, anchorB) = candidate(edits: 0, identifier: "B")
        let (d, anchorD) = candidate(edits: 1, identifier: "D")
        forecast.recorded(a, identifier: "A", anchor: anchorA)
        forecast.recorded(b, identifier: "B", anchor: anchorB)
        forecast.recorded(.deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: []),
                          identifier: "C", anchor: anchorA)
        forecast.recorded(d, identifier: "D", anchor: anchorD)
        XCTAssertEqual(forecast.expected, [.init(identifier: "A", forecast: edits(2)), .init(identifier: "D", forecast: edits(1))])
    }

    func testARecordThatRefusesTheCallsUndoClearsEveryForecast() {
        var forecast = RulesAloneForecast()
        let (a, anchorA) = candidate(edits: 2, identifier: "A")
        let (c, anchorC) = candidate(edits: 1, identifier: "C")
        forecast.recorded(a, identifier: "A", anchor: anchorA)
        XCTAssertFalse(forecast.isSuppressed)
        forecast.recorded(.deleteFollowingOccurrences(title: "Standup"), identifier: "B", anchor: nil)
        XCTAssertTrue(forecast.isSuppressed)
        forecast.recorded(c, identifier: "C", anchor: anchorC)
        XCTAssertEqual(forecast.expected, [])
    }

    /// `delete_event`: the forecast of the one record it made, nil unless that record is a whole-series delete.
    func testASingleDeleteForecastsOnlyForAWholeSeriesRecord() {
        XCTAssertEqual(RulesAloneForecast.expected(of: wholeSeries(), unplacedEdits: { edits(2) }), edits(2))
        let notWhole: [UndoOperation] = [
            .deleteFollowingOccurrences(title: "Standup"),
            .deleteOccurrence(snapshot: UndoSnapshotFixtures.event(), notCarriedOver: [])
        ]
        for record in notWhole {
            XCTAssertNil(RulesAloneForecast.expected(of: record) {
                XCTFail("an ineligible delete must not compute a forecast")
                return self.edits(2)
            })
        }
    }

    func testTheForecastUsesTheSameThreeReadsAsTheRecordedCapture() throws {
        let slots = weekly(from: date(2027, 2, 11, 10, in: taipei), count: 6)
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Standup", slots: slots)
        edit(occurrences[2], rid: zonedRID(slots[2].addingTimeInterval(3600)), title: "Off the rule")
        let now = slots[0].addingTimeInterval(-30 * day)
        let before = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now))
        XCTAssertEqual(store.log, Array(repeating: "list", count: 3))
        // The previous baseline lookup listed its own three ranges after the capture.
        let baselineWindow = UndoPostState.seriesScanWindow(firstStart: slots[0], ruleEnd: nil)
        for range in SeriesExceptionsPlanner.listingRanges(for: baselineWindow) {
            _ = store.events(in: range, inCalendarOf: occurrences[0])
        }
        let previousReadCount = store.log.count
        XCTAssertEqual(previousReadCount, 6)

        let anchor = SeriesDeleteAnchor(start: slots[0], occurrenceDate: slots[0], isAllDay: false, zone: taipei)
        store.observeForForecast = anchor.observe
        let after = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: now))
        XCTAssertEqual(before.windows, after.windows)
        XCTAssertEqual(before.keptSlots, after.keptSlots)
        XCTAssertEqual(before.detached.map(\.slot), after.detached.map(\.slot))

        let snapshot = UndoSnapshotFixtures.event(weeklyOccurrences: 6, startDate: slots[0])
            .withExceptions(after)
        XCTAssertEqual(anchor.forecast(for: snapshot), edits(1))
        XCTAssertEqual(store.log.count - previousReadCount, 3, "no baseline listing after the second capture")
        let unproven = SeriesDeleteAnchor(start: slots[0], occurrenceDate: slots[0], isAllDay: false, zone: taipei)
        XCTAssertNil(unproven.forecast(for: snapshot), "the first slot must have been observed")
    }

    // MARK: - Texts

    /// The text, word for word (PR #558 fix round 4: one cause, the restore's check; L7: the count is of the
    /// recorded edits; fix round 5, Q9: only what that check establishes).
    func testTheNotesSayTheForecastWithItsCount() {
        XCTAssertEqual(CheICalMCPServer.rulesAloneUndoNote(edits(2)),
                       "Undo is expected to bring this series back from its rules alone: 2 recorded occurrence(s) edited on their own have an original time, as recorded from a readable RID or otherwise the occurrence date or start, that is absent from the predicted restore listings. The forecast is computed from the recurrence rule, and the store may list different slots at undo. If those slots are absent, undo applies none of the recorded exceptions.")
        XCTAssertEqual(CheICalMCPServer.batchPreviewRulesAloneNote(edits(1)),
                       "Undo of this row would be expected to bring the series back from its rules alone: 1 recorded occurrence(s) edited on their own have an original time, as recorded from a readable RID or otherwise the occurrence date or start, that is absent from the predicted restore listings. The forecast is computed from the recurrence rule, and the store may list different slots at undo. If those slots are absent, undo applies none of the recorded exceptions.")
    }
}
