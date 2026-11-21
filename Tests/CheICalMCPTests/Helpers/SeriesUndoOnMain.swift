import EventKit
import Foundation
@testable import CheICalMCP

/// PR #558 fix round 4 (verify findings C1, C10, L14): the undo of a whole-series delete, and of one
/// occurrence's delete, as `main` runs them, so a test runs one sequence through this server's production
/// path and through `main`'s and compares the calendars and answers. Copied from `main` at 92d9b796
/// (`SeriesExceptionsUndo.capture(of:in:now:)` with its lister, `recreateDeletedEvent`,
/// `undoDeleteOccurrence`, `seriesHoldsSlot`, `held`, `slotLength`; `OccurrenceSlotGuard.isHeld`) without
/// a change but their names, the names of the copies they call and their comments (left out): the planner's capture is
/// `SeriesExceptionsPlanner.captureOnMain` (bdcb8f9e, the same as 92d9b796's) and the store-level restore
/// `SeriesExceptionsUndo.restoreOnMain` (ba98641, before #527 replaced its scans; #538 did not change it;
/// `UndoSlotComparisonEquivalenceTests` compares it with the current one). The shared builders they call
/// (the texts, `DeleteUndoFollow.removedIdentifier`, the store) are production's. The old behaviour on
/// purpose: do not update them when the current functions change their answers.
enum SeriesUndoOnMain {
    static func capture<Store: SeriesExceptionsStoreSource>(of series: Store.Event, in store: Store, now: Date = Date()) -> SeriesExceptions? {
        let ids = store.identifiers(of: series)
        guard let id = ids.eventIdentifier, !id.isEmpty, store.hasCalendar(series) else { return nil }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: ids.externalIdentifier)
        let seriesEnd = store.seriesEnd(of: series)
        let placed = SeriesExceptionsPlanner.deleteWindow(firstStart: store.startDate(of: series), end: seriesEnd,
                                                          deletedAt: now)
        let window = placed.window
        let fromFirst = UndoPostState.seriesScanWindow(firstStart: store.startDate(of: series), ruleEnd: nil)
        if seriesEnd.isCount, window.start > fromFirst.start {
            let both = observedOccurrences(of: series, ids: seriesIDs,
                                           over: SeriesExceptionsPlanner.listingRanges(covering: [window, fromFirst]), in: store)
            let windows = [window, fromFirst]
            guard var exceptions = SeriesExceptionsPlanner.captureOnMain(both, of: seriesIDs, windows: windows) else { return nil }
            exceptions.seriesStartsBeforeWindow = false
            exceptions.seriesContinuesAfterWindow = placed.seriesContinuesAfter
            exceptions.seriesMayContinueAfterWindow = placed.seriesMayContinueAfter
            return exceptions
        }
        let observed = observedOccurrences(of: series, ids: seriesIDs, over: SeriesExceptionsPlanner.listingRanges(for: window), in: store)
        guard var exceptions = SeriesExceptionsPlanner.captureOnMain(observed, of: seriesIDs, windows: [window]) else { return nil }
        exceptions.seriesStartsBeforeWindow = placed.seriesStartsBefore
        exceptions.seriesContinuesAfterWindow = placed.seriesContinuesAfter
        exceptions.seriesMayContinueAfterWindow = placed.seriesMayContinueAfter
        return exceptions
    }

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

    static func seriesHoldsSlot<Store: SeriesExceptionsStoreSource>(_ origin: OccurrenceOrigin, length: TimeInterval,
                                                                    calendar: Store.Calendar, in store: Store) -> Bool {
        OccurrenceSlotGuard.isHeldOnMain(origin, recreatedAs: store.recreations(of: origin.series),
                                         by: store.slotHolders(at: origin.slot, length: length, in: calendar))
    }

    private static func held(_ snapshot: EventSnapshot, _ origin: OccurrenceOrigin) -> (text: String, outcome: UndoEventOutcome) {
        (UndoOperation.occurrenceAlreadyRestoredMessage(title: snapshot.title, edited: origin.edited),
         origin.edited ? .editedOccurrenceAlreadyHeld : .occurrenceAlreadyHeld)
    }

    private static func slotLength(of snapshot: EventSnapshot) -> TimeInterval {
        snapshot.endDate.timeIntervalSince(snapshot.startDate)
    }

    static func recreateDeletedEvent<Store: SeriesExceptionsStoreSource>(_ snapshot: EventSnapshot, calendar: Store.Calendar,
                                                                         in store: Store) throws
        -> (text: String, outcome: UndoEventOutcome?, newID: String?) {
        if !snapshot.restoresFromRules, let origin = snapshot.occurrenceOrigin,
           seriesHoldsSlot(origin, length: slotLength(of: snapshot), calendar: calendar, in: store) {
            let answer = held(snapshot, origin)
            return (answer.text, answer.outcome, nil)
        }
        let event = store.makeEvent()
        store.apply(snapshot, to: event, calendar: calendar)
        try store.save(event)
        store.markNeedsRefresh()
        if snapshot.restoresFromRules, let recorded = snapshot.seriesIdentity {
            store.noteRecreation(of: recorded, as: store.identifiers(of: event))
        }
        var outcome: SeriesExceptionsRestorer.Outcome?
        if snapshot.restoresFromRules, let exceptions = snapshot.exceptions {
            outcome = try SeriesExceptionsUndo.restoreOnMain(exceptions, of: event, in: store)
        }
        let readID = store.identifiers(of: event).eventIdentifier
        let text = UndoOperation.eventRestoredMessage(snapshot: snapshot, newID: readID ?? "unknown",
                                                      exceptionsOutcome: outcome)
        let newID = readID.map { DeleteUndoFollow.removedIdentifier(eventIdentifier: $0, hasRules: snapshot.restoresFromRules) }
        if !snapshot.restoresFromRules, snapshot.isOccurrenceRecord {
            guard snapshot.occurrenceOrigin != nil else {
                return (text + ". " + UndoOperation.occurrenceSlotUncheckedNote, .occurrenceOneOffSlotUnchecked(notCarriedOver: []), newID)
            }
            return (text, .occurrenceOneOff(notCarriedOver: []), newID)
        }
        guard snapshot.restoresFromRules else { return (text, nil, newID) }
        return (text, outcome.map(UndoEventOutcome.seriesWithExceptions) ?? .seriesFromRules, newID)
    }

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
        guard snapshot.occurrenceOrigin != nil else {
            return (text + ". " + UndoOperation.occurrenceSlotUncheckedNote, .occurrenceOneOffSlotUnchecked(notCarriedOver: notCarriedOver))
        }
        return (text, .occurrenceOneOff(notCarriedOver: notCarriedOver))
    }
}

extension OccurrenceSlotGuard {
    /// `main`'s `isHeld` at 92d9b796 (see `SeriesUndoOnMain`).
    static func isHeldOnMain(_ origin: OccurrenceOrigin, recreatedAs recreated: [UndoPostState.OccurrenceIDs],
                             by holders: [SeriesHolder]) -> Bool {
        let series = [origin.series] + recreated
        return holders.contains { holder in
            UndoPostState.sameInstant(holder.slot, origin.slot)
                && series.contains { UndoPostState.isOccurrence(holder.ids, of: $0) }
        }
    }
}
