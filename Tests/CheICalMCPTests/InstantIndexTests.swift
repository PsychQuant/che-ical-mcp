import XCTest
@testable import CheICalMCP

/// #527: `InstantIndex.firstPosition` must answer exactly what the scan it replaces answered,
/// `list.firstIndex { UndoPostState.sameInstant($0, query) }`: the same element, also when several
/// are within a second of the query. `DistinctInstants.insert` must decide exactly what
/// `if !kept.contains(where: { UndoPostState.sameInstant($0, instant) }) { kept.append(instant) }` decided.
final class InstantIndexTests: XCTestCase {
    /// The lookup the undo paths did on `main` (ba98641), element first, query second.
    private func scan(_ list: [Date], _ query: Date) -> Int? {
        list.firstIndex { UndoPostState.sameInstant($0, query) }
    }

    /// The de-duplication `SeriesExceptionsUndo.restore` did on `main`: the positions kept.
    private func scanKept(_ list: [Date]) -> [Int] {
        var kept: [(slot: Date, position: Int)] = []
        for (position, slot) in list.enumerated() {
            if !kept.contains(where: { UndoPostState.sameInstant($0.slot, slot) }) { kept.append((slot, position)) }
        }
        return kept.map(\.position)
    }

    private func taken(_ list: [Date], counter: ComparisonCounter? = nil) -> [Int] {
        var distinct = DistinctInstants(counter: counter)
        var kept: [Int] = []
        for (position, slot) in list.enumerated() where distinct.insert(slot) { kept.append(position) }
        return kept
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    private func assertSame(_ list: [Double], _ queries: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let dates = list.map(date)
        let index = InstantIndex(dates)
        for query in queries {
            XCTAssertEqual(index.firstPosition(sameInstantAs: date(query)), scan(dates, date(query)),
                           "list \(list), query \(query)", file: file, line: line)
        }
        XCTAssertEqual(taken(dates), scanKept(dates), "list \(list)", file: file, line: line)
    }

    // MARK: - The lookup

    func testAnEmptyListHasNoPosition() {
        XCTAssertNil(InstantIndex([]).firstPosition(sameInstantAs: date(0)))
        XCTAssertNil(InstantIndex([]).firstPosition(sameInstantAs: date(.nan)))
        assertSame([], [0, 1, -1, 7e8])
    }

    /// Strictly less than a second apart is the same instant; exactly a second apart is not.
    func testTheToleranceBoundaries() {
        let index = InstantIndex([date(100)])
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(100)), 0)
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(100.999)), 0)
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(99.001)), 0)
        XCTAssertNil(index.firstPosition(sameInstantAs: date(101)))
        XCTAssertNil(index.firstPosition(sameInstantAs: date(99)))
        XCTAssertNil(index.firstPosition(sameInstantAs: date(101.001)))
        XCTAssertNil(index.firstPosition(sameInstantAs: date(98.999)))
        assertSame([100], [98.999, 99, 99.001, 99.5, 100, 100.5, 100.999, 101, 101.001])
    }

    /// Two candidates within a second of the query: the one that comes first in the list is the
    /// answer, whichever side of the query it is on and whether or not it is the nearer one.
    func testTwoCandidatesWithinASecondTakeTheFirstInTheList() {
        // Both after the query; the farther one is first in the list.
        XCTAssertEqual(InstantIndex([date(100.9), date(100.1)]).firstPosition(sameInstantAs: date(100)), 0)
        XCTAssertEqual(InstantIndex([date(100.1), date(100.9)]).firstPosition(sameInstantAs: date(100)), 0)
        // Both before the query.
        XCTAssertEqual(InstantIndex([date(99.1), date(99.9)]).firstPosition(sameInstantAs: date(100)), 0)
        XCTAssertEqual(InstantIndex([date(99.9), date(99.1)]).firstPosition(sameInstantAs: date(100)), 0)
        // One on each side; the later instant is first in the list, then the earlier one.
        XCTAssertEqual(InstantIndex([date(100.6), date(99.6)]).firstPosition(sameInstantAs: date(100)), 0)
        XCTAssertEqual(InstantIndex([date(99.6), date(100.6)]).firstPosition(sameInstantAs: date(100)), 0)
        // A stranger first in the list, then the two candidates: the answer is position 1.
        XCTAssertEqual(InstantIndex([date(50), date(100.6), date(99.6)]).firstPosition(sameInstantAs: date(100)), 1)
        XCTAssertEqual(InstantIndex([date(50), date(99.6), date(100.6)]).firstPosition(sameInstantAs: date(100)), 1)
        // The first in the list is neither the nearest nor the lowest nor the highest instant.
        XCTAssertEqual(InstantIndex([date(100.5), date(100), date(99.2), date(100.9)]).firstPosition(sameInstantAs: date(100.1)), 0)
        // The one at exactly a second is not a candidate, wherever it sits in the list.
        XCTAssertEqual(InstantIndex([date(101), date(100.999), date(99), date(99.001)]).firstPosition(sameInstantAs: date(100)), 1)
        assertSame([100.9, 100.1, 99.1, 99.9, 100.6, 99.6, 101, 99], [99, 99.5, 100, 100.05, 100.5, 101, 101.5, 101.9])
    }

    /// Equal instants: the first of them in the list, not the one a sort happens to put first.
    func testDuplicatesAndUnsortedInput() {
        let list = [30.0, 10, 20, 10, 30, 30]
        let index = InstantIndex(list.map(date))
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(10)), 1)
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(30.5)), 0)
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(20.999)), 2)
        assertSame(list, [9, 9.5, 10, 10.5, 15, 19.001, 20.999, 21, 29.5, 30.999, 31])
        // A cluster inside one tolerance: several elements within a second of every query.
        assertSame([50.9, 50.1, 50.5, 50.0, 49.2, 51.7], [48.1, 48.2, 49, 49.9, 50, 50.55, 51, 51.9, 52.7, 52.8])
        // Every element equal: position 0 for any query within a second, the whole run walked.
        XCTAssertEqual(InstantIndex(Array(repeating: date(7), count: 40)).firstPosition(sameInstantAs: date(7.5)), 0)
    }

    /// At today's magnitudes (about 8e8 seconds from the reference date) the boundary is exact.
    func testTheBoundaryAtRealDateMagnitudes() {
        let base = 815_000_000.0
        let index = InstantIndex([date(base + 86_400), date(base)])
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(base + 0.9999999)), 1)
        XCTAssertNil(index.firstPosition(sameInstantAs: date(base + 1)))
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(base - 0.9999999)), 1)
        XCTAssertNil(index.firstPosition(sameInstantAs: date(base - 1)))
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(base + 86_399.0000001)), 0)
        assertSame([base, base + 86_400, base + 2 * 86_400, base + 0.5],
                   [base - 1, base - 0.9999999, base - 0.5, base + 0.5, base + 1, base + 1.4999999, base + 1.5, base + 86_399,
                    base + 86_399.0000001, base + 86_401, base + 172_800.9999999])
    }

    /// A NaN date is the same instant as nothing, and an infinite one neither (its difference from
    /// a finite date is infinite, from itself NaN). Positions stay those of the list as given, so a
    /// NaN before a match does not shift the answer.
    func testNaNAndInfiniteDates() {
        let odd: [Double] = [.nan, .infinity, 5, -.infinity, .nan, 5.5, .infinity]
        let queries: [Double] = [.nan, .infinity, -.infinity, 4.5, 5, 6, 6.4, 6.5]
        let dates = odd.map(date)
        let index = InstantIndex(dates)
        for query in queries {
            XCTAssertEqual(index.firstPosition(sameInstantAs: date(query)), scan(dates, date(query)), "query \(query)")
        }
        XCTAssertNil(index.firstPosition(sameInstantAs: date(.nan)))
        XCTAssertNil(index.firstPosition(sameInstantAs: date(.infinity)))
        XCTAssertNil(index.firstPosition(sameInstantAs: date(-.infinity)))
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(4.5)), 2, "the position in the list, the NaN and the infinity before it counted")
        XCTAssertEqual(index.firstPosition(sameInstantAs: date(6.4)), 5)
        XCTAssertNil(InstantIndex([date(.nan)]).firstPosition(sameInstantAs: date(0)))
    }

    /// Generated lists and queries on a grid that puts many pairs exactly on, just inside and just
    /// outside the tolerance, with duplicates and in random order. The counts show the generator
    /// reaches the cases that tell a first match from another one.
    func testGeneratedListsAnswerAsTheScan() {
        var generator = SeededGenerator(seed: 527)
        let offsets: [Double] = [0, 0.001, 0.25, 0.4, 0.499, 0.5, 0.501, 0.6, 0.75, 0.9, 0.999, 1, 1.001, 1.5, 2]
        var found = 0, missing = 0, severalMatches = 0, firstIsNotNearest = 0, firstIsNotLowestInstant = 0, firstIsNotHighestInstant = 0
        var cases = 0
        for round in 0..<3_000 {
            let base = round % 2 == 0 ? 0.0 : 815_000_000.0
            let size = Int.random(in: 0...12, using: &generator)
            func value() -> Double {
                let second = Double(Int.random(in: 0...6, using: &generator))
                let offset = offsets.randomElement(using: &generator)!
                return base + second + (Bool.random(using: &generator) ? offset : -offset)
            }
            var list = (0..<size).map { _ in value() }
            if size > 1, Bool.random(using: &generator) { list.append(list[0]) }
            let dates = list.map(date)
            let index = InstantIndex(dates)
            for _ in 0..<12 {
                let query = value()
                let expected = scan(dates, date(query))
                XCTAssertEqual(index.firstPosition(sameInstantAs: date(query)), expected, "list \(list), query \(query)")
                cases += 1
                guard let expected else { missing += 1; continue }
                found += 1
                let matches = list.indices.filter { UndoPostState.sameInstant(dates[$0], date(query)) }
                guard matches.count > 1 else { continue }
                severalMatches += 1
                let nearest = matches.min { abs(list[$0] - query) < abs(list[$1] - query) }!
                if abs(list[nearest] - query) < abs(list[expected] - query) { firstIsNotNearest += 1 }
                if matches.contains(where: { list[$0] < list[expected] }) { firstIsNotLowestInstant += 1 }
                if matches.contains(where: { list[$0] > list[expected] }) { firstIsNotHighestInstant += 1 }
            }
            XCTAssertEqual(taken(dates), scanKept(dates), "list \(list)")
        }
        XCTAssertEqual(cases, 36_000)
        XCTAssertGreaterThan(found, 5_000)
        XCTAssertGreaterThan(missing, 2_000)
        XCTAssertGreaterThan(severalMatches, 3_000, "several elements within a second of the query")
        XCTAssertGreaterThan(firstIsNotNearest, 1_000, "an index that returned the nearest match would fail")
        XCTAssertGreaterThan(firstIsNotLowestInstant, 1_000, "an index that returned the earliest instant would fail")
        XCTAssertGreaterThan(firstIsNotHighestInstant, 1_000, "an index that returned the latest instant would fail")
    }

    /// Dense random values: every query has several elements within two seconds of it.
    func testGeneratedDenseListsAnswerAsTheScan() {
        var generator = SeededGenerator(seed: 5_270)
        for _ in 0..<400 {
            let list = (0..<60).map { _ in Double.random(in: 0..<40, using: &generator) }
            let dates = list.map(date)
            let index = InstantIndex(dates)
            for _ in 0..<40 {
                let query = Double.random(in: -2..<42, using: &generator)
                XCTAssertEqual(index.firstPosition(sameInstantAs: date(query)), scan(dates, date(query)), "list \(list), query \(query)")
            }
            XCTAssertEqual(taken(dates), scanKept(dates), "list \(list)")
        }
    }

    // MARK: - The growing set

    /// The tolerance is not transitive: what is taken depends on the order the instants come in.
    func testWhatIsTakenDependsOnTheOrder() {
        XCTAssertEqual(taken([0, 0.9, 1.8].map(date)), [0, 2], "0.9 is dropped against 0; 1.8 is a second from nothing taken")
        XCTAssertEqual(taken([0.9, 0, 1.8].map(date)), [0], "both others are within a second of 0.9")
        XCTAssertEqual(taken([1.8, 0.9, 0].map(date)), [0, 2])
        XCTAssertEqual(taken([0, 1, 2, 0.999, 1.001, 1.999].map(date)), [0, 1, 2], "exactly a second apart is another instant")
        XCTAssertEqual(taken([5, 5, 5.999, 4.001, 6, 4].map(date)), [0, 4, 5])
        XCTAssertEqual(taken([]), [])
        for list in [[0, 0.9, 1.8], [0.9, 0, 1.8], [1.8, 0.9, 0], [0, 1, 2, 0.999, 1.001, 1.999], [5, 5, 5.999, 4.001, 6, 4],
                     [3, 1, 2, 1.5, 2.5, 0.2, 3.9, 4.0, 0.0]] {
            XCTAssertEqual(taken(list.map(date)), scanKept(list.map(date)), "\(list)")
        }
    }

    /// An instant inserted before, between and after what was taken is compared with its two
    /// neighbours at that moment, not with what a later insert puts beside it.
    func testInsertsOnEitherSideOfWhatWasTaken() {
        var distinct = DistinctInstants()
        XCTAssertTrue(distinct.insert(date(100)))
        XCTAssertTrue(distinct.insert(date(98)), "before everything taken")
        XCTAssertTrue(distinct.insert(date(102)), "after everything taken")
        XCTAssertTrue(distinct.insert(date(99)), "between two taken instants, a second from each")
        XCTAssertFalse(distinct.insert(date(99.5)), "within a second of the one before it and the one after it")
        XCTAssertFalse(distinct.insert(date(102.999)), "within a second of the last")
        XCTAssertFalse(distinct.insert(date(97.001)), "within a second of the first")
        XCTAssertTrue(distinct.insert(date(103)))
        XCTAssertTrue(distinct.insert(date(97)))
        XCTAssertFalse(distinct.insert(date(100)), "the same instant again")
    }

    /// On `main` a NaN slot was appended every time (it matches nothing, itself included), and so
    /// was an infinite one (its difference from itself is NaN).
    func testNaNAndInfiniteInstantsAreAlwaysNew() {
        let odd: [Double] = [.nan, 5, .nan, .infinity, .infinity, -.infinity, 5.5, -.infinity, .nan, 6.5]
        let dates = odd.map(date)
        XCTAssertEqual(scanKept(dates), [0, 1, 2, 3, 4, 5, 7, 8, 9])
        XCTAssertEqual(taken(dates), scanKept(dates))
    }

    // MARK: - Scaling

    /// 20,000 slots a day apart, every one looked up and as many misses: the comparisons (the
    /// sort's and the lookups', through the injected counter) stay near n log n. A scan per query
    /// would make about 400 million of them.
    func testTheLookupsDoNotGrowWithTheSquareOfTheList() {
        let count = 20_000
        var generator = SeededGenerator(seed: 20_527)
        let order = Array(0..<count).shuffled(using: &generator)
        let slots = order.map { date(Double($0) * 86_400) }
        let counter = ComparisonCounter()
        let index = InstantIndex(slots, counter: counter)
        let sorting = counter.count
        for (position, slot) in slots.enumerated() {
            XCTAssertEqual(index.firstPosition(sameInstantAs: slot.addingTimeInterval(0.5)), position)
        }
        var misses = 0
        for slot in slots where index.firstPosition(sameInstantAs: slot.addingTimeInterval(43_200)) == nil { misses += 1 }
        XCTAssertEqual(misses, count, "no midpoint is found")
        XCTAssertEqual(counter.lookups, 2 * count)
        // At most log2(20,000) + 1 = 16 steps, the match and the two elements that end the walk.
        XCTAssertLessThanOrEqual(counter.count - sorting, 2 * count * 19)
        XCTAssertLessThanOrEqual(sorting, 3_000_000)
        XCTAssertGreaterThan(sorting, 0, "the sort is counted too")
    }

    /// 20,000 slots a day apart, each offered twice (as two overlapping windows list an occurrence
    /// twice) in shuffled order: every first offer is taken, every second one refused, in near
    /// n log n comparisons. A scan of what was kept would make about 400 million.
    func testTheGrowingSetDoesNotGrowWithTheSquareOfTheList() {
        let count = 20_000
        var generator = SeededGenerator(seed: 21_527)
        let slots = (Array(0..<count) + Array(0..<count)).shuffled(using: &generator).map { date(Double($0) * 86_400) }
        let counter = ComparisonCounter()
        let kept = taken(slots, counter: counter)
        XCTAssertEqual(kept.count, count)
        XCTAssertEqual(counter.lookups, 2 * count)
        XCTAssertLessThanOrEqual(counter.count, 2 * count * 18)
        XCTAssertGreaterThan(counter.count, 2 * count, "the comparisons are counted")
    }

    // MARK: - The probe

    /// A set built without a counter reports to the probe a test binds, and to nothing otherwise;
    /// a counter passed by hand wins over the probe.
    func testASetBuiltWithoutACounterReportsToTheBoundProbe() {
        let probe = ComparisonCounter()
        XCTAssertNil(ComparisonCounter.probe, "nothing is bound outside a test's own scope")
        ComparisonCounter.$probe.withValue(probe) {
            _ = InstantSet([date(1), date(2)]).contains(date(1))
            _ = InstantIndex([date(1), date(2)]).firstPosition(sameInstantAs: date(2))
            var distinct = DistinctInstants()
            _ = distinct.insert(date(3))
            XCTAssertEqual(probe.lookups, 3)
            let own = ComparisonCounter()
            _ = InstantSet([date(1)], counter: own).contains(date(1))
            XCTAssertEqual(own.lookups, 1)
            XCTAssertEqual(probe.lookups, 3, "a counter passed by hand is the one that counts")
        }
        XCTAssertNil(ComparisonCounter.probe)
        let before = probe.lookups
        _ = InstantSet([date(1)]).contains(date(1))
        XCTAssertEqual(probe.lookups, before, "unbound again")
    }
}
