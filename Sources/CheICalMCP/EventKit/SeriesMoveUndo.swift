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

    /// #511: the undo of a whole-series move whose way back crosses accounts is a create plus a delete,
    /// as the forward move is, so #503's verdict (`verdict`, read only here) must be `none`; otherwise
    /// the refusal text, naming the record's `title`. A redo of a move does not write; a one-off has no
    /// deletions; within one account the move kept them (measured). An unknown account counts as across
    /// (`movesAcrossAccounts`).
    static func deletedOccurrenceRefusal(isSeries: Bool, verb: UndoHistoryVerb, acrossAccounts: Bool, title: String,
                                         verdict: () throws -> DeletedOccurrenceCheck.Verdict) rethrows -> String? {
        guard isSeries, verb == .undo, acrossAccounts else { return nil }
        let result = try verdict()
        // #506 verify r1 (item 10): exhaustive, so a later horizon here is not read as no deletion.
        switch result {
        case .none: return nil
        case .noneThrough, .deleted, .unknown: return DeletedOccurrenceCheck.undoAccountMoveReason(result, title: title)
        }
    }

    /// PR #516 round 1: what #503's verdict lists for the undo of a whole-series move. A move made
    /// through an occurrence's own id (#426) records that id, whose object has no rules of its own, so
    /// the series behind it is listed under the part before `/RID=` (`seriesOf`), as the forward move
    /// does. nil when that series cannot be named or read, which the caller refuses as not listed.
    static func verdictTarget<Event>(id: String, isDetached: Bool, resolved: Event,
                                     seriesOf: (String) throws -> Event?) rethrows -> (series: Event, id: String)? {
        guard DetachedOccurrenceSpan.addressesOneOccurrence(identifier: id, isDetached: isDetached) else { return (resolved, id) }
        guard let seriesID = DetachedOccurrenceSpan.seriesIdentifier(of: id), let series = try seriesOf(id) else { return nil }
        return (series, seriesID)
    }

    /// - nothing resolved and nothing stored (`stored` is asked only here): nil, which
    ///   `UndoTargetCheck` reports as not found;
    /// - nothing resolved but the identifier is stored: the residual not-found;
    /// - a stand-in still in the recorded destination: refused when the original calendar does
    ///   not resolve (fails closed with `missingOriginal()`, the record's refusal that the move arm
    ///   throws too, #269; the bare lookup error only for a record that is not a move, which no
    ///   `.eventCalendar` post-state comes from), and when the way back
    ///   leaves the account or an account is unknown, as the forward move refuses it
    ///   (`refusesMoveThroughStandIn`). Both are kept, since neither is one of the spec's discard
    ///   scenarios;
    /// - otherwise the resolved event. A stand-in in a third calendar goes on to the comparison,
    ///   which reports the changed calendar; one already back in the original calendar is accepted
    ///   there. For the series object itself the move arm handles a missing original calendar.
    ///   A post-state other than `.eventCalendar` also falls through here, unchecked: it cannot
    ///   occur, because `resolvesThroughStandIn` is true only for a whole-series move, whose
    ///   post-state is always `.eventCalendar`. Widening that predicate needs a check here.
    ///
    /// The stand-in's calendar is read before `UndoTargetCheck` refreshes it a second time. No
    /// other task of this process can run in between (synchronous, no suspension point), but a
    /// write by another process (Calendar.app, a sync) landing between the two refreshes would be
    /// seen only by the second one. The window is a few lines of code long, so it is accepted
    /// rather than closed by moving the account check into the comparison.
    static func decide<Event>(_ expected: UndoPostState, verb: UndoHistoryVerb, stored: () throws -> Bool,
                              resolved: Resolved<Event>?, original: OriginalCalendar?,
                              missingOriginal: () -> Error?) throws -> Event? {
        guard let resolved else {
            guard try stored() else { return nil }
            throw UndoTargetMissingError(verb: verb, kind: expected.kind, title: expected.title,
                                         hasIdentifier: !expected.itemID.isEmpty, seriesWithoutStandIn: true)
        }
        guard resolved.viaStandIn, case .eventCalendar(_, _, let destination, let restoring) = expected,
              resolved.calendarID == destination else { return resolved.event }
        guard let original else { throw missingOriginal() ?? EventKitError.calendarNotFound(identifier: restoring) }
        if FirstRemainingOccurrence.refusesMoveThroughStandIn(
            viaStandIn: true, wholeSeries: true,
            acrossAccounts: FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: resolved.sourceID,
                                                                         toSourceID: original.sourceID)) {
            throw EventKitError.standInRefused(reason: EventKitManager.standInUndoAccountReason)
        }
        return resolved.event
    }
}
