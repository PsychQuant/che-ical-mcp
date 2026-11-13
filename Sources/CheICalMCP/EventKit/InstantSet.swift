import Foundation

/// #520: counts the work of the `InstantSet`s it is given to, for the tests that show it does not grow
/// with the square of the list: `count`, every comparison of two dates (the sort's and the lookups'),
/// and `lookups`, every call of `contains`. No caller in the server passes one.
///
/// #527: `InstantIndex` and `DistinctInstants` count the same way (`lookups`: every `firstPosition`
/// and every `insert`). A set built without a counter reports to `probe` when a test has bound one,
/// so a test can count the sets a function of the server builds inside itself (the undo paths) while
/// no file of the server passes or names a counter. Nothing in the server binds it; it is read once
/// per set built, not per comparison. What is counted is date comparisons and calls: the elements
/// an insertion into a sorted array moves (`DistinctInstants.insert`) are not.
///
/// `@unchecked Sendable` because a task-local value must be `Sendable`, while `count` and `lookups`
/// are plain variables. The invariant it relies on: a counter is touched only by the one test that
/// made it, on the thread that bound it, so nothing run inside a bound scope may start a task (a
/// child task inherits the binding and would count from another thread).
final class ComparisonCounter: @unchecked Sendable {
    var count = 0
    var lookups = 0

    @TaskLocal static var probe: ComparisonCounter?
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
        let counter = counter ?? ComparisonCounter.probe
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

/// #527: the instants of a list with their positions in it, to find the first element of the list
/// (in the list's own order) that is the same instant as another one, to the second: what
/// `list.firstIndex { UndoPostState.sameInstant($0, query) }` answers, without the scan. The undo of
/// a whole-series delete resolves each occurrence it removes this way, and the undo of a whole-series
/// update each occurrence edited on its own that it compares, so the element returned must be the
/// one the scan returned, also when two elements are within a second of the query.
///
/// The instants are sorted with their positions. For a fixed query the difference
/// `element - query` grows with the element (`InstantSet`'s argument), so the elements within the
/// tolerance are one unbroken run around the query in sorted order: from the first element at or
/// after the query onwards while `UndoPostState.sameInstant` holds, and from the one before it
/// backwards while it holds. The walk sees every match and no other element but the two that end
/// it; the smallest position among the matches is the first match in the list's order.
///
/// The walk reads the whole run of matches plus those two elements, which can be more than the scan
/// read: the scan stopped at its first match in the list's order, so where that match came early
/// in the list (40 equal instants and one query: one comparison) the walk still reads all of the
/// run. The answer is the same. A list of n elements all within a second of each of n queries
/// costs n walks of n elements here, where the scan stopped at once. A rule gives at most one slot
/// a day, so the lists the undo paths index are not expected to hold two elements within a second
/// of each other, and a walk is then the match and the two elements that end it.
struct InstantIndex {
    private let sorted: [(instant: Date, position: Int)]
    private let counter: ComparisonCounter?

    init(_ instants: [Date], counter: ComparisonCounter? = nil) {
        let counter = counter ?? ComparisonCounter.probe
        // A NaN instant is the same instant as nothing, so it is left out; the positions kept are
        // those of the list as given.
        let placed = instants.enumerated().compactMap { offset, instant in
            instant.timeIntervalSinceReferenceDate.isNaN ? nil : (instant: instant, position: offset)
        }
        if let counter {
            sorted = placed.sorted { counter.count += 1; return $0.instant < $1.instant }
        } else {
            sorted = placed.sorted { $0.instant < $1.instant }
        }
        self.counter = counter
    }

    /// The position, in the list as given, of its first element at the same instant as `query`;
    /// nil when it has none.
    func firstPosition(sameInstantAs query: Date) -> Int? {
        counter?.lookups += 1
        // The first element at or after the query (a NaN query is before nothing: `low` stays 0,
        // and `sameInstant` is false for it).
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = low + (high - low) / 2
            counter?.count += 1
            if sorted[middle].instant < query { low = middle + 1 } else { high = middle }
        }
        var first: Int?
        var index = low
        while index < sorted.count {
            counter?.count += 1
            guard UndoPostState.sameInstant(sorted[index].instant, query) else { break }
            first = min(first ?? sorted[index].position, sorted[index].position)
            index += 1
        }
        index = low - 1
        while index >= 0 {
            counter?.count += 1
            guard UndoPostState.sameInstant(sorted[index].instant, query) else { break }
            first = min(first ?? sorted[index].position, sorted[index].position)
            index -= 1
        }
        return first
    }
}

/// #527: instants taken one at a time, each only when none taken before it is the same instant, to
/// the second: what `if !kept.contains(where: { UndoPostState.sameInstant($0, instant) }) { kept.append(instant) }`
/// decides, without the scan of `kept`. The undo of a whole-series delete lists the recreated
/// series' occurrences once per recorded window and takes an occurrence where two windows overlap
/// once (`SeriesExceptionsUndo.restore`).
///
/// The tolerance is not transitive, so what is taken depends on the order (0 s, 0.9 s, 1.8 s takes
/// the first and the third), and a set built from the whole list cannot answer it: the taken
/// instants are kept sorted as they come, and a new one is compared with the first taken instant at
/// or after it and the one before it (`InstantSet`'s two neighbours). A NaN instant is the same
/// instant as nothing, so it is always new, and it is not kept (nothing can match it later either).
///
/// What this bounds is the date comparisons: a binary search and at most two `sameInstant` calls per
/// instant offered, where the scan compared it with every instant kept. It does not bound the
/// elements moved: `sorted` is an array, so taking an instant moves every kept instant after its
/// position. Instants offered in ascending order are appended and move nothing; offered in
/// descending order each one moves all that were kept, n(n-1)/2 moves of one `Date` (8 bytes) for
/// n instants, and no order moves more. The one caller offers the occurrences of at most two
/// recorded windows of at most 1,460 days each, so about 2,920 slots of a daily series at most:
/// under 4.3 million moves in the worst order. The record lists the later window first
/// (`SeriesExceptionsUndo.capture`), so when each window is listed in date order, every slot of
/// the earlier window outside the overlap is inserted before the whole first block (at most about
/// 1,460 x 1,460 moves); its slots inside the overlap are refused, and the first window's own
/// slots were appended.
struct DistinctInstants {
    private var sorted: [Date] = []
    private let counter: ComparisonCounter?

    init(counter: ComparisonCounter? = nil) {
        self.counter = counter ?? ComparisonCounter.probe
    }

    /// Whether no instant taken so far is the same instant as `instant`; it is taken then.
    mutating func insert(_ instant: Date) -> Bool {
        counter?.lookups += 1
        guard !instant.timeIntervalSinceReferenceDate.isNaN else { return true }
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = low + (high - low) / 2
            counter?.count += 1
            if sorted[middle] < instant { low = middle + 1 } else { high = middle }
        }
        if low < sorted.count {
            counter?.count += 1
            if UndoPostState.sameInstant(sorted[low], instant) { return false }
        }
        if low > 0 {
            counter?.count += 1
            if UndoPostState.sameInstant(sorted[low - 1], instant) { return false }
        }
        sorted.insert(instant, at: low)
        return true
    }
}
