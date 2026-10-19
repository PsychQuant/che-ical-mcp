import Foundation

/// #325 verify round 1: the pairing behind `find_duplicate_events`.
///
/// Two events are duplicates when they are in different calendars, their titles are equal
/// ignoring case (both present), and both their starts and their ends are within `tolerance`.
/// The earlier loop compared every pair in the range on the manager's actor: O(n²). EventKit's
/// four-year cut used to bound n; with complete ranges (#325) one open-ended daily series over a
/// wide range gives n in the 10^5 range, about 10^10 comparisons, and every other tool waits.
///
/// Here items are grouped by title and each group is sorted by start, so an item is compared
/// only with the items that start within `tolerance` after it. The result is the same pairs the
/// earlier loop returned, in the same order (by first index, then second).
enum DuplicateMatcher {
    struct Pair: Equatable {
        let first: Int
        let second: Int
        let startDifference: TimeInterval
    }

    static func pairs(count: Int, tolerance: TimeInterval,
                      title: (Int) -> String?, calendar: (Int) -> String,
                      start: (Int) -> Date, end: (Int) -> Date) -> [Pair] {
        var groups: [String: [Int]] = [:]
        for index in 0..<count {
            guard let key = title(index)?.lowercased() else { continue }
            groups[key, default: []].append(index)
        }
        var pairs: [Pair] = []
        for indices in groups.values where indices.count > 1 {
            let sorted = indices.sorted { start($0) < start($1) || (start($0) == start($1) && $0 < $1) }
            for (position, a) in sorted.enumerated() {
                var next = position + 1
                while next < sorted.count {
                    let b = sorted[next]
                    let startDifference = start(b).timeIntervalSince(start(a))
                    if startDifference > tolerance { break }
                    if calendar(a) != calendar(b), abs(end(a).timeIntervalSince(end(b))) <= tolerance {
                        pairs.append(Pair(first: min(a, b), second: max(a, b), startDifference: abs(startDifference)))
                    }
                    next += 1
                }
            }
        }
        return pairs.sorted { ($0.first, $0.second) < ($1.first, $1.second) }
    }
}
