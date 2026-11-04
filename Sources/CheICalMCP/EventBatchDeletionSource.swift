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

/// #331: the narrow seam `delete_events_batch` goes through (CLAUDE.md "Test Seam Convention"):
/// the date-range listing and the two batch deletes, so a handler test reads the response
/// (`searched_from` / `searched_to`, the deletion ceiling, `deletions`, `preview_truncated`,
/// `already_removed`) instead of the handler's source. Production passes nothing and gets
/// `EventKitManager.shared`; access checks and undo recording stay inside the manager.
protocol EventBatchDeletionSource: Sendable {
    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent]
    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult
    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult
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
}
