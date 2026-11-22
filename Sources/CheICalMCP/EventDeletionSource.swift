import EventKit

/// #270 round 3: the narrow seam `delete_event` goes through (CLAUDE.md "Test Seam Convention"),
/// so a handler test can check the date that reaches the delete, not only the call that computes
/// it. Production passes nothing and gets `EventKitManager.shared`.
protocol EventDeletionSource: Sendable {
    /// The zone a date-only `occurrence_date` is read in (`EventKitManager.occurrenceDateTimeZone`).
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone?
    /// #539 step 6: returns the forecast of a whole-series delete (`RulesAloneOnUndo`): the recorded
    /// occurrences edited on their own whose recorded slot is no slot of the rule; nil unless it
    /// recorded a whole-series delete with such a record.
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws -> RulesAloneOnUndo?
    func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute
}

/// #428: how `deleteEventSeries` reached the series.
enum SeriesDeleteRoute: Equatable, Sendable {
    /// The series object, recorded so that undo recreates the series. #539 step 6: `unplacedEdits`,
    /// as `deleteEvent`'s result.
    case series(unplacedEdits: RulesAloneOnUndo?)
    /// The series' first occurrence was edited on its own and the series object did not refresh:
    /// deleted with span future from that occurrence (`id`), which removed every occurrence on
    /// iCloud, open-ended series included (2026-11-08), and which undo cannot restore.
    case firstEditedOccurrence(id: String)
}

extension EventKitManager: EventDeletionSource {}
