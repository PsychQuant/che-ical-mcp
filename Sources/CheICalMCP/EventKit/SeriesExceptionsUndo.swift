import EventKit
import Foundation

/// #285 — recording and restoring a series' exceptions, and the two delete-undo arms that use
/// them, over a `SeriesExceptionsStoreSource` (#322). The decisions are `SeriesExceptionsPlanner`
/// and `SeriesExceptionsRestorer` (pure, tested); this is the layer that lists occurrences and
/// writes, verified on device with the EventKit store. #322 moved these bodies here from
/// `EventKitManager` unchanged, call for call, so that the same code runs against a fake in tests.
enum SeriesExceptionsUndo {
    /// The exceptions of `series`, read before a whole-series delete removes anything: the
    /// occurrences that exist over the series' scan window, split into those that stay and those
    /// edited on their own. Nil when they cannot be listed (no identifier or calendar, or no
    /// occurrence of the series found inside the window), so the record says so instead of
    /// claiming there were none.
    static func capture<Store: SeriesExceptionsStoreSource>(of series: Store.Event, in store: Store) -> SeriesExceptions? {
        let ids = store.identifiers(of: series)
        guard let id = ids.eventIdentifier, !id.isEmpty, store.hasCalendar(series) else { return nil }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: ids.externalIdentifier)
        let window = store.scanWindow(of: series)
        var observed: [SeriesExceptionsPlanner.ObservedOccurrence] = []
        // Listed over the window and a year on each side, as separate queries: an occurrence edited
        // on its own is matched by its current time, so one moved out of the window is only found
        // there (PR #318 verify B1; round 2, A: the four-year limit is per query).
        var seen = Set<String>()
        for range in SeriesExceptionsPlanner.listingRanges(for: window) {
            for occurrence in store.events(in: range, inCalendarOf: series) {
                let key = "\(store.identifiers(of: occurrence).eventIdentifier ?? "")|\(store.startDate(of: occurrence).timeIntervalSinceReferenceDate)"
                if seen.insert(key).inserted { observed.append(store.observed(occurrence)) }
            }
        }
        return SeriesExceptionsPlanner.capture(observed, of: seriesIDs, window: window)
    }

    /// Undo of a whole-series delete that recorded `exceptions`, after `restored` was saved from
    /// the rules: removes the occurrences the original series did not have (deleted on their own
    /// before the delete) and recreates each occurrence edited on its own as a one-off event.
    /// All or nothing: a failure deletes `restored` and the one-off events again.
    static func restore<Store: SeriesExceptionsStoreSource>(_ exceptions: SeriesExceptions, of restored: Store.Event,
                                                            in store: Store) throws -> SeriesExceptionsRestorer.Outcome {
        let restoredIDs = store.identifiers(of: restored)
        guard let id = restoredIDs.eventIdentifier, !id.isEmpty, store.hasCalendar(restored) else {
            try rollbackRestoredSeries(restored, exclusionsApplied: 0, in: store)
            throw EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not restore the exceptions of the recreated series (it has no identifier). The series was deleted again; nothing was restored. Retry undo.")
        }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: restoredIDs.externalIdentifier)
        var generated: [(slot: Date, occurrence: Store.Event)] = []
        for occurrence in store.events(in: exceptions.window, inCalendarOf: restored)
        where UndoPostState.isOccurrence(store.identifiers(of: occurrence), of: seriesIDs) {
            generated.append((store.slot(of: occurrence), occurrence))
        }
        do {
            return try SeriesExceptionsRestorer.restore(
                exceptions: exceptions, seriesStart: store.startDate(of: restored), generated: generated,
                remove: { try store.remove($0, span: .thisEvent) },
                createOneOff: { detached in
                    let oneOff = store.makeEvent()
                    do {
                        // Inside a delete-undo, after the recreated series was saved in this
                        // calendar, so the synchronous lookup (#269); a miss here is rolled back.
                        let calendar = try store.calendarNow(for: detached.snapshot, kind: .recreateDeleted)
                        store.apply(detached.snapshot, to: oneOff, calendar: calendar)
                        try store.save(oneOff)
                        return oneOff
                    } catch {
                        throw SeriesExceptionsOneOffWriteFailed(possiblyWritten: oneOff)
                    }
                },
                removeOneOff: { oneOff in
                    // A save that threw may or may not have written: remove only what the store holds.
                    guard store.isStored(oneOff) else { return }
                    try store.remove(oneOff, span: .thisEvent)
                },
                rollbackSeries: { try store.remove(restored, span: .futureEvents) })
        } catch let error as SeriesExceptionsRestoreError {
            store.markNeedsRefresh()
            throw restoreFailure(error)
        }
    }

    private static func rollbackRestoredSeries<Store: SeriesExceptionsStoreSource>(_ restored: Store.Event, exclusionsApplied: Int,
                                                                                  in store: Store) throws {
        do { try store.remove(restored, span: .futureEvents); store.markNeedsRefresh() } catch {
            throw restoreFailure(.rollbackFailed(exclusionsApplied: exclusionsApplied))
        }
    }

    /// Rolled back → a plain error (the record is put back for a retry). The compensating delete
    /// failing is permanent: a retry would create a second series, so the record is discarded.
    static func restoreFailure(_ error: SeriesExceptionsRestoreError) -> Error {
        func day(_ date: Date) -> String { EventKitManager.formatExclusionDay(date, timezone: nil) }
        switch error {
        case .surplusUnresolved(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not restore the exceptions of the series: no occurrence of the recreated series on \(day(date)). The series was deleted again; nothing was restored. Retry undo.")
        case .removeFailed(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not remove the occurrence on \(day(date)) that the deleted series did not have. The recreated series was deleted again; nothing was restored. Retry undo.")
        case .oneOffFailed(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not recreate the occurrence edited on its own on \(day(date)). The recreated series and the occurrences recreated so far were deleted again; nothing was restored. Retry undo; if it keeps failing, discard_id gives up this undo (the series is then not restored at all).")
        case .strayOneOffs(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not finish restoring the exceptions of the series (the occurrence edited on its own on \(day(date)) could not be recreated). The recreated series was deleted again, but an occurrence recreated before the failure could not be removed and remains in the calendar: check Calendar and remove it before retrying undo, or a retry will add it again.")
        case .oneOffMaybeLeft(let date):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not recreate the occurrence edited on its own on \(day(date)). The recreated series was deleted again, but that occurrence's save failed in a way that may have written it and it could not be removed: check Calendar for a stray event on that day before retrying undo.")
        case .rollbackFailed(let applied):
            return UnrecoverableUndoError(
                message: "Undo recreated the series but could not finish restoring its exceptions, and deleting it again failed too: the series exists with \(applied) occurrence(s) removed, and any occurrences edited on their own that were recreated before the failure may remain (they were removed first where possible). Check Calendar; this undo entry is discarded because a retry would create a second series.")
        }
    }

    /// Whether `calendar` (the snapshot's own, resolved by the caller) already holds an occurrence
    /// of a recurring series with its title at its start (`OccurrenceSlotGuard`). The store is
    /// refreshed first when this server wrote since the last refresh, so the series an earlier undo
    /// just recreated is seen.
    static func seriesHoldsSlot<Store: SeriesExceptionsStoreSource>(of snapshot: EventSnapshot, calendar: Store.Calendar,
                                                                    in store: Store) -> Bool {
        OccurrenceSlotGuard.isHeld(title: snapshot.title, start: snapshot.startDate, by: store.slotHolders(for: snapshot, in: calendar))
    }

    /// The undo of `.deleteEvent`: recreate from the snapshot; a series from its rules only (#285),
    /// which the text says. #261: no discard; in the failure classes tried on device, a failed new
    /// event was not written by a later save (see NewObjectSave). A series whose exceptions were
    /// recorded gets them back (all or nothing).
    /// `calendar` is the recorded one, read by the caller through `restoreCalendar(for:kind:)` with
    /// `.recreateDeleted` (#269; `EventKitManager.undoDeletedEvent`), so this runs synchronously on
    /// the caller's actor. Returns the text and what the undo did (#323: none for an event that is
    /// not a series), which a batch carries up instead of the text.
    static func undoDeleteEvent<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, calendar: Store.Calendar,
                                                                    in store: Store) throws -> (text: String, outcome: UndoEventOutcome?) {
        let event = store.makeEvent()
        store.apply(snapshot, to: event, calendar: calendar)
        try store.save(event)
        store.markNeedsRefresh()
        var outcome: SeriesExceptionsRestorer.Outcome?
        if snapshot.restoresFromRules, let exceptions = snapshot.exceptions {
            outcome = try restore(exceptions, of: event, in: store)
        }
        let text = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: store.identifiers(of: event).eventIdentifier ?? "unknown",
                                                      exceptionsOutcome: outcome)
        guard snapshot.restoresFromRules else { return (text, nil) }
        return (text, outcome.map(UndoEventOutcome.seriesWithExceptions) ?? .seriesFromRules)
    }

    /// The undo of `.deleteOccurrence`. #244: the snapshot holds no rules, so the occurrence comes
    /// back as a one-off event at its slot, beside what is left of the series (EventKit cannot put
    /// it back in). #285: not when the series already holds the slot (it was recreated from its
    /// rules by an undo of the whole-series delete, which brings every slot back).
    /// `calendar` is the recorded one, read once by the caller with `.recreateDeletedOccurrence`
    /// before the slot check and the write (#269 verify; `EventKitManager.undoDeletedOccurrence`).
    /// Returns the text and what the undo did (#323).
    static func undoDeleteOccurrence<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, notCarriedOver: [String],
                                                                         calendar: Store.Calendar, in store: Store) throws -> (text: String, outcome: UndoEventOutcome) {
        if seriesHoldsSlot(of: snapshot, calendar: calendar, in: store) {
            return (UndoOperation.occurrenceAlreadyRestoredMessage(title: snapshot.title), .occurrenceAlreadyHeld)
        }
        let event = store.makeEvent()
        store.apply(snapshot, to: event, calendar: calendar)
        try store.save(event)
        store.markNeedsRefresh()
        let text = UndoOperation.occurrenceRestoredMessage(title: snapshot.title, newID: store.identifiers(of: event).eventIdentifier ?? "unknown",
                                                           notCarriedOver: notCarriedOver)
        return (text, .occurrenceOneOff(notCarriedOver: notCarriedOver))
    }
}
