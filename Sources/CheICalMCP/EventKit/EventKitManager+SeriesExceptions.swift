import EventKit
import Foundation

/// #285 — the EventKit side of recording and restoring a series' exceptions. The code lives in
/// `SeriesExceptionsUndo`, over the `SeriesExceptionsStoreSource` seam (#322); these entry points
/// run it on this manager's store (`EventKitSeriesExceptionsStore`). The two undo arms run it on the
/// store a test passed to `forTesting(probe:seriesExceptionsStore:)` instead, when there is one; the
/// capture never does.
extension EventKitManager {
    /// The production store: this manager's `eventStore` and its own helpers (the #269 calendar read
    /// `restoreCalendar(for:kind:)`, `storedEvent`, the refresh flags). Built inside the manager's
    /// isolation and used there only, for the call it was built for.
    var seriesExceptionsStore: EventKitSeriesExceptionsStore {
        EventKitSeriesExceptionsStore(eventStore: eventStore,
                                      restoreCalendar: { try await self.restoreCalendar(for: $0, kind: $1) },
                                      storedEvent: { try self.storedEvent(id: $0) },
                                      markNeedsRefresh: { self.markNeedsRefresh() },
                                      refreshIfNeeded: { self.refreshIfNeeded() })
    }

    /// `SeriesExceptionsUndo.capture` of `series`, read before a whole-series delete removes
    /// anything. The record sites hand it an `EKEvent`, so it always runs on this manager's store.
    func captureSeriesExceptions(of series: EKEvent) -> SeriesExceptions? {
        SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore)
    }

    /// The `.deleteEvent` undo arm (`SeriesExceptionsUndo.undoDeleteEvent`).
    func undoDeletedEvent(_ snapshot: EventSnapshot) async throws -> (text: String, outcome: UndoEventOutcome?) {
        if let store = seriesExceptionsStoreOverride {
            return try await undoDeletedEvent(snapshot, on: store)
        }
        return try await undoDeletedEvent(snapshot, on: seriesExceptionsStore)
    }

    /// The `.deleteOccurrence` undo arm (`SeriesExceptionsUndo.undoDeleteOccurrence`).
    func undoDeletedOccurrence(_ snapshot: EventSnapshot, notCarriedOver: [String]) async throws -> (text: String, outcome: UndoEventOutcome) {
        if let store = seriesExceptionsStoreOverride {
            return try await undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver, on: store)
        }
        return try await undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver, on: seriesExceptionsStore)
    }

    /// #269: the recorded calendar, read as every event undo reads it (a missing one is refused with
    /// the way on, `EventKitError.undoCalendarMissing`, the record kept); then the arm, synchronously
    /// on this actor, as before #322 moved it.
    private func undoDeletedEvent<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, on store: Store) async throws
        -> (text: String, outcome: UndoEventOutcome?) {
        let calendar = try await store.restoreCalendar(for: snapshot, kind: .recreateDeleted)
        return try SeriesExceptionsUndo.undoDeleteEvent(snapshot, calendar: calendar, in: store)
    }

    /// The occurrence's calendar is read once, before the slot check and the write (#269 verify).
    private func undoDeletedOccurrence<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, notCarriedOver: [String],
                                                                          on store: Store) async throws -> (text: String, outcome: UndoEventOutcome) {
        let calendar = try await store.restoreCalendar(for: snapshot, kind: .recreateDeletedOccurrence)
        return try SeriesExceptionsUndo.undoDeleteOccurrence(snapshot, notCarriedOver: notCarriedOver, calendar: calendar, in: store)
    }
}
