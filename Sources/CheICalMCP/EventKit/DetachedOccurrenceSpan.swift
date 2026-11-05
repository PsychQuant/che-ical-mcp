import EventKit

/// #416: writes that take a span, addressed through the identifier of an occurrence that was edited
/// on its own. That identifier resolves to the occurrence object (`isDetached`; on iCloud
/// `<series>/RID=<seconds>`), which has no recurrence rules of its own. Measured on device (iCloud,
/// 2026-11-05, throwaway calendars) against `main` without these refusals, with a weekly series of 5:
///
/// | Occurrence (its own id) | `update_event` span `all` | `delete_event` / batch span `all` |
/// |---|---|---|
/// | middle, earlier ones remain | split; only it and the later ones updated | only it deleted, answered "all" |
/// | first | every occurrence updated, id kept | only it deleted, answered "all" |
/// | first left, first one deleted | every remaining one updated, new id | only it deleted, answered "all" |
/// | the only one left | it updated, new id | it deleted |
///
/// Refused, before anything is written, is what did something other than what the caller asked for:
/// update span `all` with an earlier occurrence left, delete span `all` with any other occurrence
/// left. These are the coordinator's defaults while the maintainer has not answered.
///
/// Not refused:
/// - `update_event` span `future`: it does what the span says, from this occurrence on, and a split
///   there is what the description says it does; `id_changed` reports it.
/// - span `this`, and `delete_event` span `future` (this occurrence and the later ones; from the
///   earliest occurrence, the whole series).
/// - `move_events_batch` span `all`: all occurrences moved and the identifier stayed, within one
///   iCloud account. Across accounts was not measured.
/// - `delete_events_batch` by date range: the listing named the identifier, not the caller; a range
///   holding only that occurrence deletes it alone (#427).
///
/// The reasons are fixed strings: no EventKit text, no user input.
enum DetachedOccurrenceSpan {
    private static let slotMarker = "/RID="

    /// What is left of the series around the occurrence. `nil` where one is taken means unknown.
    struct Neighbours: Equatable {
        /// An occurrence with an earlier slot: span `all` would split the series.
        let earlierRemain: Bool
        /// Any other occurrence: span `all` through a delete would leave it.
        let othersRemain: Bool
    }

    /// The identifier names one occurrence: the object is detached, or the identifier carries a
    /// `/RID=` slot. Other sources may give an edited occurrence no `/RID=` (#320, not checked), so
    /// the object's `isDetached` is read too.
    static func addressesOneOccurrence(identifier: String, isDetached: Bool) -> Bool {
        isDetached || identifier.contains(slotMarker)
    }

    /// The part of an occurrence's identifier before `/RID=`; nil without one, as nothing says what
    /// the series' identifier is then.
    static func seriesIdentifier(of identifier: String) -> String? {
        guard let range = identifier.range(of: slotMarker), range.lowerBound != identifier.startIndex else { return nil }
        return String(identifier[..<range.lowerBound])
    }

    /// `candidates` are the series' listed occurrences (`FirstRemainingOccurrence.Candidate`), the
    /// occurrence itself among them. By slot, not by the time it shows: a write with `.futureEvents`
    /// covers slots.
    static func neighbours(of identifier: String, slot: Date, among candidates: [FirstRemainingOccurrence.Candidate]) -> Neighbours {
        let others = candidates.filter { $0.eventIdentifier != identifier }
        return Neighbours(earlierRemain: others.contains { ($0.slot ?? $0.start) < slot }, othersRemain: !others.isEmpty)
    }

    /// `update_event` with span `all` through one occurrence with an earlier one left, or with
    /// nothing known about the rest of the series (nothing is written then). `neighbours` is read
    /// only when the answer depends on it: it scans the series.
    static func refusesUpdate(identifier: String, isDetached: Bool, wholeSeries: Bool,
                              neighbours: @autoclosure () -> Neighbours?) -> Bool {
        guard wholeSeries, addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return false }
        return neighbours()?.earlierRemain ?? true
    }

    /// `delete_event` / `delete_events_batch` with span `all` through one occurrence with another
    /// one left, or with nothing known about the rest of the series.
    static func refusesSeriesDelete(identifier: String, isDetached: Bool, neighbours: @autoclosure () -> Neighbours?) -> Bool {
        guard addressesOneOccurrence(identifier: identifier, isDetached: isDetached) else { return false }
        return neighbours()?.othersRemain ?? true
    }

    /// The way to the whole series in every measured shape. It is the series' identifier unless the
    /// earliest occurrence was edited on its own too, and then the series' identifier is refused
    /// (#428) while that occurrence's own id works.
    static let earliestHint = "the id list_events shows for the series' earliest occurrence"

    static let updateReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would split the series here: the earlier occurrences would stay in the old series, not updated. To update the whole series, use \(earliestHint) with span 'all'. To update from this occurrence on, use span 'future', which ends the series here and starts a new one with a new identifier. To edit this occurrence only, use span 'this'. Nothing was written."

    private static let seriesDeleteRoute = "To delete the whole series, use \(earliestHint), with span 'all' when that id has no /RID=… part and span 'future' when it has one. To delete this occurrence only, use span 'this'."

    static let seriesDeleteReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only this occurrence, not the series. \(seriesDeleteRoute) Nothing was deleted."

    /// `seriesDeleteReason` as a `delete_events_batch` row: the other rows may have been deleted.
    static let seriesDeleteBatchReason = "This identifier names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only this occurrence, not the series. \(seriesDeleteRoute) This row deleted nothing."
}
