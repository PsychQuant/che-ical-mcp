import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #527: the undo of a whole-series delete and of a whole-series update compare slots through
/// `InstantSet`, `InstantIndex` and `DistinctInstants` instead of a scan per slot. These paths guard
/// writes, so nothing they decide may change: each changed function runs here beside its copy from
/// `main` (ba98641, `UndoSlotComparisonsOnMain.swift`) over the same generated inputs, and the
/// counts at the end of each test show the inputs reach the cases that could differ.
final class UndoSlotComparisonEquivalenceTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSinceReferenceDate: 820_000_000)

    private func slot(_ index: Int) -> Date { t0.addingTimeInterval(Double(index) * day) }

    /// Offsets inside the tolerance: the slot still counts as the same instant.
    private let inside: [TimeInterval] = [0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 0.999, -0.999]
    /// Offsets on and outside it.
    private let outside: [TimeInterval] = [1, -1, 1.001, -1.001, 2, -2, 3_600]

    private func chance(_ percent: Int, _ generator: inout SeededGenerator) -> Bool {
        Int.random(in: 0..<100, using: &generator) < percent
    }

    /// 0 most of the time, else an offset inside the tolerance, else one on or outside it.
    private func jitter(inside insidePercent: Int, outside outsidePercent: Int, _ generator: inout SeededGenerator) -> TimeInterval {
        let draw = Int.random(in: 0..<100, using: &generator)
        if draw < insidePercent { return inside.randomElement(using: &generator)! }
        if draw < insidePercent + outsidePercent { return outside.randomElement(using: &generator)! }
        return 0
    }

    // MARK: - Snapshots

    private static let calendar = UndoSnapshotFixtures.newCalendar()
    private static var snapshots: [String: EventSnapshot] = [:]

    /// One snapshot per combination of values, built once: the generated cases reuse them.
    private func snapshot(title: String = "Own", notes: String? = nil, location: String? = nil, coordinates: Bool = false) -> EventSnapshot {
        let key = [title, notes ?? "<nil>", location ?? "<nil>", coordinates ? "geo" : ""].joined(separator: "\u{1}")
        if let made = Self.snapshots[key] { return made }
        let event = EKEvent(eventStore: SharedTestStore.store)
        event.calendar = Self.calendar
        event.title = title
        event.notes = notes
        event.location = location
        if coordinates {
            let place = EKStructuredLocation(title: location ?? "")
            place.geoLocation = CLLocation(latitude: 25, longitude: 121.5)
            event.structuredLocation = place
        }
        event.startDate = t0
        event.endDate = t0.addingTimeInterval(3_600)
        let made = EventSnapshot(from: event)
        Self.snapshots[key] = made
        return made
    }

    private struct Boom: Error {}

    // MARK: - The restorer (A1, A2, A3, A6)

    private struct RestorerInput {
        var exceptions: SeriesExceptions
        var seriesStart: Date
        var generated: [(slot: Date, occurrence: Int)]
        /// The call of `remove` (counted from 1) that throws.
        var failRemoveCall: Int?
        /// The call of `createOneOff` (counted from 1) that throws.
        var failCreateCall: Int?
        var writeThenThrow = false
        var failRollback = false
        var failCleanup = false
    }

    private func windows(gridSize: Int, _ generator: inout SeededGenerator) -> [DateInterval] {
        let half = day / 2
        let from = Int.random(in: 0...2, using: &generator)
        let to = Int.random(in: max(from + 1, gridSize - 3)...gridSize, using: &generator)
        var windows = [DateInterval(start: slot(from).addingTimeInterval(-half), end: slot(to).addingTimeInterval(-half))]
        if chance(30, &generator) {
            let start = Int.random(in: 0..<gridSize, using: &generator)
            let end = Int.random(in: start + 1...gridSize + 1, using: &generator)
            windows.append(DateInterval(start: slot(start).addingTimeInterval(-half), end: slot(end).addingTimeInterval(-half)))
        }
        return windows
    }

    private func restorerInput(_ generator: inout SeededGenerator) -> RestorerInput {
        let gridSize = Int.random(in: 3...14, using: &generator)
        let windows = windows(gridSize: gridSize, &generator)
        var kept: [Date] = []
        var detached: [DetachedOccurrence] = []
        var generated: [(slot: Date, occurrence: Int)] = []
        var nextOccurrence = 0
        func occurrence() -> Int { nextOccurrence += 1; return nextOccurrence }
        for index in 0..<gridSize {
            // What the record holds for this slot: kept, edited on its own, or nothing (deleted on its own).
            let draw = Int.random(in: 0..<100, using: &generator)
            if draw < 55 {
                kept.append(slot(index).addingTimeInterval(jitter(inside: 15, outside: 0, &generator)))
            } else if draw < 72 {
                detached.append(DetachedOccurrence(slot: slot(index).addingTimeInterval(jitter(inside: 15, outside: 0, &generator)),
                                                   snapshot: snapshot(title: "Edited \(index)")))
            }
            // What the recreated series generates there: nearly always the slot, to the second.
            if !chance(3, &generator) {
                generated.append((slot(index).addingTimeInterval(jitter(inside: 20, outside: 3, &generator)), occurrence()))
            }
            // A second entry within a second of it, carrying another occurrence, or the very same instant.
            if chance(14, &generator) {
                generated.append((slot(index).addingTimeInterval(inside.randomElement(using: &generator)!), occurrence()))
            }
            if chance(4, &generator), let last = generated.last {
                generated.append((last.slot, occurrence()))
            }
        }
        if chance(30, &generator) { generated.shuffle(using: &generator) }
        if chance(15, &generator) { kept.shuffle(using: &generator) }
        var seriesStart = slot(0)
        if chance(10, &generator) { seriesStart = slot(0).addingTimeInterval(inside.randomElement(using: &generator)!) }
        if chance(8, &generator) { seriesStart = chance(50, &generator) ? slot(1) : slot(0).addingTimeInterval(-3 * day) }
        var input = RestorerInput(
            exceptions: SeriesExceptions(window: windows[0], keptSlots: kept, detached: detached, extraWindows: Array(windows.dropFirst())),
            seriesStart: seriesStart, generated: generated)
        if chance(18, &generator) {
            if chance(50, &generator) {
                input.failRemoveCall = Int.random(in: 1...3, using: &generator)
            } else {
                input.failCreateCall = Int.random(in: 1...2, using: &generator)
                input.writeThenThrow = chance(50, &generator)
            }
            input.failRollback = chance(30, &generator)
            input.failCleanup = chance(30, &generator)
        }
        return input
    }

    /// One run of a restorer: what it answered or threw, and every call it made, in order, with the
    /// identity of what it removed and created.
    private func run(_ input: RestorerInput, onMain: Bool) -> (answer: String, calls: [String]) {
        var calls: [String] = []
        var removes = 0, creates = 0
        let remove: (Int) throws -> Void = { occurrence in
            removes += 1
            if removes == input.failRemoveCall { calls.append("remove \(occurrence) failed"); throw Boom() }
            calls.append("remove \(occurrence)")
        }
        let createOneOff: (DetachedOccurrence) throws -> String = { detached in
            creates += 1
            let handle = "\(detached.snapshot.title)@\(detached.slot.timeIntervalSinceReferenceDate)"
            if creates == input.failCreateCall {
                calls.append("create \(handle) failed")
                if input.writeThenThrow { throw SeriesExceptionsOneOffWriteFailed(possiblyWritten: handle, underlying: Boom()) }
                throw Boom()
            }
            calls.append("create \(handle)")
            return handle
        }
        let removeOneOff: (String) throws -> Void = { handle in
            calls.append("removeOneOff \(handle)")
            if input.failCleanup { throw Boom() }
        }
        let rollbackSeries: () throws -> Void = {
            calls.append("rollback")
            if input.failRollback { throw Boom() }
        }
        do {
            let outcome = onMain
                ? try SeriesExceptionsRestorer.restoreOnMain(
                    exceptions: input.exceptions, seriesStart: input.seriesStart, generated: input.generated,
                    remove: remove, createOneOff: createOneOff, removeOneOff: removeOneOff, rollbackSeries: rollbackSeries)
                : try SeriesExceptionsRestorer.restore(
                    exceptions: input.exceptions, seriesStart: input.seriesStart, generated: input.generated,
                    remove: remove, createOneOff: createOneOff, removeOneOff: removeOneOff, rollbackSeries: rollbackSeries)
            return ("\(outcome)", calls)
        } catch {
            return ("threw \(error)", calls)
        }
    }

    private func kind(ofRestorerAnswer answer: String) -> String {
        if answer.hasPrefix("threw ") {
            return "threw " + String(answer.dropFirst(6).prefix { $0 != "(" })
        }
        return answer.contains("notApplied: true") ? "notApplied" : "applied"
    }

    func testTheRestorerRemovesAndCreatesWhatMainDid() {
        var generator = SeededGenerator(seed: 527_001)
        var kinds: [String: Int] = [:]
        var removed = 0, created = 0, firstKept = 0, stayedDeleted = 0
        var severalCandidates = 0, firstCandidateIsNotNearest = 0
        for round in 0..<6_000 {
            let input = restorerInput(&generator)
            let failing = input.failRemoveCall != nil || input.failCreateCall != nil
            // A failed write logs its error to stderr (`failureCode`); kept off the test output.
            let (main, current) = failing
                ? withCapturedStderr { (run(input, onMain: true), run(input, onMain: false)) }.result
                : (run(input, onMain: true), run(input, onMain: false))
            XCTAssertEqual(current.answer, main.answer, "round \(round)")
            XCTAssertEqual(current.calls, main.calls, "round \(round)")
            kinds[kind(ofRestorerAnswer: main.answer), default: 0] += 1
            if main.calls.contains(where: { $0.hasPrefix("remove ") }) { removed += 1 }
            if main.calls.contains(where: { $0.hasPrefix("create ") && !$0.hasSuffix("failed") }) { created += 1 }
            if main.answer.contains("firstOccurrenceKeptFromRule: true") { firstKept += 1 }
            if !main.answer.hasPrefix("threw"), !main.answer.contains("stayedDeleted: 0") { stayedDeleted += 1 }
            // A removal resolved among several generated entries within a second of the surplus slot,
            // carrying different occurrences: where the first in the list is not the nearest, a lookup
            // that returned the nearest (or the last) match would remove another occurrence.
            guard main.calls.contains(where: { $0.hasPrefix("remove ") }) else { continue }
            let surplus = SeriesExceptionsPlanner.surplusSlotsOnMain(generated: input.generated.map(\.slot), exceptions: input.exceptions)
            var several = false, notNearest = false
            for query in surplus {
                let matches = input.generated.filter { UndoPostState.sameInstant($0.slot, query) }
                guard matches.count > 1, Set(matches.map(\.occurrence)).count > 1 else { continue }
                several = true
                let nearest = matches.min { abs($0.slot.timeIntervalSince(query)) < abs($1.slot.timeIntervalSince(query)) }!
                if nearest.occurrence != matches[0].occurrence { notNearest = true }
            }
            if several { severalCandidates += 1 }
            if notNearest { firstCandidateIsNotNearest += 1 }
        }
        // Every way the restorer can end was reached, and so were the removals a lookup decides.
        // `surplusUnresolved` is not in the list: it needs a surplus slot the lookup does not find,
        // and every surplus slot is a generated one, which the lookup finds on `main` and here
        // (`SeriesExceptionsRestorerTests` covers the branch through the executor).
        for expected in ["applied", "notApplied", "threw removeFailed", "threw oneOffFailed",
                         "threw rollbackFailed", "threw strayOneOffs", "threw oneOffMaybeLeft"] {
            XCTAssertGreaterThan(kinds[expected, default: 0], 5, "\(expected): \(kinds)")
        }
        XCTAssertEqual(kinds.values.reduce(0, +), 6_000)
        XCTAssertGreaterThan(kinds["applied", default: 0], 1_500, "\(kinds)")
        XCTAssertGreaterThan(removed, 1_500)
        XCTAssertGreaterThan(created, 800)
        XCTAssertGreaterThan(firstKept, 100)
        XCTAssertGreaterThan(stayedDeleted, 800)
        XCTAssertGreaterThan(severalCandidates, 300, "removals resolved among several entries within a second")
        XCTAssertGreaterThan(firstCandidateIsNotNearest, 60, "where the first entry in the list is not the nearest one")
    }

    func testTheSurplusSlotsAreThoseMainGave() {
        var generator = SeededGenerator(seed: 527_002)
        var nonEmpty = 0, withTolerance = 0
        for round in 0..<6_000 {
            let input = restorerInput(&generator)
            let slots = input.generated.map(\.slot)
            let main = SeriesExceptionsPlanner.surplusSlotsOnMain(generated: slots, exceptions: input.exceptions)
            XCTAssertEqual(SeriesExceptionsPlanner.surplusSlots(generated: slots, exceptions: input.exceptions), main, "round \(round)")
            if !main.isEmpty { nonEmpty += 1 }
            // A generated slot kept only through the tolerance (no kept slot is exactly equal to it).
            if slots.contains(where: { slot in
                SeriesExceptionsPlanner.inWindows(slot, input.exceptions.windows) && !main.contains(slot)
                    && !input.exceptions.keptSlots.contains(slot)
            }) { withTolerance += 1 }
        }
        XCTAssertGreaterThan(nonEmpty, 4_000)
        XCTAssertGreaterThan(withTolerance, 2_000)
    }

    // MARK: - The store-level restore (A9, then the restorer)

    private struct StoredOccurrence {
        var id: String
        var title: String
        var start: Date
        var slot: Date?
    }

    private struct StoreInput {
        var occurrences: [StoredOccurrence]
        var exceptions: SeriesExceptions
        var restoredID: String? = "R"
        var failingRemovalSlots: Set<Date> = []
        var failingSaveTitles: Set<String> = []
        var seriesRemovalFails = false
        var isStoredFails = false
        /// Two occurrences of the series within a second of each other, or the same instant twice.
        var hasNearDuplicates = false
        var windowsOverlap = false
    }

    private func storeInput(_ generator: inout SeededGenerator) -> StoreInput {
        let gridSize = Int.random(in: 3...12, using: &generator)
        let windows = windows(gridSize: gridSize, &generator)
        var kept: [Date] = []
        var detached: [DetachedOccurrence] = []
        var occurrences: [StoredOccurrence] = []
        var near = false
        var serial = 0
        func title() -> String { serial += 1; return "o\(serial)" }
        for index in 0..<gridSize {
            // A record holds only slots inside its windows (`SeriesExceptionsPlanner.capture`); one
            // outside them, which the listing never shows, is generated now and then.
            let recorded = SeriesExceptionsPlanner.inWindows(slot(index), windows) || chance(3, &generator)
            let draw = Int.random(in: 0..<100, using: &generator)
            if recorded, draw < 55 {
                kept.append(slot(index).addingTimeInterval(jitter(inside: 10, outside: 0, &generator)))
            } else if recorded, draw < 72 {
                detached.append(DetachedOccurrence(slot: slot(index), snapshot: snapshot(title: "Edited \(index)")))
            }
            // The series' own first occurrence (index 0) is the restored object itself, added below.
            if index > 0, !chance(3, &generator) {
                let at = slot(index).addingTimeInterval(jitter(inside: 15, outside: 3, &generator))
                occurrences.append(StoredOccurrence(id: "R", title: title(), start: at, slot: chance(85, &generator) ? at : nil))
            }
            // Another occurrence of the series within a second of the slot, or 0.9 s and 1.8 s after
            // it (the first and the third are then both taken), or the same instant again.
            if chance(16, &generator) {
                near = true
                let shape = Int.random(in: 0..<3, using: &generator)
                let offsets: [TimeInterval] = shape == 0 ? [inside.randomElement(using: &generator)!] : shape == 1 ? [0.9, 1.8] : [0]
                for offset in offsets {
                    let at = slot(index).addingTimeInterval(offset)
                    occurrences.append(StoredOccurrence(id: "R", title: title(), start: at, slot: at))
                }
            }
            // An occurrence of another series in the same calendar, never taken.
            if chance(20, &generator) {
                occurrences.append(StoredOccurrence(id: "T", title: title(), start: slot(index), slot: slot(index)))
            }
        }
        if chance(35, &generator) { occurrences.shuffle(using: &generator) }
        var input = StoreInput(
            occurrences: occurrences,
            exceptions: SeriesExceptions(window: windows[0], keptSlots: kept, detached: detached, extraWindows: Array(windows.dropFirst())),
            hasNearDuplicates: near,
            windowsOverlap: windows.count > 1 && windows[0].intersects(windows[1]))
        if chance(4, &generator) { input.restoredID = chance(50, &generator) ? "" : nil }
        if chance(16, &generator) {
            switch Int.random(in: 0..<3, using: &generator) {
            case 0: input.failingRemovalSlots = Set(occurrences.filter { $0.id == "R" }.compactMap(\.slot).shuffled(using: &generator).prefix(3))
            case 1: input.failingSaveTitles = Set(detached.map(\.snapshot.title).shuffled(using: &generator).prefix(1))
            default:
                input.failingSaveTitles = Set(detached.map(\.snapshot.title).shuffled(using: &generator).prefix(1))
                input.isStoredFails = true
            }
            input.seriesRemovalFails = chance(30, &generator)
        }
        return input
    }

    /// One run on a store built from `input`: the answer or the error, the store's log of every
    /// listing and write in order, and what the store holds afterwards (each event is told from
    /// every other by its title).
    private func run(_ input: StoreInput, onMain: Bool) -> (answer: String, log: [String], left: [String], refreshMarks: Int) {
        let store = FakeSeriesExceptionsStore()
        let restored = FakeSeriesExceptionsStore.Event(id: input.restoredID, external: "X-R", calendar: "C", title: "first",
                                                      start: slot(0), occurrenceDate: slot(0), hasRules: true)
        store.add(restored)
        for occurrence in input.occurrences {
            store.add(FakeSeriesExceptionsStore.Event(id: occurrence.id, external: "X-\(occurrence.id)", calendar: "C", title: occurrence.title,
                                                      start: occurrence.start, occurrenceDate: occurrence.slot, hasRules: true))
        }
        store.failingRemovalSlots = input.failingRemovalSlots
        store.failingSaveTitles = input.failingSaveTitles
        store.seriesRemovalFails = input.seriesRemovalFails
        store.isStoredFails = input.isStoredFails
        var answer: String
        do {
            let outcome = onMain ? try SeriesExceptionsUndo.restoreOnMain(input.exceptions, of: restored, in: store)
                                 : try SeriesExceptionsUndo.restore(input.exceptions, of: restored, in: store)
            answer = "\(outcome)"
        } catch {
            answer = "threw \(type(of: error)): \(error.localizedDescription)"
        }
        return (answer, store.log, store.events.map { "\($0.title)@\($0.start.timeIntervalSinceReferenceDate)" }, store.refreshMarks)
    }

    func testTheStoreLevelRestoreWritesWhatMainDid() {
        var generator = SeededGenerator(seed: 527_003)
        var applied = 0, notApplied = 0, threw = 0, removedSome = 0, nearAndRemoved = 0, overlapAndRemoved = 0, noIdentifier = 0
        for round in 0..<5_000 {
            let input = storeInput(&generator)
            let failing = !input.failingRemovalSlots.isEmpty || !input.failingSaveTitles.isEmpty
            let (main, current) = failing
                ? withCapturedStderr { (run(input, onMain: true), run(input, onMain: false)) }.result
                : (run(input, onMain: true), run(input, onMain: false))
            XCTAssertEqual(current.answer, main.answer, "round \(round)")
            XCTAssertEqual(current.log, main.log, "round \(round)")
            XCTAssertEqual(current.left, main.left, "round \(round)")
            XCTAssertEqual(current.refreshMarks, main.refreshMarks, "round \(round)")
            if main.answer.hasPrefix("threw") { threw += 1 } else if main.answer.contains("notApplied: true") { notApplied += 1 } else { applied += 1 }
            if input.restoredID != "R" { noIdentifier += 1 }
            let removes = main.log.contains { $0.hasPrefix("remove ") && $0 != "remove series" && !$0.hasPrefix("remove failed") }
            if removes { removedSome += 1 }
            if removes, input.hasNearDuplicates { nearAndRemoved += 1 }
            if removes, input.windowsOverlap { overlapAndRemoved += 1 }
        }
        XCTAssertEqual(applied + notApplied + threw, 5_000)
        XCTAssertGreaterThan(applied, 1_200, "applied \(applied), notApplied \(notApplied), threw \(threw)")
        XCTAssertGreaterThan(notApplied, 300)
        XCTAssertGreaterThan(threw, 150)
        XCTAssertGreaterThan(noIdentifier, 50)
        XCTAssertGreaterThan(removedSome, 1_200)
        XCTAssertGreaterThan(nearAndRemoved, 300, "removals with two occurrences within a second of each other in the listing")
        XCTAssertGreaterThan(overlapAndRemoved, 150, "removals with an occurrence listed by two overlapping windows")
    }

    /// The order-dependent case by hand: three occurrences 0.9 s apart are taken as the first and the
    /// third, an occurrence in the overlap of two windows once, and the removal of a surplus slot
    /// takes the first occurrence listed within a second of it.
    func testNearDuplicatesAndOverlappingWindowsAreTakenAsOnMain() {
        let half = day / 2
        let input = StoreInput(
            occurrences: [
                StoredOccurrence(id: "R", title: "a", start: slot(1), slot: slot(1)),
                StoredOccurrence(id: "R", title: "b", start: slot(1).addingTimeInterval(0.9), slot: slot(1).addingTimeInterval(0.9)),
                StoredOccurrence(id: "R", title: "c", start: slot(1).addingTimeInterval(1.8), slot: slot(1).addingTimeInterval(1.8)),
                StoredOccurrence(id: "R", title: "d", start: slot(2), slot: slot(2)),
                StoredOccurrence(id: "R", title: "e", start: slot(3).addingTimeInterval(0.4), slot: slot(3).addingTimeInterval(0.4)),
                StoredOccurrence(id: "R", title: "f", start: slot(3), slot: slot(3)),
            ],
            exceptions: SeriesExceptions(window: DateInterval(start: slot(0).addingTimeInterval(-half), end: slot(2).addingTimeInterval(half)),
                                         keptSlots: [slot(0), slot(2)], detached: [],
                                         extraWindows: [DateInterval(start: slot(1).addingTimeInterval(half), end: slot(4))]))
        let main = run(input, onMain: true)
        let current = run(input, onMain: false)
        XCTAssertEqual(current.log, main.log)
        XCTAssertEqual(current.left, main.left)
        XCTAssertEqual(current.answer, main.answer)
        func removed(_ title: String, _ offset: TimeInterval, _ index: Int) -> String {
            "remove \(slot(index).addingTimeInterval(offset).timeIntervalSince1970)"
        }
        // Two listings (one per window), then: a and c (b was within a second of a and never taken;
        // c is a second from nothing taken), and e, the first listed at slot 3 (f, 0.4 s before it, was
        // never taken). d is listed by both windows and kept.
        XCTAssertEqual(current.log, ["list", "list", removed("a", 0, 1), removed("c", 1.8, 1), removed("e", 0.4, 3)])
        XCTAssertEqual(current.left.map { String($0.prefix { $0 != "@" }) }, ["first", "b", "d", "f"])
    }

    // MARK: - The update record (A4, A5, A7, A8)

    func testSameSlotsAnswersAsMain() {
        var generator = SeededGenerator(seed: 527_004)
        var same = 0, different = 0, sameWithoutEqualLists = 0
        for round in 0..<8_000 {
            let size = Int.random(in: 0...10, using: &generator)
            var a = (0..<size).map { _ in slot(Int.random(in: 0..<8, using: &generator)).addingTimeInterval(jitter(inside: 25, outside: 0, &generator)) }
            if chance(40, &generator) { a = Array(Set(a)).sorted() }
            var b = a.map { $0.addingTimeInterval(jitter(inside: 30, outside: 4, &generator)) }
            if chance(40, &generator) { b.shuffle(using: &generator) }
            if !b.isEmpty, chance(8, &generator) { b[0] = slot(20) }
            if chance(6, &generator) { b.append(slot(1)) }
            if !b.isEmpty, chance(6, &generator) { b.removeLast() }
            let main = SeriesUpdateUndo.sameSlotsOnMain(a, b)
            XCTAssertEqual(SeriesUpdateUndo.sameSlots(a, b), main, "round \(round): \(a) \(b)")
            XCTAssertEqual(SeriesUpdateUndo.sameSlots(b, a), SeriesUpdateUndo.sameSlotsOnMain(b, a), "round \(round), reversed")
            if main { same += 1 } else { different += 1 }
            if main, a.sorted() != b.sorted() { sameWithoutEqualLists += 1 }
        }
        XCTAssertGreaterThan(same, 2_500)
        XCTAssertGreaterThan(different, 1_500)
        XCTAssertGreaterThan(sameWithoutEqualLists, 1_500, "the same slots only through the tolerance")
    }

    /// A listing of a series' exceptions around the grid, and a second one that is the first with
    /// slots moved inside or outside the tolerance, occurrences dropped, added, edited or turned from
    /// kept to edited, in another order, sometimes with two edited occurrences within a second.
    private func listings(_ generator: inout SeededGenerator) -> (recorded: SeriesExceptions, current: SeriesExceptions, twins: Bool) {
        let window = DateInterval(start: slot(0).addingTimeInterval(-day), duration: 40 * day)
        let titles = ["Own", "Other", "Third"]
        var keptA: [Date] = [], keptB: [Date] = []
        var detachedA: [DetachedOccurrence] = [], detachedB: [DetachedOccurrence] = []
        var twins = false
        for index in 0..<Int.random(in: 0...10, using: &generator) {
            let draw = Int.random(in: 0..<100, using: &generator)
            let moved = slot(index).addingTimeInterval(jitter(inside: 25, outside: 4, &generator))
            if draw < 50 {
                keptA.append(slot(index))
                if !chance(8, &generator) { keptB.append(moved) }
            } else if draw < 80 {
                let title = titles.randomElement(using: &generator)!
                detachedA.append(DetachedOccurrence(slot: slot(index), snapshot: snapshot(title: title)))
                if !chance(8, &generator) {
                    detachedB.append(DetachedOccurrence(slot: moved, snapshot: snapshot(title: chance(80, &generator) ? title : "Edited again")))
                }
                // A second edited occurrence within a second of the slot, on either side or both.
                if chance(25, &generator) {
                    twins = true
                    let twin = DetachedOccurrence(slot: slot(index).addingTimeInterval(inside.randomElement(using: &generator)!),
                                                  snapshot: snapshot(title: titles.randomElement(using: &generator)!))
                    if chance(60, &generator) { detachedB.append(twin) }
                    if chance(60, &generator) { detachedA.append(twin) }
                }
            } else if draw < 88 {
                keptA.append(slot(index))
                detachedB.append(DetachedOccurrence(slot: moved, snapshot: snapshot(title: "Own")))
            } else if draw < 94 {
                keptB.append(moved)
            }
        }
        if chance(40, &generator) { detachedB.shuffle(using: &generator) }
        if chance(40, &generator) { detachedA.shuffle(using: &generator) }
        if chance(30, &generator) { keptB.shuffle(using: &generator) }
        let other = chance(5, &generator) ? DateInterval(start: window.start, duration: 41 * day) : window
        return (SeriesExceptions(window: window, keptSlots: keptA, detached: detachedA),
                SeriesExceptions(window: other, keptSlots: keptB, detached: detachedB), twins)
    }

    func testTheDiffOfTwoListingsIsMains() {
        var generator = SeededGenerator(seed: 527_005)
        var empty = 0, deleted = 0, added = 0, edited = 0, otherWindows = 0, twinsWithEdits = 0
        for round in 0..<8_000 {
            let (recorded, current, twins) = listings(&generator)
            let main = SeriesUpdateUndo.diffOnMain(recorded: recorded, current: current)
            XCTAssertEqual(SeriesUpdateUndo.diff(recorded: recorded, current: current), main, "round \(round)")
            XCTAssertEqual(SeriesUpdateUndo.diff(recorded: current, current: recorded),
                           SeriesUpdateUndo.diffOnMain(recorded: current, current: recorded), "round \(round), reversed")
            if main.isEmpty { empty += 1 }
            if !main.deleted.isEmpty { deleted += 1 }
            if !main.added.isEmpty { added += 1 }
            if !main.edited.isEmpty { edited += 1 }
            if main.otherWindows { otherWindows += 1 }
            if twins, !main.edited.isEmpty { twinsWithEdits += 1 }
        }
        XCTAssertGreaterThan(empty, 400)
        XCTAssertGreaterThan(deleted, 1_500)
        XCTAssertGreaterThan(added, 1_500)
        XCTAssertGreaterThan(edited, 1_500)
        XCTAssertGreaterThan(otherWindows, 200)
        XCTAssertGreaterThan(twinsWithEdits, 800, "edits found with two edited occurrences within a second of one slot")
    }

    /// Two edited occurrences within a second of one slot, with different fields: the one compared
    /// is the first in its list, on both sides.
    func testTheDiffTakesTheFirstEditedOccurrenceInEachList() {
        let window = DateInterval(start: slot(0).addingTimeInterval(-day), duration: 40 * day)
        func listing(_ detached: [(TimeInterval, String)]) -> SeriesExceptions {
            SeriesExceptions(window: window, keptSlots: [], detached: detached.map {
                DetachedOccurrence(slot: slot(3).addingTimeInterval($0.0), snapshot: snapshot(title: $0.1))
            })
        }
        let recorded = listing([(0, "Own")])
        // The first in the current list has the recorded title: nothing edited. The other order: edited.
        XCTAssertTrue(SeriesUpdateUndo.diff(recorded: recorded, current: listing([(0.6, "Own"), (-0.3, "Other")])).isEmpty)
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: recorded, current: listing([(-0.3, "Other"), (0.6, "Own")])).edited, [slot(3)])
        // The nearest is not the first: 0.1 s away with another title, listed second.
        XCTAssertTrue(SeriesUpdateUndo.diff(recorded: recorded, current: listing([(0.9, "Own"), (0.1, "Other")])).isEmpty)
        for current in [listing([(0.6, "Own"), (-0.3, "Other")]), listing([(-0.3, "Other"), (0.6, "Own")]), listing([(0.9, "Own"), (0.1, "Other")])] {
            XCTAssertEqual(SeriesUpdateUndo.diff(recorded: recorded, current: current), SeriesUpdateUndo.diffOnMain(recorded: recorded, current: current))
            XCTAssertEqual(SeriesUpdateUndo.diff(recorded: current, current: recorded), SeriesUpdateUndo.diffOnMain(recorded: current, current: recorded))
        }
    }

    private func exceptions(kept: [Int] = [], edited: [(Int, String)]) -> SeriesExceptions {
        SeriesExceptions(window: DateInterval(start: slot(0).addingTimeInterval(-day), duration: 40 * day),
                         keptSlots: kept.map { slot($0) },
                         detached: edited.map { DetachedOccurrence(slot: slot($0.0), snapshot: snapshot(title: $0.1)) })
    }

    /// Each side's edited occurrence at a slot is looked up in that side's own list. The two lists
    /// hold as many entries in every case here, so a lookup through the other list's positions
    /// stays inside the list and reads another entry, or finds none.
    func testTheDiffLooksEachEditedOccurrenceUpInItsOwnList() {
        // The same two edited occurrences, listed in the other order: nothing differs.
        let ordered = exceptions(edited: [(3, "Own"), (5, "Other")])
        let reordered = exceptions(edited: [(5, "Other"), (3, "Own")])
        XCTAssertTrue(SeriesUpdateUndo.diff(recorded: ordered, current: reordered).isEmpty)
        XCTAssertTrue(SeriesUpdateUndo.diff(recorded: reordered, current: ordered).isEmpty)
        // One of them edited again, in the other order: that slot only.
        let editedAgain = exceptions(edited: [(5, "Edited again"), (3, "Own")])
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: ordered, current: editedAgain).edited, [slot(5)])
        // A plain occurrence that is edited on its own now, beside one that was edited and is plain
        // now: both slots, and neither is deleted or added.
        let before = exceptions(kept: [3], edited: [(5, "Own")])
        let after = exceptions(kept: [5], edited: [(3, "Own")])
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: before, current: after),
                       SeriesUpdateUndo.ExceptionsDiff(deleted: [], added: [], edited: [slot(3), slot(5)]))
        for (recorded, current) in [(ordered, reordered), (ordered, editedAgain), (before, after)] {
            XCTAssertEqual(SeriesUpdateUndo.diff(recorded: recorded, current: current), SeriesUpdateUndo.diffOnMain(recorded: recorded, current: current))
            XCTAssertEqual(SeriesUpdateUndo.diff(recorded: current, current: recorded), SeriesUpdateUndo.diffOnMain(recorded: current, current: recorded))
        }
    }

    /// The lists of edited occurrences hold different numbers of entries: an occurrence edited on
    /// its own where none was recorded, and the reverse.
    func testTheDiffOfListsOfDifferentLengths() {
        let plain = exceptions(kept: [3], edited: [])
        let edited = exceptions(edited: [(3, "Own")])
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: plain, current: edited),
                       SeriesUpdateUndo.ExceptionsDiff(deleted: [], added: [], edited: [slot(3)]))
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: edited, current: plain),
                       SeriesUpdateUndo.ExceptionsDiff(deleted: [], added: [], edited: [slot(3)]))
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: plain, current: edited), SeriesUpdateUndo.diffOnMain(recorded: plain, current: edited))
        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: edited, current: plain), SeriesUpdateUndo.diffOnMain(recorded: edited, current: plain))
    }

    func testOccurrencesFollowOrKeepAnswersAsMain() {
        var generator = SeededGenerator(seed: 527_006)
        let window = DateInterval(start: slot(0).addingTimeInterval(-day), duration: 40 * day)
        var restorable = 0, marker = 0, restorableWithEdited = 0, severalCandidates = 0, severalWithDifferentAnswers = 0
        for round in 0..<8_000 {
            let fields = SeriesUpdateUndo.restorableOrder.filter { _ in chance(50, &generator) }
            let written = Dictionary(uniqueKeysWithValues: (fields.isEmpty ? ["notes"] : fields).map { ($0, "New") })
            let old = snapshot(title: "Old", notes: "Old", location: "Old")
            func values(_ kind: Int, after: Bool) -> EventSnapshot {
                // 0 follows (the old values, then the written ones), 1 keeps its own, 2 had the old
                // values and did not take the new ones, 3 changes a field the write did not touch.
                func value(_ field: String) -> String {
                    let touched = written[field] != nil
                    switch kind {
                    case 0: return touched && after ? "New" : "Old"
                    case 1: return "Own"
                    case 2: return "Old"
                    default: return after && !touched ? "Drift" : (touched && after ? "New" : "Old")
                    }
                }
                return snapshot(title: value("title"), notes: value("notes"), location: value("location"),
                                coordinates: kind == 1 && written["location"] != nil && chance(4, &generator))
            }
            var keptBefore: [Date] = [], keptAfter: [Date] = []
            var before: [DetachedOccurrence] = [], after: [DetachedOccurrence] = []
            for index in 0..<Int.random(in: 0...9, using: &generator) {
                let moved = slot(index).addingTimeInterval(jitter(inside: 25, outside: 2, &generator))
                if chance(55, &generator) {
                    keptBefore.append(slot(index))
                    if !chance(3, &generator) { keptAfter.append(moved) }
                    continue
                }
                let draw = Int.random(in: 0..<100, using: &generator)
                let kind = draw < 45 ? 0 : draw < 88 ? 1 : draw < 94 ? 2 : 3
                before.append(DetachedOccurrence(slot: slot(index), snapshot: values(kind, after: false)))
                if !chance(3, &generator) { after.append(DetachedOccurrence(slot: moved, snapshot: values(kind, after: true))) }
                // A twin within a second of the slot on both sides, of another kind: which of the two
                // after-entries each before-entry is compared with decides the answer.
                if chance(22, &generator) {
                    let twinKind = Int.random(in: 0...2, using: &generator)
                    let offset = inside.randomElement(using: &generator)!
                    before.append(DetachedOccurrence(slot: slot(index).addingTimeInterval(offset), snapshot: values(twinKind, after: false)))
                    after.append(DetachedOccurrence(slot: slot(index).addingTimeInterval(offset), snapshot: values(twinKind, after: true)))
                }
            }
            if chance(40, &generator) { after.shuffle(using: &generator) }
            if chance(30, &generator) { keptAfter.shuffle(using: &generator) }
            let listedBefore = SeriesExceptions(window: window, keptSlots: keptBefore, detached: before)
            let listedAfter = SeriesExceptions(window: window, keptSlots: keptAfter, detached: after)
            let callFields = fields.isEmpty && chance(50, &generator) ? ["title"] : Array(written.keys).sorted {
                SeriesUpdateUndo.restorableOrder.firstIndex(of: $0)! < SeriesUpdateUndo.restorableOrder.firstIndex(of: $1)!
            }
            let main = SeriesUpdateUndo.occurrencesFollowOrKeepOnMain(before: listedBefore, after: listedAfter, old: old, written: written, fields: callFields)
            XCTAssertEqual(SeriesUpdateUndo.occurrencesFollowOrKeep(before: listedBefore, after: listedAfter, old: old, written: written, fields: callFields),
                           main, "round \(round)")
            if main { restorable += 1 } else { marker += 1 }
            if main, !before.isEmpty { restorableWithEdited += 1 }
            // A before-entry with several after-entries within a second of it; and among those, cases
            // where taking another of them than the first would give another answer for that entry.
            var several = false, differ = false
            for was in before {
                let candidates = after.filter { UndoPostState.sameInstant($0.slot, was.slot) }
                guard candidates.count > 1 else { continue }
                several = true
                let titles = Set(candidates.map { "\($0.snapshot.title)|\($0.snapshot.notes ?? "")|\($0.snapshot.location ?? "")" })
                if titles.count > 1 { differ = true }
            }
            if several { severalCandidates += 1 }
            if differ { severalWithDifferentAnswers += 1 }
        }
        XCTAssertGreaterThan(restorable, 2_000, "restorable \(restorable), marker \(marker)")
        XCTAssertGreaterThan(marker, 2_000)
        XCTAssertGreaterThan(restorableWithEdited, 600, "restorable with occurrences edited on their own")
        XCTAssertGreaterThan(severalCandidates, 1_500)
        XCTAssertGreaterThan(severalWithDifferentAnswers, 800, "several candidates with different fields: the first in the list decides")
    }

    /// The first after-entry within a second of a before-entry is the one compared, also when a
    /// nearer one with other fields follows it in the list.
    func testFollowOrKeepComparesWithTheFirstEntryInTheList() {
        let window = DateInterval(start: slot(0).addingTimeInterval(-day), duration: 40 * day)
        let old = snapshot(title: "Old", notes: "Old", location: "Old")
        let was = [DetachedOccurrence(slot: slot(2), snapshot: snapshot(title: "Old", notes: "Old", location: "Old")),
                   DetachedOccurrence(slot: slot(2).addingTimeInterval(0.5), snapshot: snapshot(title: "Old", notes: "Old", location: "Old"))]
        let followed = DetachedOccurrence(slot: slot(2).addingTimeInterval(0.9), snapshot: snapshot(title: "Old", notes: "New", location: "Old"))
        let stayed = DetachedOccurrence(slot: slot(2).addingTimeInterval(0.1), snapshot: snapshot(title: "Old", notes: "Old", location: "Old"))
        func answer(_ after: [DetachedOccurrence], onMain: Bool) -> Bool {
            let before = SeriesExceptions(window: window, keptSlots: [], detached: was)
            let listed = SeriesExceptions(window: window, keptSlots: [], detached: after)
            return onMain
                ? SeriesUpdateUndo.occurrencesFollowOrKeepOnMain(before: before, after: listed, old: old, written: ["notes": "New"], fields: ["notes"])
                : SeriesUpdateUndo.occurrencesFollowOrKeep(before: before, after: listed, old: old, written: ["notes": "New"], fields: ["notes"])
        }
        XCTAssertTrue(answer([followed, stayed], onMain: false), "both before-entries are compared with the first after-entry, which followed")
        XCTAssertFalse(answer([stayed, followed], onMain: false), "the first after-entry did not take the new notes")
        XCTAssertEqual(answer([followed, stayed], onMain: false), answer([followed, stayed], onMain: true))
        XCTAssertEqual(answer([stayed, followed], onMain: false), answer([stayed, followed], onMain: true))
    }
}
