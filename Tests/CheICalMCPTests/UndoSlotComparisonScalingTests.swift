import EventKit
import XCTest
@testable import CheICalMCP

/// #527: the slot comparisons of the undo paths do not grow with the square of the series. Each
/// changed function runs on a long daily series with a `ComparisonCounter` bound as the probe, which
/// the sets the function builds inside itself report to. Two numbers are asserted per function: the
/// exact count of lookups, which falls when a comparison is made by a scan beside the sets (a scan
/// does not pass through the counter), and a bound on the date comparisons far under the count a
/// scan per slot makes. No timing is asserted.
final class UndoSlotComparisonScalingTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSinceReferenceDate: 820_000_000)
    /// About seven times the slots a record can hold (two windows of 1,460 days): at this size a
    /// scan per slot makes hundreds of millions of comparisons.
    private let count = 20_000

    private func slot(_ index: Int) -> Date { t0.addingTimeInterval(Double(index) * day) }

    private func counted<T>(_ body: () throws -> T) rethrows -> (value: T, counter: ComparisonCounter) {
        let counter = ComparisonCounter()
        let value = try ComparisonCounter.$probe.withValue(counter) { try body() }
        return (value, counter)
    }

    private var window: DateInterval { DateInterval(start: slot(0).addingTimeInterval(-day / 2), end: slot(count)) }

    /// Every tenth slot (5, 15, 25, …) is not kept: half of those were edited on their own (5, 25, …),
    /// the others deleted on their own. 18,000 kept, 1,000 edited, 1,000 deleted.
    private func recorded(snapshot: EventSnapshot, windows: [DateInterval]? = nil) -> SeriesExceptions {
        let windows = windows ?? [window]
        return SeriesExceptions(
            window: windows[0], keptSlots: (0..<count).filter { $0 % 10 != 5 }.map(slot),
            detached: (0..<count).filter { $0 % 20 == 5 }.map { DetachedOccurrence(slot: slot($0), snapshot: snapshot) },
            extraWindows: Array(windows.dropFirst()))
    }

    private let edited = UndoSnapshotFixtures.event(title: "Edited")

    // MARK: - The undo of a whole-series delete

    func testTheSurplusSlotsAreFoundWithoutAScanPerSlot() {
        let exceptions = recorded(snapshot: edited)
        let generated = (0..<count).map(slot)
        let (surplus, counter) = counted { SeriesExceptionsPlanner.surplusSlots(generated: generated, exceptions: exceptions) }
        XCTAssertEqual(surplus.count, 2_000)
        XCTAssertEqual(counter.lookups, count, "one lookup per generated slot inside the window")
        XCTAssertLessThanOrEqual(counter.count, 3_000_000, "a scan of the kept slots per generated slot makes about 180 million")
        XCTAssertGreaterThan(counter.count, count)
    }

    func testTheRestorerComparesWithoutAScanPerSlot() throws {
        let exceptions = recorded(snapshot: edited)
        var generator = SeededGenerator(seed: 527_100)
        // In shuffled order, so the lookup finds each slot by its position, not by luck of the order.
        let generated = (0..<count).shuffled(using: &generator).map { (slot: slot($0), occurrence: $0) }
        var removed: [Int] = []
        var created = 0
        let (outcome, counter) = try counted {
            try SeriesExceptionsRestorer.restore(
                exceptions: exceptions, seriesStart: slot(0), generated: generated,
                remove: { removed.append($0) },
                createOneOff: { _ in created += 1; return created },
                removeOneOff: { (_: Int) in XCTFail("no cleanup") },
                rollbackSeries: { XCTFail("no rollback") })
        }
        XCTAssertEqual(outcome, SeriesExceptionsRestorer.Outcome(stayedDeleted: 1_000, oneOffs: 1_000))
        XCTAssertEqual(removed.count, 2_000)
        XCTAssertEqual(Set(removed), Set((0..<count).filter { $0 % 10 == 5 }), "each surplus slot resolved to its own occurrence")
        XCTAssertEqual(created, 1_000)
        // The series' start, the kept and the edited slots against the generated ones (19,001), each
        // generated slot against the kept ones (20,000), each surplus slot resolved (2,000) and
        // checked against the edited ones (2,000).
        XCTAssertEqual(counter.lookups, 19_001 + 20_000 + 2_000 + 2_000)
        XCTAssertLessThanOrEqual(counter.count, 6_000_000, "the scans made about 190 million for the first check alone")
        XCTAssertGreaterThan(counter.count, counter.lookups)
    }

    /// The store-level restore over two overlapping windows: every listed occurrence is offered to
    /// the growing set once per window that lists it, then the restorer runs on what was taken.
    func testTheStoreLevelRestoreTakesEachListedOccurrenceWithoutAScan() throws {
        let size = 6_000
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "R", calendar: "C", title: "Standup", slots: (0..<size).map(slot))
        let half = day / 2
        // Slots 0 ..< 4,000 and 2,000 ..< 6,000: the 2,000 in both are listed twice.
        let windows = [DateInterval(start: slot(0).addingTimeInterval(-half), end: slot(4_000).addingTimeInterval(-half)),
                       DateInterval(start: slot(2_000).addingTimeInterval(-half), end: slot(size).addingTimeInterval(-half))]
        let exceptions = SeriesExceptions(window: windows[0], keptSlots: (0..<size).filter { $0 % 10 != 5 }.map(slot), detached: [],
                                          extraWindows: [windows[1]])
        let (outcome, counter) = try counted { try SeriesExceptionsUndo.restore(exceptions, of: occurrences[0], in: store) }
        XCTAssertEqual(outcome, SeriesExceptionsRestorer.Outcome(stayedDeleted: 600, oneOffs: 0))
        XCTAssertEqual(store.starts(of: "R").count, size - 600)
        // 8,000 offers to the growing set (4,000 per window), then the restorer over the 6,000 taken:
        // 1 + 5,400 kept slots against the generated ones, 6,000 generated against the kept ones,
        // 600 surplus resolved and 600 checked against the (empty) edited ones.
        XCTAssertEqual(counter.lookups, 8_000 + 5_401 + 6_000 + 600 + 600)
        XCTAssertLessThanOrEqual(counter.count, 2_000_000, "a scan of what was taken per listed occurrence makes about 18 million")
        XCTAssertGreaterThan(counter.count, counter.lookups)
    }

    // MARK: - The undo of a whole-series update

    func testSameSlotsComparesWithoutAScanPerSlot() {
        var generator = SeededGenerator(seed: 527_101)
        let a = (0..<count).map(slot)
        let b = a.shuffled(using: &generator).map { $0.addingTimeInterval(0.5) }
        let (same, counter) = counted { SeriesUpdateUndo.sameSlots(a, b) }
        XCTAssertTrue(same)
        XCTAssertEqual(counter.lookups, count)
        XCTAssertLessThanOrEqual(counter.count, 3_000_000, "a scan of one list per slot of the other makes about 200 million")
        XCTAssertGreaterThan(counter.count, count)
    }

    func testTheDiffComparesWithoutAScanPerSlot() {
        var generator = SeededGenerator(seed: 527_102)
        let before = recorded(snapshot: edited)
        // The same occurrences listed in another order, half a second off.
        let after = SeriesExceptions(window: before.window,
                                     keptSlots: before.keptSlots.shuffled(using: &generator).map { $0.addingTimeInterval(0.5) },
                                     detached: before.detached.shuffled(using: &generator).map {
                                         DetachedOccurrence(slot: $0.slot.addingTimeInterval(-0.5), snapshot: $0.snapshot)
                                     })
        let (diff, counter) = counted { SeriesUpdateUndo.diff(recorded: before, current: after) }
        XCTAssertTrue(diff.isEmpty)
        // 19,000 recorded slots against the current ones, 19,000 current against the recorded ones,
        // then per recorded slot: the current ones again and the edited occurrence in each listing.
        XCTAssertEqual(counter.lookups, 5 * 19_000)
        XCTAssertLessThanOrEqual(counter.count, 8_000_000, "the scans made about 900 million")
        XCTAssertGreaterThan(counter.count, counter.lookups)
    }

    func testFollowOrKeepComparesWithoutAScanPerSlot() {
        var generator = SeededGenerator(seed: 527_103)
        // Every other slot edited on its own with a title of its own, kept by the update.
        let own = UndoSnapshotFixtures.event(title: "Own")
        let old = UndoSnapshotFixtures.event(title: "Old")
        let kept = (0..<count).filter { $0 % 2 == 0 }.map(slot)
        let detached = (0..<count).filter { $0 % 2 == 1 }.map { DetachedOccurrence(slot: slot($0), snapshot: own) }
        let before = SeriesExceptions(window: window, keptSlots: kept, detached: detached)
        let after = SeriesExceptions(window: window, keptSlots: kept.shuffled(using: &generator), detached: detached.shuffled(using: &generator))
        let (restorable, counter) = counted {
            SeriesUpdateUndo.occurrencesFollowOrKeep(before: before, after: after, old: old, written: ["title": "New"], fields: ["title"])
        }
        XCTAssertTrue(restorable)
        XCTAssertEqual(counter.lookups, count, "10,000 kept slots and 10,000 edited occurrences, one lookup each")
        XCTAssertLessThanOrEqual(counter.count, 3_000_000, "the scans made about 100 million")
        XCTAssertGreaterThan(counter.count, count)
    }
}
