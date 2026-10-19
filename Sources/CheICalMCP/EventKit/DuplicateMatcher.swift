import Foundation

/// #325 verify rounds 1-2: the pairing behind `find_duplicate_events`.
///
/// Two events are duplicates when they are in different calendars, their titles are equal
/// ignoring case (both present), and both their starts and their ends are within `tolerance`.
/// The earlier loop compared every pair in the range on the manager's actor: O(n²). EventKit's
/// four-year cut used to bound n; with complete ranges (#325) one open-ended daily series over a
/// wide range gives n in the 10^5 range, about 10^10 comparisons, and every other tool waits.
///
/// Items are grouped by title, then by calendar, each calendar's list sorted by start. Only lists
/// of two different calendars are compared, and only within `tolerance` of each start (a window
/// that slides forward), so one calendar is never compared with itself however large the
/// tolerance (round 2: the first version still compared same-calendar items inside the window).
/// The result is the same pairs the earlier loop returned, in the same order (by first index,
/// then second).
enum DuplicateMatcher {
    struct Pair: Equatable {
        let first: Int
        let second: Int
        let startDifference: TimeInterval
    }

    static func pairs(count: Int, tolerance: TimeInterval,
                      title: (Int) -> String?, calendar: (Int) -> String,
                      start: (Int) -> Date, end: (Int) -> Date) -> [Pair] {
        var groups: [String: [String: [Int]]] = [:]
        for index in 0..<count {
            guard let key = title(index)?.lowercased() else { continue }
            groups[key, default: [:]][calendar(index), default: []].append(index)
        }
        var pairs: [Pair] = []
        for byCalendar in groups.values where byCalendar.count > 1 {
            let lists = byCalendar.keys.sorted().map { key in
                byCalendar[key]!.sorted { start($0) < start($1) || (start($0) == start($1) && $0 < $1) }
            }
            for left in 0..<lists.count {
                for right in (left + 1)..<lists.count {
                    let a = lists[left], b = lists[right]
                    var low = 0
                    for x in a {
                        let from = start(x).addingTimeInterval(-tolerance)
                        while low < b.count, start(b[low]) < from { low += 1 }
                        var y = low
                        while y < b.count {
                            let startDifference = start(b[y]).timeIntervalSince(start(x))
                            if startDifference > tolerance { break }
                            if abs(end(x).timeIntervalSince(end(b[y]))) <= tolerance {
                                pairs.append(Pair(first: min(x, b[y]), second: max(x, b[y]),
                                                  startDifference: abs(startDifference)))
                            }
                            y += 1
                        }
                    }
                }
            }
        }
        return pairs.sorted { ($0.first, $0.second) < ($1.first, $1.second) }
    }
}
