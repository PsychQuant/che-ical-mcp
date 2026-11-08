import EventKit
import Foundation

/// #285 — recording and restoring a series' exceptions, and the two delete-undo arms that use
/// them, over a `SeriesExceptionsStoreSource` (#322). The decisions are `SeriesExceptionsPlanner`
/// and `SeriesExceptionsRestorer` (pure, tested); this is the layer that lists occurrences and
/// writes, verified on device with the EventKit store. #322 moved these bodies here from
/// `EventKitManager` unchanged, call for call, so that the same code runs against a fake in tests.
enum SeriesExceptionsUndo {
    /// The exceptions of `series`, read before a whole-series delete removes anything: the
    /// occurrences that exist over the delete window (`SeriesExceptionsPlanner.deleteWindow`, placed
    /// around `now`, #319), split into those that stay and those edited on their own. Nil when they
    /// cannot be listed (no identifier or calendar, or no occurrence of the series found inside the
    /// window), so the record says so instead of claiming there were none.
    static func capture<Store: SeriesExceptionsStoreSource>(of series: Store.Event, in store: Store, now: Date = Date()) -> SeriesExceptions? {
        let ids = store.identifiers(of: series)
        guard let id = ids.eventIdentifier, !id.isEmpty, store.hasCalendar(series) else { return nil }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: ids.externalIdentifier)
        let seriesEnd = store.seriesEnd(of: series)
        let placed = SeriesExceptionsPlanner.deleteWindow(firstStart: store.startDate(of: series), end: seriesEnd,
                                                          deletedAt: now)
        let window = placed.window
        // PR #494 rounds 4-5: a count (known or not) whose window around the delete starts after
        // its first occurrence is also listed over the window from its first occurrence, the window
        // before #319, which placed every count as open-ended. Its end is unknown or only an upper
        // bound, so either window can hold its exceptions. Both are recorded, and the restore applies
        // the exceptions inside either. Rounds 2 and 3 chose one window by what the listing showed,
        // which a continuing series with deleted later occurrences, or a sparse one, fooled.
        // Round 6: decided before anything is listed, then listed once over both windows' merged
        // ranges (`listingRanges(covering:)`).
        let fromFirst = UndoPostState.seriesScanWindow(firstStart: store.startDate(of: series), ruleEnd: nil)
        if seriesEnd.isCount, window.start > fromFirst.start {
            let both = observedOccurrences(of: series, ids: seriesIDs,
                                           over: SeriesExceptionsPlanner.listingRanges(covering: [window, fromFirst]), in: store)
            // Round 7: always kept. It is exactly the window before #319, so its early part behaves as
            // it did then, whether the user deleted those occurrences one by one or the store lacks
            // that history (rounds 5-6 dropped it when its early part listed nothing, which brought a
            // user's early deletions back from the rules).
            let windows = [window, fromFirst]
            guard var exceptions = SeriesExceptionsPlanner.capture(both, of: seriesIDs, windows: windows) else { return nil }
            exceptions.seriesStartsBeforeWindow = false
            exceptions.seriesContinuesAfterWindow = placed.seriesContinuesAfter
            exceptions.seriesMayContinueAfterWindow = placed.seriesMayContinueAfter
            return exceptions
        }
        let observed = observedOccurrences(of: series, ids: seriesIDs, over: SeriesExceptionsPlanner.listingRanges(for: window), in: store)
        guard var exceptions = SeriesExceptionsPlanner.capture(observed, of: seriesIDs, window: window) else { return nil }
        exceptions.seriesStartsBeforeWindow = placed.seriesStartsBefore
        exceptions.seriesContinuesAfterWindow = placed.seriesContinuesAfter
        exceptions.seriesMayContinueAfterWindow = placed.seriesMayContinueAfter
        return exceptions
    }

    /// The series' own occurrences, listed over `ranges`, one query each: a window and a year on each
    /// side of it (`SeriesExceptionsPlanner.listingRanges`), because an occurrence edited on its own is
    /// matched by its current time, so one moved out of a window is only found there (PR #318 verify
    /// B1; round 2, A: the four-year limit is per query). #319: only this series' occurrences are
    /// snapshotted; the listing covers the calendar. An occurrence listed twice (an event that spans
    /// two ranges) is taken once.
    private static func observedOccurrences<Store: SeriesExceptionsStoreSource>(of series: Store.Event, ids seriesIDs: UndoPostState.OccurrenceIDs,
                                                                                over ranges: [DateInterval], in store: Store)
        -> [SeriesExceptionsPlanner.ObservedOccurrence] {
        var observed: [SeriesExceptionsPlanner.ObservedOccurrence] = []
        var seen = Set<String>()
        for range in ranges {
            for occurrence in store.events(in: range, inCalendarOf: series) {
                let occurrenceIDs = store.identifiers(of: occurrence)
                guard UndoPostState.isOccurrence(occurrenceIDs, of: seriesIDs) else { continue }
                let key = "\(occurrenceIDs.eventIdentifier ?? "")|\(store.startDate(of: occurrence).timeIntervalSinceReferenceDate)"
                if seen.insert(key).inserted { observed.append(store.observed(occurrence)) }
            }
        }
        return observed
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
        // Round 4: one listing per recorded window; an occurrence where they overlap is taken once.
        for window in exceptions.windows {
            for occurrence in store.events(in: window, inCalendarOf: restored)
            where UndoPostState.isOccurrence(store.identifiers(of: occurrence), of: seriesIDs) {
                let slot = store.slot(of: occurrence)
                if !generated.contains(where: { UndoPostState.sameInstant($0.slot, slot) }) { generated.append((slot, occurrence)) }
            }
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
                        throw SeriesExceptionsOneOffWriteFailed(possiblyWritten: oneOff, underlying: error)
                    }
                },
                removeOneOff: { oneOff in
                    // A save that threw may or may not have written: remove only what the store
                    // holds. A failed lookup throws, so the event is reported as maybe left (#288).
                    guard try store.isStored(oneOff) else { return }
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
        case .removeFailed(let date, let code):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not remove the occurrence on \(day(date)) that the deleted series did not have (\(code)). The recreated series was deleted again; nothing was restored. Retry undo; if it keeps failing with the same code, discard_id gives up this undo (the series is then not restored at all).")
        case .oneOffFailed(let date, let code):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not recreate the occurrence edited on its own on \(day(date)) (\(code)). The recreated series and the occurrences recreated so far were deleted again; nothing was restored. Retry undo; if it keeps failing with the same code, discard_id gives up this undo (the series is then not restored at all).")
        case .strayOneOffs(let date, let code):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not finish restoring the exceptions of the series: the occurrence edited on its own on \(day(date)) could not be recreated (\(code)). The recreated series was deleted again, but an occurrence recreated before the failure could not be removed and remains in the calendar: check Calendar and remove it before retrying undo, or a retry will add it again.")
        case .oneOffMaybeLeft(let date, let code):
            return EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not recreate the occurrence edited on its own on \(day(date)) (\(code)). The recreated series was deleted again, but that occurrence's save failed in a way that may have written it and it could not be removed: check Calendar for a stray event on that day before retrying undo.")
        case .rollbackFailed(let applied):
            return UnrecoverableUndoError(
                message: "Undo recreated the series but could not finish restoring its exceptions, and deleting it again failed too: the series exists with \(applied) occurrence(s) removed, and any occurrences edited on their own that were recreated before the failure may remain (they were removed first where possible). Check Calendar; this undo entry is discarded because a retry would create a second series.")
        }
    }

    /// #321: whether `calendar` (the snapshot's own, resolved by the caller) already holds an
    /// occurrence of the recorded series, or of a series undo recreated from it, at the recorded
    /// rule slot (`OccurrenceSlotGuard`). The store is refreshed first when this server wrote since
    /// the last refresh, so the series an earlier undo just recreated is seen.
    static func seriesHoldsSlot<Store: SeriesExceptionsStoreSource>(_ origin: OccurrenceOrigin, length: TimeInterval,
                                                                    calendar: Store.Calendar, in store: Store) -> Bool {
        OccurrenceSlotGuard.isHeld(origin, recreatedAs: store.recreations(of: origin.series),
                                   by: store.slotHolders(at: origin.slot, length: length, in: calendar))
    }

    /// The answer when the series holds the slot: an occurrence edited on its own before its delete
    /// is held as the rules give it, so its text and outcome say its edit did not come back
    /// (PR #494 round 1).
    private static func held(_ snapshot: EventSnapshot, _ origin: OccurrenceOrigin) -> (text: String, outcome: UndoEventOutcome) {
        (UndoOperation.occurrenceAlreadyRestoredMessage(title: snapshot.title, edited: origin.edited),
         origin.edited ? .editedOccurrenceAlreadyHeld : .occurrenceAlreadyHeld)
    }

    /// The length the slot is listed for: the occurrence's own (an edited one may be shorter than
    /// the series'; an event that overlaps the slot's first minute is listed either way).
    private static func slotLength(of snapshot: EventSnapshot) -> TimeInterval {
        snapshot.endDate.timeIntervalSince(snapshot.startDate)
    }

    /// The undo of `.deleteEvent`: recreate from the snapshot; a series from its rules only (#285),
    /// which the text says. #261: no discard; in the failure classes tried on device, a failed new
    /// event was not written by a later save (see NewObjectSave). A series whose exceptions were
    /// recorded gets them back (all or nothing).
    /// `calendar` is the recorded one, read by the caller through `restoreCalendar(for:kind:)` with
    /// `.recreateDeleted` (#269; `EventKitManager.undoDeletedEvent`), so this runs synchronously on
    /// the caller's actor. Returns the text and what the undo did (#323: none for an event that is
    /// not a series), which a batch carries up instead of the text.
    ///
    /// #321: a series recreated from its rules is noted under the recorded series' identifiers
    /// (`noteRecreation`, right after its save), so an older occurrence record of it sees its slot held. A rule-less
    /// snapshot of one occurrence (the whole-series delete of an occurrence edited on its own,
    /// addressed by its own identifier: PR #318 round 3, finding 22) is guarded as an occurrence
    /// record is: nothing is written when the series holds its slot again.
    static func undoDeleteEvent<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, calendar: Store.Calendar,
                                                                    in store: Store) throws -> (text: String, outcome: UndoEventOutcome?) {
        if !snapshot.restoresFromRules, let origin = snapshot.occurrenceOrigin,
           seriesHoldsSlot(origin, length: slotLength(of: snapshot), calendar: calendar, in: store) {
            return held(snapshot, origin)
        }
        let event = store.makeEvent()
        store.apply(snapshot, to: event, calendar: calendar)
        try store.save(event)
        store.markNeedsRefresh()
        // PR #494 round 3: noted right after the save, before the restore, so a series that
        // `rollbackFailed` leaves in place is linked too (the title match before #321 saw it). A
        // rolled-back series leaves a link to a series that no longer exists, which holds nothing.
        if snapshot.restoresFromRules, let recorded = snapshot.seriesIdentity {
            store.noteRecreation(of: recorded, as: store.identifiers(of: event))
        }
        var outcome: SeriesExceptionsRestorer.Outcome?
        if snapshot.restoresFromRules, let exceptions = snapshot.exceptions {
            outcome = try restore(exceptions, of: event, in: store)
        }
        let text = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: store.identifiers(of: event).eventIdentifier ?? "unknown",
                                                      exceptionsOutcome: outcome)
        // PR #494 round 1: an occurrence's record that could not name its series says so, as
        // `.deleteOccurrence` does; round 2: and returns it as the outcome, so a batch says it too.
        if !snapshot.restoresFromRules, snapshot.isOccurrenceRecord {
            guard snapshot.occurrenceOrigin != nil else {
                return (text + ". " + UndoOperation.occurrenceSlotUncheckedNote, .occurrenceOneOffSlotUnchecked(notCarriedOver: []))
            }
            return (text, .occurrenceOneOff(notCarriedOver: []))
        }
        guard snapshot.restoresFromRules else { return (text, nil) }
        return (text, outcome.map(UndoEventOutcome.seriesWithExceptions) ?? .seriesFromRules)
    }

    /// The undo of `.deleteOccurrence`. #244: the snapshot holds no rules, so the occurrence comes
    /// back as a one-off event at its slot, beside what is left of the series (EventKit cannot put
    /// it back in). #285: not when the series already holds the slot (it was recreated from its
    /// rules by an undo of the whole-series delete, which brings every slot back). #321: "the series"
    /// is the recorded one or one undo recreated from it, and "the slot" its rule slot; a record
    /// without them (`occurrenceOrigin` nil) writes the one-off, and its text says the slot was not
    /// checked.
    /// `calendar` is the recorded one, read once by the caller with `.recreateDeletedOccurrence`
    /// before the slot check and the write (#269 verify; `EventKitManager.undoDeletedOccurrence`).
    /// Returns the text and what the undo did (#323).
    static func undoDeleteOccurrence<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, notCarriedOver: [String],
                                                                         calendar: Store.Calendar, in store: Store) throws -> (text: String, outcome: UndoEventOutcome) {
        if let origin = snapshot.occurrenceOrigin,
           seriesHoldsSlot(origin, length: slotLength(of: snapshot), calendar: calendar, in: store) {
            return held(snapshot, origin)
        }
        let event = store.makeEvent()
        store.apply(snapshot, to: event, calendar: calendar)
        try store.save(event)
        store.markNeedsRefresh()
        let text = UndoOperation.occurrenceRestoredMessage(title: snapshot.title, newID: store.identifiers(of: event).eventIdentifier ?? "unknown",
                                                           notCarriedOver: notCarriedOver)
        // Round 2: the unchecked slot travels in the outcome, so a batch says it too.
        guard snapshot.occurrenceOrigin != nil else {
            return (text + ". " + UndoOperation.occurrenceSlotUncheckedNote, .occurrenceOneOffSlotUnchecked(notCarriedOver: notCarriedOver))
        }
        return (text, .occurrenceOneOff(notCarriedOver: notCarriedOver))
    }
}
