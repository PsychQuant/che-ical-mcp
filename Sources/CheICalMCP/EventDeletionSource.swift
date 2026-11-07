import EventKit

/// #270 round 3: the narrow seam `delete_event` goes through (CLAUDE.md "Test Seam Convention"),
/// so a handler test can check the date that reaches the delete, not only the call that computes
/// it. Production passes nothing and gets `EventKitManager.shared`.
protocol EventDeletionSource: Sendable {
    /// The zone a date-only `occurrence_date` is read in (`EventKitManager.occurrenceDateTimeZone`).
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone?
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws
    func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute
}

/// #428: how `deleteEventSeries` reached the series.
enum SeriesDeleteRoute: Equatable, Sendable {
    /// The series object, recorded so that undo recreates the series.
    case series
    /// The series' first occurrence was edited on its own and the series object did not refresh:
    /// deleted with span future from that occurrence (`id`), which removed every occurrence on
    /// iCloud, open-ended series included (2026-11-08), and which undo cannot restore.
    case firstEditedOccurrence(id: String)
}

extension EventKitManager: EventDeletionSource {}
