import XCTest
@testable import CheICalMCP

/// Pure-unit tests for the duplicate pairing of `find_duplicate_events` (#325 verify round 1).
///
/// The old loop compared every pair in the range, O(n²) on the manager's actor. EventKit's
/// four-year cut used to bound n; with complete ranges (#325) one open-ended daily series over a
/// wide range gives n in the 10^5 range. The matcher must return exactly the pairs the old loop
/// returned, in the same order, without comparing every pair.
final class DuplicateMatcherTests: XCTestCase {

    private struct Item {
        let title: String?
        let calendar: String
        let start: Date
        let end: Date
    }

    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func item(_ title: String?, _ calendar: String, startMinute: Double, lengthMinutes: Double = 60) -> Item {
        let start = base.addingTimeInterval(startMinute * 60)
        return Item(title: title, calendar: calendar, start: start, end: start.addingTimeInterval(lengthMinutes * 60))
    }

    /// The pre-#325 loop, kept as the reference.
    private func bruteForce(_ items: [Item], tolerance: TimeInterval) -> [DuplicateMatcher.Pair] {
        var pairs: [DuplicateMatcher.Pair] = []
        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                let a = items[i], b = items[j]
                if a.calendar == b.calendar { continue }
                guard let t1 = a.title?.lowercased(), let t2 = b.title?.lowercased(), t1 == t2 else { continue }
                let startDiff = abs(a.start.timeIntervalSince(b.start))
                let endDiff = abs(a.end.timeIntervalSince(b.end))
                if startDiff <= tolerance && endDiff <= tolerance {
                    pairs.append(DuplicateMatcher.Pair(first: i, second: j, startDifference: startDiff))
                }
            }
        }
        return pairs
    }

    private func matched(_ items: [Item], tolerance: TimeInterval) -> [DuplicateMatcher.Pair] {
        DuplicateMatcher.pairs(count: items.count, tolerance: tolerance,
                               title: { items[$0].title }, calendar: { items[$0].calendar },
                               start: { items[$0].start }, end: { items[$0].end })
    }

    func testMatchesTheBruteForcePairsInTheSameOrder() {
        let items = [
            item("Standup", "A", startMinute: 0),
            item("standup", "B", startMinute: 3),          // case-insensitive, within 5 min
            item("Standup", "C", startMinute: 5),          // exactly at the tolerance
            item("Standup", "A", startMinute: 2),          // same calendar as #0: never paired with it
            item("Standup", "D", startMinute: 9),          // start too far from #0, close to #1 and #2
            item("Review", "B", startMinute: 0),
            item("Review", "C", startMinute: 1, lengthMinutes: 90), // end too far
            item(nil, "B", startMinute: 0),                // no title: never paired
            item(nil, "C", startMinute: 0),
            item("Lunch", "A", startMinute: 600),
            item("lunch", "B", startMinute: 604),
        ]
        let tolerance: TimeInterval = 5 * 60
        let expected = bruteForce(items, tolerance: tolerance)
        XCTAssertFalse(expected.isEmpty, "the fixture must contain duplicates")
        XCTAssertEqual(matched(items, tolerance: tolerance), expected)
    }

    func testZeroToleranceMatchesOnlyIdenticalTimes() {
        let items = [item("X", "A", startMinute: 0), item("X", "B", startMinute: 0), item("X", "C", startMinute: 1)]
        XCTAssertEqual(matched(items, tolerance: 0), bruteForce(items, tolerance: 0))
    }

    /// 50,000 occurrences of one daily series in one calendar: the old loop made about 1.25 × 10^9
    /// comparisons and held the actor for minutes. Same-title items more than the tolerance apart
    /// are not compared at all.
    func testOneLargeDailySeriesIsNotComparedPairByPair() {
        let items = (0..<50_000).map { item("Daily", "A", startMinute: Double($0) * 1440) }
        let begin = Date()
        XCTAssertEqual(matched(items, tolerance: 5 * 60), [])
        XCTAssertLessThan(Date().timeIntervalSince(begin), 10, "pairing must not be quadratic in the series length")
    }
}
