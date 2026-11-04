import EventKit

/// #270 round 3: the narrow seam `delete_event` goes through (CLAUDE.md "Test Seam Convention"),
/// so a handler test can check the date that reaches the delete, not only the call that computes
/// it. Production passes nothing and gets `EventKitManager.shared`.
protocol EventDeletionSource: Sendable {
    /// The zone a date-only `occurrence_date` is read in (`EventKitManager.occurrenceDateTimeZone`).
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone?
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws
    func deleteEventSeries(identifier: String) async throws
}

extension EventKitManager: EventDeletionSource {}
