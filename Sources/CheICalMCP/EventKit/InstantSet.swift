import Foundation

/// #520: counts the work of the `InstantSet`s it is given to, for the tests that show it does not grow
/// with the square of the list: `count`, every comparison of two dates (the sort's and the lookups'),
/// and `lookups`, every call of `contains`. No caller in the server passes one.
final class ComparisonCounter {
    var count = 0
    var lookups = 0
}

/// #520: the instants of a list, to ask whether any of them is the same instant as another one, to the
/// second: what `list.contains { UndoPostState.sameInstant($0, query) }` answers, without the scan.
/// The #503 verdict (`DeletedOccurrenceCheck.verdict`) made that scan for every slot of the rule and
/// for every listed slot: a third of a second for 4,000 listed occurrences, growing with the square.
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
        counter?.lookups += 1
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
