import EventKit

/// #331: one event as `delete_events_batch` by date range reads it: the identifier (nil for an
/// event without one; it is previewed as "" and never sent), start, end and slot
/// (`EKEvent.occurrenceDate`, which differs from the start for a moved occurrence). A value type,
/// because `EKEvent`'s identifier and slot are read-only and a test double could not set them.
struct BatchDeletionListedEvent: Sendable, Equatable {
    let identifier: String?
    let start: Date
    let end: Date
    let slot: Date?
    /// #427: an occurrence edited on its own, by its own identifier. Read by tests and filled by the
    /// listing only: the handler judges a row through `previewEventDeletion` (cluster verify r2).
    var isDetached = false
}

/// #416: what the `event_ids` dry run says about one row.
enum BatchDeletionPreviewRow: Sendable, Equatable {
    case deletes(start: Date, end: Date)
    /// #436 (PR #465 verify r2): a series row that the real call deletes from its first occurrence
    /// edited on its own, which cannot be undone; the preview says so before anything is deleted.
    case deletesThroughFirstOccurrence(start: Date, end: Date, occurrenceID: String)
    case refused(String)
}

/// #331: the narrow seam `delete_events_batch` goes through (CLAUDE.md "Test Seam Convention"):
/// the date-range listing and the two batch deletes, so a handler test reads the response
/// (`searched_from` / `searched_to`, the deletion ceiling, `deletions`, `preview_truncated`,
/// `already_removed`) instead of the handler's source. The two deletes also carry the `event_ids`
/// mode's real deletion, which shares `deleteEventsWithSpan`, and `previewEventDeletion` its dry
/// run (#416). Production passes nothing and gets `EventKitManager.shared`; access checks and undo
/// recording stay inside the manager.
protocol EventBatchDeletionSource: Sendable {
    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent]
    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult
    /// An identifier of one occurrence edited on its own is refused, as a failed row, while another
    /// occurrence of its series is left that `identifiers` does not hold (#416). By date range too
    /// (#427): the row would delete that occurrence alone, answering for the series.
    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult
    /// One `event_ids` dry-run row. `span` as the real row takes it, `spanAll` for span `all`.
    /// `namedInTheCall`: every id of the call. `goneInTheCall`: the rows passed so far with span
    /// `all`, which the real call has deleted by the time it gets to this row. Throws what the real
    /// row would fail with when the id does not resolve.
    func previewEventDeletion(identifier: String, span: EKSpan, spanAll: Bool, namedInTheCall: Set<String>,
                              goneInTheCall: Set<String>) async throws -> BatchDeletionPreviewRow
}

extension EventKitManager: EventBatchDeletionSource {
    /// `listEvents`, read as the handler read it before #331: `eventIdentifier`, `startDate`,
    /// `endDate`, `occurrenceDate`.
    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent] {
        try await listEvents(startDate: startDate, endDate: endDate, calendarName: calendarName,
                             calendarSource: calendarSource)
            .map { BatchDeletionListedEvent(identifier: $0.eventIdentifier, start: $0.startDate,
                                            end: $0.endDate, slot: $0.occurrenceDate, isDetached: $0.isDetached) }
    }

    /// Refreshed, like the writes the dry run describes (#326): a series whose first occurrence was
    /// deleted shows its first remaining occurrence, not the deleted one.
    func previewEventDeletion(identifier: String, span: EKSpan, spanAll: Bool, namedInTheCall: Set<String>,
                              goneInTheCall: Set<String>) async throws -> BatchDeletionPreviewRow {
        try await ensureCalendarAccess()
        guard let event = try freshEventWithOrigin(
            id: identifier, refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span, wholeSeries: spanAll),
            goneInTheCall: goneInTheCall)?.event else {
            // #436: what the real row does when the series reaches only its first occurrence.
            if spanAll, let first = try firstEditedOccurrenceID(of: identifier, excluding: goneInTheCall),
               let occurrence = try freshEvent(id: first.id) {
                if let refusal = Self.throughFirstOccurrenceRefusal(occurrence, movedFirst: try movedFirstDeleteRefusal(occurrence, id: first.id)) {
                    return .refused(refusal)
                }
                return .deletesThroughFirstOccurrence(start: occurrence.startDate, end: occurrence.endDate, occurrenceID: first.id)
            }
            throw notFoundError(id: identifier)
        }
        // #416: what the real call refuses is not listed as a deletion.
        if spanAll, let refusal = try seriesDeleteRefusal(event, id: identifier, namedInTheCall: namedInTheCall, batch: true) {
            return .refused(refusal)
        }
        if !spanAll, event.hasRecurrenceRules { return .refused(Self.batchOccurrenceDateRequired) }
        return .deletes(start: event.startDate, end: event.endDate)
    }
}
