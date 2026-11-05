import EventKit

/// #416: a whole-series write addressed through the identifier of an occurrence that was edited on
/// its own. That identifier resolves to the occurrence object (`isDetached`; on iCloud
/// `<series>/RID=<seconds>`), which EventKit does not treat as the series. Measured on device
/// (iCloud, 2026-11-05, throwaway calendars):
/// - `update_event` with span `all` or `future` split the series at that occurrence: the earlier
///   occurrences kept the series identifier, that one and the later ones became a new series;
/// - `delete_event` with span `all` deleted that occurrence only, and answered that the series was
///   deleted.
/// Both are refused before anything is written: the coordinator's default ("A: refuse") while the
/// maintainer has not chosen between refusing and resolving the series. Not refused, because they
/// measured correct: span `this`, `move_events_batch` with span `all` (the whole series moved, its
/// identifier kept) and `delete_event` with span `future` (that occurrence and the later ones).
/// `delete_events_batch` by date range is not refused either, because the listing named the
/// identifier, not the caller; a range holding only that occurrence deletes it alone (#427).
///
/// The reasons are fixed strings: no EventKit text, no user input.
enum DetachedOccurrenceSpan {
    private static let slotMarker = "/RID="

    /// The identifier names one occurrence: the object is detached, or the identifier carries a
    /// `/RID=` slot. On Google and Exchange an edited occurrence has no `/RID=` (#320), so the
    /// object's `isDetached` is what recognizes it there (not measured on device).
    static func addressesOneOccurrence(identifier: String, isDetached: Bool) -> Bool {
        isDetached || identifier.contains(slotMarker)
    }

    /// `update_event` with span `all` (`wholeSeries`) or `future` through one occurrence.
    static func refusesUpdate(identifier: String, isDetached: Bool, wholeSeries: Bool, span: EKSpan) -> Bool {
        addressesOneOccurrence(identifier: identifier, isDetached: isDetached) && (wholeSeries || span == .futureEvents)
    }

    /// `delete_event` / `delete_events_batch` with span `all` through one occurrence.
    static func refusesSeriesDelete(identifier: String, isDetached: Bool) -> Bool {
        addressesOneOccurrence(identifier: identifier, isDetached: isDetached)
    }

    /// The refusal the `delete_events_batch` dry run by `event_ids` reports for a row, so that the
    /// preview does not list what the real call refuses. Span all only.
    static func dryRunRefusal(span: String, identifier: String, isDetached: Bool) -> String? {
        span == "all" && refusesSeriesDelete(identifier: identifier, isDetached: isDetached) ? seriesDeleteBatchReason : nil
    }

    private static let seriesIdentifierHint = "Use the series' identifier instead (on iCloud, this identifier without its /RID=… part; it is the id of the series' other occurrences in list_events)"

    static func updateReason(wholeSeries: Bool) -> String {
        let span = wholeSeries ? "'all'" : "'future'"
        let instead = wholeSeries
            ? "with span 'all' and no occurrence_date"
            : "with span 'future' and occurrence_date set to this occurrence's date"
        return "event_id names one occurrence of a recurring series, edited on its own, and span \(span) through it would split the series into a new series with a new identifier. \(seriesIdentifierHint), \(instead). To edit this occurrence only, use span 'this'. Nothing was written."
    }

    /// `seriesDeleteReason` as a `delete_events_batch` row: the other rows may have been deleted.
    static let seriesDeleteBatchReason = "This identifier names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only that occurrence, not the series. To delete the series, pass the series' identifier (on iCloud, this identifier without its /RID=… part; it is the id of the series' other occurrences in list_events) with span 'all'. To delete this occurrence only, use span 'this'. This row deleted nothing."

    static let seriesDeleteReason = "event_id names one occurrence of a recurring series, edited on its own, and span 'all' through it would delete only that occurrence, not the series. To delete the series, call it with the series' identifier (on iCloud, this identifier without its /RID=… part; it is the id of the series' other occurrences in list_events) and span 'all'. To delete this occurrence only, use span 'this'. Nothing was deleted."
}
