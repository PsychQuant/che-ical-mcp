import Foundation

/// #527: what one listing of a series' occurrences was made over (`EventKitManager.seriesOccurrences`):
/// the calendar that was enumerated, the series' identifier and external identifier (what tells its
/// occurrences from the calendar's other events), and the ranges, as resolved and in the order they
/// were listed. Two listings with equal keys enumerate the same ranges of the same calendar and keep
/// the same events in the same order, as long as the store does not change between them.
struct SeriesListingKey: Hashable {
    let calendarIdentifier: String
    let eventIdentifier: String
    let externalIdentifier: String?
    let ranges: [DateInterval]
}

/// #527: the series listings of one stretch of checks. `update_event` listed a series once for the
/// baseline of its deleted-occurrence check (#503) and again, right after, for the verdict, and each
/// listing enumerates every event of the calendar in its ranges. Inside `sharing`, a listing made
/// for a key is kept and handed to the next call with that key; outside it, every call lists, as
/// before.
///
/// `sharing` takes a closure that cannot suspend, so a stretch never stays open across an `await`
/// (another call of the actor could otherwise read a listing made before a write), and it ends when
/// the closure returns or throws. What is kept is dropped then. Within a stretch the listing is read
/// once: where `main` listed twice, a change another process made between the two listings could
/// make them differ; here both readers see the one listing.
final class SeriesListingMemo<Listing> {
    /// The listings of the open stretch by what they were made over; nil when no stretch is open.
    private var kept: [SeriesListingKey: Listing]?

    var isSharing: Bool { kept != nil }

    /// Runs `checks` with the listings made inside it shared. A stretch opened inside another one is
    /// part of it: the outer one keeps the listings and ends the sharing.
    func sharing<T>(_ checks: () throws -> T) rethrows -> T {
        guard kept == nil else { return try checks() }
        kept = [:]
        defer { kept = nil }
        return try checks()
    }

    /// The listing for `key`: the one kept in the open stretch, else `list()`, which is kept when a
    /// stretch is open. With no stretch open, `list()` every time.
    func listing(for key: SeriesListingKey, list: () -> Listing) -> Listing {
        guard kept != nil else { return list() }
        if let made = kept?[key] { return made }
        let made = list()
        kept?[key] = made
        return made
    }
}
