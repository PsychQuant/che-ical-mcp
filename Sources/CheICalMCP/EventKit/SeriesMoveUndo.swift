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

    /// - nothing resolved and nothing stored: nil, which `UndoTargetCheck` reports as not found;
    /// - nothing resolved but the series object stored (no stand-in): the residual not-found;
    /// - a stand-in still in the recorded destination whose way back leaves the account (or an
    ///   account is unknown): refused as the forward move refuses it (`refusesMoveThroughStandIn`),
    ///   and kept, since it is not one of the spec's discard scenarios;
    /// - otherwise the resolved event. A stand-in that left the destination goes on to the
    ///   comparison, which reports the changed calendar; a missing original calendar is refused by
    ///   the move arm (`calendarNotFound`).
    static func decide<Event>(_ expected: UndoPostState, verb: UndoHistoryVerb, stored: Bool,
                              resolved: Resolved<Event>?, original: OriginalCalendar?) throws -> Event? {
        guard let resolved else {
            guard stored else { return nil }
            throw UndoTargetMissingError(verb: verb, kind: expected.kind, title: expected.title,
                                         hasIdentifier: !expected.itemID.isEmpty, seriesWithoutStandIn: true)
        }
        if case .eventCalendar(_, _, let destination, _) = expected,
           resolved.calendarID == destination,
           let original,
           FirstRemainingOccurrence.refusesMoveThroughStandIn(
               viaStandIn: resolved.viaStandIn, wholeSeries: true,
               acrossAccounts: FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: resolved.sourceID,
                                                                            toSourceID: original.sourceID)) {
            throw EventKitError.standInRefused(reason: EventKitManager.standInUndoAccountReason)
        }
        return resolved.event
    }
}
