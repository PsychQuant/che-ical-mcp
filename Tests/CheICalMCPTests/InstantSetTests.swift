import XCTest
@testable import CheICalMCP

/// #520: `InstantSet.contains` must answer exactly what the scan it replaces answered,
/// `list.contains { UndoPostState.sameInstant($0, query) }`, with the same one-second tolerance.
final class InstantSetTests: XCTestCase {
    /// The scan `DeletedOccurrenceCheck.verdict` did on `main` (ef79cbc), element first, query second.
    private func scan(_ list: [Date], _ query: Date) -> Bool {
        list.contains { UndoPostState.sameInstant($0, query) }
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    private func assertSame(_ list: [Double], _ queries: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let dates = list.map(date)
        let set = InstantSet(dates)
        for query in queries {
            XCTAssertEqual(set.contains(date(query)), scan(dates, date(query)),
                           "list \(list), query \(query)", file: file, line: line)
        }
    }

    func testAnEmptyListHoldsNothing() {
        XCTAssertFalse(InstantSet([]).contains(date(0)))
        XCTAssertFalse(InstantSet([]).contains(date(.nan)))
        assertSame([], [0, 1, -1, 7e8])
    }

    /// Strictly less than a second apart is the same instant; exactly a second apart is not.
    func testTheToleranceBoundaries() {
        let set = InstantSet([date(100)])
        XCTAssertTrue(set.contains(date(100)))
        XCTAssertTrue(set.contains(date(100.999)))
        XCTAssertTrue(set.contains(date(99.001)))
        XCTAssertFalse(set.contains(date(101)))
        XCTAssertFalse(set.contains(date(99)))
        XCTAssertFalse(set.contains(date(101.001)))
        XCTAssertFalse(set.contains(date(98.999)))
        assertSame([100], [98.999, 99, 99.001, 99.5, 100, 100.5, 100.999, 101, 101.001])
    }

    /// What a set keyed on a rounded value gets wrong (every value here is an exact binary fraction):
    /// 100.375 and 100.625 are a quarter of a second apart and round to different seconds; 100.5 and
    /// 101.375 are 0.875 s apart and round to the same one; 100.875 and 101 are an eighth apart with
    /// different floors; 100.375 and 101.375 are a whole second apart, so not the same instant.
    func testInstantsAroundHalfASecond() {
        XCTAssertTrue(InstantSet([date(100.375)]).contains(date(100.625)))
        XCTAssertTrue(InstantSet([date(100.625)]).contains(date(100.375)))
        XCTAssertTrue(InstantSet([date(100.5)]).contains(date(101.375)))
        XCTAssertTrue(InstantSet([date(100.875)]).contains(date(101)))
        XCTAssertFalse(InstantSet([date(100.375)]).contains(date(101.375)))
        XCTAssertFalse(InstantSet([date(100.5)]).contains(date(101.5)))
        XCTAssertFalse(InstantSet([date(100.5)]).contains(date(99.5)))
        assertSame([100.375, 100.5, 100.625], [99.375, 99.5, 99.625, 100.375, 100.5, 100.625, 101.375, 101.5, 101.625])
    }

    /// The nearer of the two neighbours may be on either side, and the element before the query may
    /// match when the one at or after it does not.
    func testTheNeighbourOnEitherSide() {
        let set = InstantSet([date(10), date(20), date(30)])
        XCTAssertTrue(set.contains(date(19.5)), "the element after the query")
        XCTAssertTrue(set.contains(date(20.5)), "the element before the query")
        XCTAssertTrue(set.contains(date(30.9)), "the last element, with nothing after it")
        XCTAssertTrue(set.contains(date(9.1)), "the first element, with nothing before it")
        XCTAssertFalse(set.contains(date(15)))
        XCTAssertFalse(set.contains(date(31)))
        XCTAssertFalse(set.contains(date(9)))
    }

    func testDuplicatesAndUnsortedInput() {
        assertSame([30, 10, 20, 10, 30, 30], [9, 9.5, 10, 10.5, 15, 19.001, 20.999, 21, 29.5, 30.999, 31])
        // A cluster inside one tolerance: several elements within a second of the query.
        assertSame([50.9, 50.1, 50.5, 50.0, 49.2, 51.7], [48.1, 48.2, 49, 49.9, 50, 50.55, 51, 51.9, 52.7, 52.8])
    }

    /// At today's magnitudes (about 8e8 seconds from the reference date) a double still resolves about
    /// 1e-7 s, and the boundary is exact.
    func testTheBoundaryAtRealDateMagnitudes() {
        let base = 815_000_000.0
        let set = InstantSet([date(base)])
        XCTAssertTrue(set.contains(date(base + 0.9999999)))
        XCTAssertFalse(set.contains(date(base + 1)))
        XCTAssertTrue(set.contains(date(base - 0.9999999)))
        XCTAssertFalse(set.contains(date(base - 1)))
        assertSame([base, base + 86_400, base + 2 * 86_400],
                   [base - 1, base - 0.9999999, base + 0.5, base + 1, base + 86_399, base + 86_399.0000001, base + 86_401, base + 172_800.9999999])
    }

    /// A NaN date is the same instant as nothing (its difference is NaN), and an infinite one neither
    /// (its difference from a finite date is infinite, from itself NaN): the scan said so, and so does the set.
    func testNaNAndInfiniteDates() {
        let odd: [Double] = [.nan, .infinity, -.infinity, 5]
        let queries: [Double] = [.nan, .infinity, -.infinity, 4.5, 5, 6]
        let dates = odd.map(date)
        let set = InstantSet(dates)
        for query in queries {
            XCTAssertEqual(set.contains(date(query)), scan(dates, date(query)), "query \(query)")
        }
        XCTAssertFalse(set.contains(date(.nan)))
        XCTAssertFalse(set.contains(date(.infinity)))
        XCTAssertTrue(set.contains(date(5.5)))
        XCTAssertFalse(InstantSet([date(.nan)]).contains(date(0)))
    }

    /// Generated lists and queries on a grid that puts many pairs exactly on, just inside and just
    /// outside the tolerance, at small and at real magnitudes, with duplicates and in random order.
    func testGeneratedListsAnswerAsTheScan() {
        var generator = SeededGenerator(seed: 520)
        let offsets: [Double] = [0, 0.001, 0.25, 0.4, 0.499, 0.5, 0.501, 0.6, 0.75, 0.9, 0.999, 1, 1.001, 1.5, 2]
        var trueAnswers = 0, falseAnswers = 0, cases = 0
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
            let set = InstantSet(dates)
            for _ in 0..<12 {
                let query = value()
                let expected = scan(dates, date(query))
                XCTAssertEqual(set.contains(date(query)), expected, "list \(list), query \(query)")
                if expected { trueAnswers += 1 } else { falseAnswers += 1 }
                cases += 1
            }
        }
        // The generator must exercise both answers, or the comparison shows nothing.
        XCTAssertEqual(cases, 36_000)
        XCTAssertGreaterThan(trueAnswers, 5_000)
        XCTAssertGreaterThan(falseAnswers, 2_000)
    }

    /// Dense random values: every query has several elements within two seconds of it.
    func testGeneratedDenseListsAnswerAsTheScan() {
        var generator = SeededGenerator(seed: 5_200)
        for _ in 0..<400 {
            let list = (0..<60).map { _ in Double.random(in: 0..<40, using: &generator) }
            let dates = list.map(date)
            let set = InstantSet(dates)
            for _ in 0..<40 {
                let query = Double.random(in: -2..<42, using: &generator)
                XCTAssertEqual(set.contains(date(query)), scan(dates, date(query)), "list \(list), query \(query)")
            }
        }
    }

    // MARK: - Scaling

    /// 20,000 slots a day apart, every one asked for and as many misses: the comparisons (the sort's
    /// and the lookups', through the injected counter) stay near n log n. A scan per query would make
    /// about 400 million of them.
    func testTheComparisonsDoNotGrowWithTheSquareOfTheList() {
        let count = 20_000
        var generator = SeededGenerator(seed: 20_000)
        let slots = (0..<count).map { date(Double($0) * 86_400) }.shuffled(using: &generator)
        let counter = ComparisonCounter()
        let set = InstantSet(slots, counter: counter)
        let sorting = counter.count
        var found = 0
        for slot in slots where set.contains(slot.addingTimeInterval(0.5)) { found += 1 }
        for slot in slots where set.contains(slot.addingTimeInterval(43_200)) { found -= 1 }
        XCTAssertEqual(found, count, "every slot is found and no midpoint is")
        // At most log2(20,000) + 1 = 16 steps and two tolerance checks per lookup.
        XCTAssertLessThanOrEqual(counter.count - sorting, 2 * count * 18)
        // A comparison sort of 20,000 elements needs about 270,000 comparisons; ten times that is far
        // below the 200 million of an insertion into a scanned list.
        XCTAssertLessThanOrEqual(sorting, 3_000_000)
        XCTAssertGreaterThan(sorting, 0, "the sort is counted too")
    }
}
