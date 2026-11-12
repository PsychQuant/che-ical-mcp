import Foundation

/// #520: the two lookups the series listing and the #503 verdict did by scanning a list for every
/// element of another, which made a daily series begun eight years ago take about six seconds to
/// change (about 4,000 occurrences listed, each compared with every one before it, and every slot
/// of the rule compared with every listed slot). Both keep the equality the scans had.

/// What the series listing takes an occurrence once by: its calendar item identifier and its start,
/// compared exactly (`==`, no tolerance), as `seriesOccurrences` compared them. An occurrence that
/// overlaps two listing ranges is listed by both, with the same identifier and start.
struct ListedOccurrenceKey: Hashable {
    let calendarItemIdentifier: String
    let start: Date?
}

/// The keys taken so far. `insert` answers whether the key is new, so a listing keeps the first
/// occurrence with each key, in the order listed, in one pass.
struct FirstSeen<Key: Hashable> {
    private var seen = Set<Key>()

    mutating func insert(_ key: Key) -> Bool {
        seen.insert(key).inserted
    }
}

/// Counts the date comparisons of the `InstantSet`s it is given to (the sort's and the lookups'), for
/// the tests that show they do not grow with the square of the list. No production caller passes one.
final class ComparisonCounter {
    var count = 0
}

/// The instants of a list, to ask whether any of them is the same instant as another one, to the
/// second: what `list.contains { UndoPostState.sameInstant($0, query) }` answers, without the scan.
///
/// The tolerance is not transitive (0.6 s apart twice is 1.2 s apart), so the instants are not
/// rounded into a hash set: they are sorted, and a lookup finds the first one at or after the query
/// and compares that one and the one before it with `UndoPostState.sameInstant`. Those two are
/// enough: for a fixed query the difference `element - query` grows with the element (floating-point
/// subtraction rounds monotonically), so among the elements at or after the query the first has the
/// smallest difference, and among those before it the last has the difference nearest zero. If any
/// element is within the tolerance, one of these two is.
struct InstantSet {
    private let sorted: [Date]
    private let counter: ComparisonCounter?

    init(_ instants: [Date], counter: ComparisonCounter? = nil) {
        // A NaN instant is the same instant as nothing (its difference is NaN), and has no place in
        // an order, so it is left out.
        let ordered = instants.filter { !$0.timeIntervalSinceReferenceDate.isNaN }
        if let counter {
            sorted = ordered.sorted { counter.count += 1; return $0 < $1 }
        } else {
            sorted = ordered.sorted()
        }
        self.counter = counter
    }

    func contains(_ query: Date) -> Bool {
        // The first element at or after the query (a NaN query is before nothing: `low` stays 0, and
        // `sameInstant` is false for it).
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = low + (high - low) / 2
            counter?.count += 1
            if sorted[middle] < query { low = middle + 1 } else { high = middle }
        }
        if low < sorted.count {
            counter?.count += 1
            if UndoPostState.sameInstant(sorted[low], query) { return true }
        }
        if low > 0 {
            counter?.count += 1
            if UndoPostState.sameInstant(sorted[low - 1], query) { return true }
        }
        return false
    }
}
