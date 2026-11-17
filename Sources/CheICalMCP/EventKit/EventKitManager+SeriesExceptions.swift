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
                                      refreshIfNeeded: { self.refreshIfNeeded() },
                                      noteRecreation: { self.seriesRecreations.note($0, recreatedAs: $1) },
                                      recreations: { self.seriesRecreations.recreations(of: $0) })
    }

    /// `SeriesExceptionsUndo.capture` of `series`, read before a whole-series delete removes
    /// anything. The record sites hand it an `EKEvent`, so it always runs on this manager's store.
    /// PR #558 round 2 (ruling I (a)): `viaStandIn` is the delete's own resolution (`freshEventWithOrigin`),
    /// the one the forecast reads too, kept on the record for the restore.
    func captureSeriesExceptions(of series: EKEvent, viaStandIn: Bool) -> SeriesExceptions? {
        SeriesExceptionsUndo.capture(of: series, in: seriesExceptionsStore, viaStandIn: viaStandIn)
    }

    /// PR #558 round 2 (ruling J): whether the series of `event` has no time zone, for an occurrence's
    /// origin (`OccurrenceOrigin.seriesIsFloating`): through an occurrence's own identifier, the series
    /// object stored under the part before `/RID=`; nil (one reading) when it cannot be read.
    func seriesIsFloating(of event: EKEvent) -> Bool {
        OccurrenceOrigin.seriesIsFloating(eventIdentifier: event.eventIdentifier, ownFloating: OccurrenceOrigin.isFloating(event),
                                          seriesFloating: { id in ((try? self.storedEvent(id: id)) ?? nil).map(OccurrenceOrigin.isFloating) })
    }

    /// #539 step 6: the forecast of a whole-series delete, read before the removal: how many of the
    /// occurrences edited on their own that `exceptions` (this delete's capture) recorded the series'
    /// rule does not place (`SeriesExceptionsPlanner.unplacedEdits`). The rule is expanded from the
    /// first slot #503's check proves (`wholeSeriesBaseline`), in the zone its verdict expands in, and
    /// only when that slot is a plain first occurrence at its own start (`.stored`): through a stand-in,
    /// or with a first occurrence edited on its own, the count is 0, as it is when the expander cannot
    /// tell. The series is listed for it only when the capture recorded an edited occurrence.
    /// PR #558 round 2 (ruling I): before that, the first-slot stop the restore asks
    /// (`SeriesExceptionsPlanner.firstSlotStopsTheRestore`, with the series' start, which the recreated
    /// series takes): when it holds, every recorded edited occurrence is counted, through a stand-in too.
    func unplacedEditsAtDelete(_ exceptions: SeriesExceptions?, of series: EKEvent, id: String, viaStandIn: Bool) -> Int {
        guard let exceptions, !exceptions.detached.isEmpty else { return 0 }
        if SeriesExceptionsPlanner.firstSlotStopsTheRestore(exceptions, seriesStart: series.startDate) { return exceptions.detached.count }
        let first = wholeSeriesBaseline(of: series, id: id, viaStandIn: viaStandIn)
        guard first.baseline == .stored else { return 0 }
        let zone = series.isAllDay ? TimeZone.current : (series.timeZone ?? .current)
        return SeriesExceptionsPlanner.unplacedEdits(exceptions, rules: (series.recurrenceRules ?? []).map(DeletedOccurrenceCheck.Rule.init),
                                                     firstSlot: first.slot, seriesStart: series.startDate, calendar: .gregorian(in: zone)) ?? 0
    }

    /// The `.deleteEvent` undo arm (`SeriesExceptionsUndo.recreateDeletedEvent`).
    /// `kind` words a missing calendar: `.undoMoveByCopy` for the source of a move by copy (#466).
    /// #538: `removedID` is the identifier the record holds, nil for the source of a move by copy
    /// (which records none and is not followed). After the arm returned, older records follow the
    /// recreated event, or are flagged for a series whose edited occurrences came back as separate
    /// events (`DeleteUndoFollow.decision`); an arm that threw has returned no identifier, and
    /// nothing is rewritten. Required, so a caller has to say which. #538 fix 1: `notFollowed` is
    /// `oneOffs` when older records were flagged (the sentence is then on `text`), for a batch, whose
    /// answer reads no member text (R1); and a record of a #263 whole-series update does not follow a
    /// recreated series (`EventIdentifierChange.recreated`, R4).
    func undoDeletedEvent(_ snapshot: EventSnapshot, removedID: String?, kind: EventRestoreKind = .recreateDeleted) async throws
        -> (text: String, outcome: UndoEventOutcome?, notFollowed: Int?) {
        let undone: (text: String, outcome: UndoEventOutcome?, newID: String?)
        if let store = seriesExceptionsStoreOverride {
            undone = try await undoDeletedEvent(snapshot, kind: kind, on: store)
        } else {
            undone = try await undoDeletedEvent(snapshot, kind: kind, on: seriesExceptionsStore)
        }
        guard let removedID else { return (undone.text, undone.outcome, nil) }
        switch DeleteUndoFollow.decision(removedID: removedID, newID: undone.newID,
                                         isOccurrenceRecord: snapshot.isOccurrenceRecord, outcome: undone.outcome) {
        case .follow(let newID):
            await undoHistory.replaceEventIdentifier(removedID, with: newID, change: .recreated)
            return (undone.text, undone.outcome, nil)
        case .flag(let oneOffs):
            let flagged = await undoHistory.markSeriesNotFollowed(removedID)
            guard flagged > 0 else { return (undone.text, undone.outcome, nil) }
            return (DeleteUndoFollow.appendingNotFollowed(undone.text, oneOffs: oneOffs), undone.outcome, oneOffs)
        case .none:
            return (undone.text, undone.outcome, nil)
        }
    }

    /// The `.deleteOccurrence` undo arm (`SeriesExceptionsUndo.undoDeleteOccurrence`).
    func undoDeletedOccurrence(_ snapshot: EventSnapshot, notCarriedOver: [String],
                               kind: EventRestoreKind = .recreateDeletedOccurrence) async throws -> (text: String, outcome: UndoEventOutcome) {
        if let store = seriesExceptionsStoreOverride {
            return try await undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver, kind: kind, on: store)
        }
        return try await undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver, kind: kind, on: seriesExceptionsStore)
    }

    /// #269: the recorded calendar, read as every event undo reads it (a missing one is refused with
    /// the way on, `EventKitError.undoCalendarMissing`, the record kept); then the arm, synchronously
    /// on this actor, as before #322 moved it.
    private func undoDeletedEvent<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, kind: EventRestoreKind,
                                                                      on store: Store) async throws
        -> (text: String, outcome: UndoEventOutcome?, newID: String?) {
        let calendar = try await store.restoreCalendar(for: snapshot, kind: kind)
        return try SeriesExceptionsUndo.recreateDeletedEvent(snapshot, calendar: calendar, kind: kind, in: store)
    }

    /// The occurrence's calendar is read once, before the slot check and the write (#269 verify).
    private func undoDeletedOccurrence<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, notCarriedOver: [String],
                                                                          kind: EventRestoreKind,
                                                                          on store: Store) async throws -> (text: String, outcome: UndoEventOutcome) {
        let calendar = try await store.restoreCalendar(for: snapshot, kind: kind)
        return try SeriesExceptionsUndo.undoDeleteOccurrence(snapshot, notCarriedOver: notCarriedOver, calendar: calendar, kind: kind, in: store)
    }
}
