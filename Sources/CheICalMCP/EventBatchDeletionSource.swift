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
}

/// #416: what the `event_ids` dry run says about one row.
enum BatchDeletionPreviewRow: Sendable, Equatable {
    case deletes(start: Date, end: Date)
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
    /// `refusingOccurrenceIdentifiers` (#416): refuse, as a failed row, an identifier of one
    /// occurrence edited on its own. True for the `event_ids` mode, where the caller named the id;
    /// false by date range, where the listing put it in the set.
    func deleteEventSeriesBatch(identifiers: [String], refusingOccurrenceIdentifiers: Bool) async throws -> BatchDeleteResult
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
                                            end: $0.endDate, slot: $0.occurrenceDate) }
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
            if spanAll, let first = try firstEditedOccurrenceID(of: identifier), let occurrence = try freshEvent(id: first.id) {
                return .deletes(start: occurrence.startDate, end: occurrence.endDate)
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
