import Foundation

/// #520: what the series listing (`EventKitManager.seriesOccurrences`) takes an occurrence once by: its
/// calendar item identifier and its start, compared exactly (`==`, no tolerance). An occurrence that
/// overlaps two listing ranges is listed by both, with the same identifier and start.
///
/// The listing used to compare each occurrence with every occurrence listed before it, reading four
/// EventKit properties per comparison, which made a daily series begun eight years ago (about 4,000
/// occurrences listed) take seconds to change. A set of these keys keeps the same equality in one pass.
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
