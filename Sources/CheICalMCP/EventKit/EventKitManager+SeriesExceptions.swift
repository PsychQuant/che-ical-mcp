import EventKit
import Foundation

/// #285 — the EventKit side of recording and restoring a series' exceptions. The code lives in
/// `SeriesExceptionsUndo`, over the `SeriesExceptionsStoreSource` seam (#322); these entry points
/// run it on this manager's store (`EventKitSeriesExceptionsStore`). The two undo arms run it on the
/// store a test passed to `forTesting(probe:seriesExceptionsStore:)` instead, when there is one; the
/// capture never does.
extension EventKitManager {
    /// The production store: this manager's `eventStore` and its own helpers. Built inside the
    /// manager's isolation and used there only, for the call it was built for.
    var seriesExceptionsStore: EventKitSeriesExceptionsStore {
        EventKitSeriesExceptionsStore(eventStore: eventStore,
                                      applySnapshot: { try self.applySnapshot($0, to: $1) },
                                      storedEvent: { self.storedEvent(id: $0) },
                                      markNeedsRefresh: { self.markNeedsRefresh() },
                                      refreshIfNeeded: { self.refreshIfNeeded() })
    }

    /// `SeriesExceptionsUndo.capture` of `series`, read before a whole-series delete removes
    /// anything. The record sites hand it an `EKEvent`, so it always runs on this manager's store.
    func captureSeriesExceptions(of series: EKEvent) -> SeriesExceptions? {
        SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore)
    }

    /// The `.deleteEvent` undo arm (`SeriesExceptionsUndo.undoDeleteEvent`).
    func undoDeletedEvent(_ snapshot: EventSnapshot) throws -> String {
        if let store = seriesExceptionsStoreOverride {
            return try SeriesExceptionsUndo.undoDeleteEvent(snapshot, in: store)
        }
        return try SeriesExceptionsUndo.undoDeleteEvent(snapshot, in: seriesExceptionsStore)
    }

    /// The `.deleteOccurrence` undo arm (`SeriesExceptionsUndo.undoDeleteOccurrence`).
    func undoDeletedOccurrence(_ snapshot: EventSnapshot, notCarriedOver: [String]) throws -> String {
        if let store = seriesExceptionsStoreOverride {
            return try SeriesExceptionsUndo.undoDeleteOccurrence(snapshot, notCarriedOver: notCarriedOver, in: store)
        }
        return try SeriesExceptionsUndo.undoDeleteOccurrence(snapshot, notCarriedOver: notCarriedOver, in: seriesExceptionsStore)
    }
}
