import XCTest
@testable import CheICalMCP

/// #520: the series listing takes an occurrence once. `FirstSeen` over `ListedOccurrenceKey` must keep
/// exactly the occurrences the scan it replaces kept: the first one with each calendar item identifier
/// and exact start, in the order listed.
final class ListedOccurrenceKeyTests: XCTestCase {
    private struct Listed: Equatable {
        let itemIdentifier: String
        let start: Date?
        /// Which listing position this was, so two equal occurrences are still told apart in the result.
        let position: Int
    }

    /// The de-duplication `seriesOccurrences` did on `main` (ef79cbc), over values.
    private func scanned(_ events: [Listed]) -> [Listed] {
        var listed: [Listed] = []
        for event in events {
            guard !listed.contains(where: { $0.itemIdentifier == event.itemIdentifier && $0.start == event.start }) else { continue }
            listed.append(event)
        }
        return listed
    }

    private func firstSeen(_ events: [Listed]) -> [Listed] {
        var listed: [Listed] = []
        var seen = FirstSeen<ListedOccurrenceKey>()
        for event in events {
            guard seen.insert(ListedOccurrenceKey(calendarItemIdentifier: event.itemIdentifier, start: event.start)) else { continue }
            listed.append(event)
        }
        return listed
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func testAnEmptyListingStaysEmpty() {
        XCTAssertEqual(firstSeen([]), [])
        XCTAssertEqual(scanned([]), [])
    }

    func testTheFirstOfEachIdentifierAndStartIsKeptInOrder() {
        let events = [
            Listed(itemIdentifier: "A", start: date(100), position: 0),
            Listed(itemIdentifier: "A", start: date(200), position: 1),
            Listed(itemIdentifier: "A", start: date(100), position: 2),   // listed again by the next range
            Listed(itemIdentifier: "B", start: date(100), position: 3),   // another item at the same start
            Listed(itemIdentifier: "A", start: date(200), position: 4),
        ]
        XCTAssertEqual(firstSeen(events).map(\.position), [0, 1, 3])
        XCTAssertEqual(firstSeen(events), scanned(events))
    }

    /// The start is compared exactly, as before: no tolerance. Two starts half a second apart are two
    /// occurrences, and so are a start and no start.
    func testTheStartIsComparedExactly() {
        let events = [
            Listed(itemIdentifier: "A", start: date(100), position: 0),
            Listed(itemIdentifier: "A", start: date(100.5), position: 1),
            Listed(itemIdentifier: "A", start: date(100.0000001), position: 2),
            Listed(itemIdentifier: "A", start: nil, position: 3),
            Listed(itemIdentifier: "A", start: nil, position: 4),
            Listed(itemIdentifier: "A", start: date(100), position: 5),
        ]
        XCTAssertEqual(firstSeen(events).map(\.position), [0, 1, 2, 3])
        XCTAssertEqual(firstSeen(events), scanned(events))
    }

    /// Identifiers are compared as `String ==` compares them, which the key's hash follows: the same
    /// text in another Unicode normal form is the same identifier in both; another case is not.
    func testIdentifiersCompareAsStringsDo() {
        let events = [
            Listed(itemIdentifier: "caf\u{E9}", start: date(1), position: 0),
            Listed(itemIdentifier: "cafe\u{301}", start: date(1), position: 1),
            Listed(itemIdentifier: "CAF\u{C9}", start: date(1), position: 2),
            Listed(itemIdentifier: "", start: date(1), position: 3),
            Listed(itemIdentifier: "", start: date(1), position: 4),
        ]
        XCTAssertEqual(firstSeen(events).map(\.position), [0, 2, 3])
        XCTAssertEqual(firstSeen(events), scanned(events))
    }

    /// A NaN start is equal to nothing, itself included, in the scan and in the set alike (EventKit
    /// gives none; this only shows the two do not part ways on it).
    func testANaNStartIsNeverADuplicate() {
        let events = (0..<3).map { Listed(itemIdentifier: "A", start: date(.nan), position: $0) }
        XCTAssertEqual(firstSeen(events).count, 3)
        XCTAssertEqual(firstSeen(events).map(\.position), scanned(events).map(\.position))
    }

    /// Generated listings with many repeats, drawn from few identifiers and few starts.
    func testGeneratedListingsKeepWhatTheScanKept() {
        var generator = SeededGenerator(seed: 52_000)
        let identifiers = ["A", "B", "A/RID=1", "C:1", ""]
        var kept = 0, dropped = 0
        for _ in 0..<1_500 {
            let size = Int.random(in: 0...40, using: &generator)
            let events = (0..<size).map { position -> Listed in
                let start: Date? = Int.random(in: 0..<10, using: &generator) == 0 ? nil
                    : date(Double(Int.random(in: 0...5, using: &generator)) * 86_400 + (Bool.random(using: &generator) ? 0 : 0.5))
                return Listed(itemIdentifier: identifiers.randomElement(using: &generator)!, start: start, position: position)
            }
            let result = firstSeen(events)
            XCTAssertEqual(result, scanned(events))
            kept += result.count
            dropped += events.count - result.count
        }
        XCTAssertGreaterThan(kept, 5_000)
        XCTAssertGreaterThan(dropped, 5_000)
    }

    // MARK: - Scaling

    /// A key that counts its comparisons, so the test sees how many the accumulator makes.
    private struct CountingKey: Hashable {
        let value: Int
        let counter: ComparisonCounter

        static func == (left: CountingKey, right: CountingKey) -> Bool {
            left.counter.count += 1
            return left.value == right.value
        }

        func hash(into hasher: inout Hasher) { hasher.combine(value) }
    }

    /// 20,000 occurrences, each listed by two ranges: the key comparisons stay proportional to the
    /// listing. The scan compared each occurrence with every one before it, about 200 million times
    /// for the first pass alone.
    func testTheKeyComparisonsDoNotGrowWithTheSquareOfTheListing() {
        let count = 20_000
        let counter = ComparisonCounter()
        var seen = FirstSeen<CountingKey>()
        var new = 0
        for _ in 0..<2 {
            for value in 0..<count where seen.insert(CountingKey(value: value, counter: counter)) { new += 1 }
        }
        XCTAssertEqual(new, count)
        XCTAssertGreaterThanOrEqual(counter.count, count, "each repeat is found by at least one comparison")
        XCTAssertLessThanOrEqual(counter.count, 10 * 2 * count)
    }
}
