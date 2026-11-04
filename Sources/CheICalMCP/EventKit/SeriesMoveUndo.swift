import Foundation

/// #369: which event the undo of a whole-series move (`.moveEvent(…, isSeries: true)`) writes to,
/// decided from facts the caller reads from the store. Generic over the event, so every branch is
/// tested without EventKit (closure seam, like `UndoTargetCheck` and `ExclusionExecutor`); the
/// EventKit side is `EventKitManager.seriesMoveUndoTarget`.
enum SeriesMoveUndo {
    /// The series resolved as `moveEvent` resolved it (`freshEventWithOrigin`), with the calendar
    /// and account it is in now.
    struct Resolved<Event> {
        let event: Event
        let viaStandIn: Bool
        let calendarID: String?
        let sourceID: String?
    }

    /// The calendar the undo moves the series back to, when it still resolves.
    struct OriginalCalendar {
        let sourceID: String?
    }

    /// The calendar a move-undo moves the series back to: the record's original calendar
    /// (`restoringCalendarIdentifier`), not the destination. Nil for any other post-state.
    static func restoringCalendarID(of expected: UndoPostState) -> String? {
        if case .eventCalendar(_, _, _, let restoring) = expected { return restoring }
        return nil
    }

    /// - nothing resolved: `stored` (asked only then) tells nothing stored, which returns nil and
    ///   `UndoTargetCheck` reports as not found, from a stored series with no stand-in, the
    ///   residual not-found;
    /// - a stand-in still in the recorded destination: refused when the original calendar does
    ///   not resolve (fails closed with the move arm's `calendarNotFound`), and when the way back
    ///   leaves the account or an account is unknown, as the forward move refuses it
    ///   (`refusesMoveThroughStandIn`). Both are kept, since neither is one of the spec's discard
    ///   scenarios;
    /// - otherwise the resolved event. A stand-in that left the destination goes on to the
    ///   comparison, which reports the changed calendar; for the series object itself the move
    ///   arm handles a missing original calendar.
    ///
    /// The stand-in's calendar is read before `UndoTargetCheck` refreshes it a second time. That
    /// is not a gap: `firstRemainingOccurrence` refreshed it just before, and the lookup, the
    /// second refresh and the comparison run synchronously, with no suspension point between them.
    static func decide<Event>(_ expected: UndoPostState, verb: UndoHistoryVerb, stored: () -> Bool,
                              resolved: Resolved<Event>?, original: OriginalCalendar?) throws -> Event? {
        guard let resolved else {
            guard stored() else { return nil }
            throw UndoTargetMissingError(verb: verb, kind: expected.kind, title: expected.title,
                                         hasIdentifier: !expected.itemID.isEmpty, seriesWithoutStandIn: true)
        }
        guard resolved.viaStandIn, case .eventCalendar(_, _, let destination, let restoring) = expected,
              resolved.calendarID == destination else { return resolved.event }
        guard let original else { throw EventKitError.calendarNotFound(identifier: restoring) }
        if FirstRemainingOccurrence.refusesMoveThroughStandIn(
            viaStandIn: true, wholeSeries: true,
            acrossAccounts: FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: resolved.sourceID,
                                                                         toSourceID: original.sourceID)) {
            throw EventKitError.standInRefused(reason: EventKitManager.standInUndoAccountReason)
        }
        return resolved.event
    }
}
