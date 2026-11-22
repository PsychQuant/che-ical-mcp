import EventKit
import Foundation
@testable import CheICalMCP

/// PR #558 fix round 4 (verify findings C1, C10, L14): the undo of a whole-series delete, and of one
/// occurrence's delete, as `main` runs them, so a test runs one sequence through this server's production
/// path and through `main`'s and compares the calendars and answers. Which commit each copy is of:
/// - copied from `main` at 92d9b796: renamed, with calls routed to the matching copies and
///   their comments (left out): the store-level capture (`SeriesExceptionsUndo.capture(of:in:now:)`) with its
///   lister, `recreateDeletedEvent`, `undoDeleteOccurrence`, `seriesHoldsSlot`, `held`, `slotLength`, and
///   `OccurrenceSlotGuard.isHeld` (below, `isHeldOnMain`);
///   The single-window capture inlines main's wrapper.
/// - the planner's capture they call, `SeriesExceptionsPlanner.captureOnMain`, is bdcb8f9e's, the same as
///   92d9b796's;
/// - the store-level restore they call, `SeriesExceptionsUndo.restoreAtBase` (below), is 92d9b796's too
///   (PR #558 fix round 5, verify finding Q4: round 4 called ba98641's scan-based `restoreOnMain`, which
///   stays as the older oracle of `UndoSlotComparisonEquivalenceTests`).
/// They share with production what neither side changed: `SeriesExceptionsPlanner.deleteWindow`,
/// `listingRanges`, `inWindows` and `ruleSlot(of:)`, `UndoPostState.seriesScanWindow`, `isOccurrence` and
/// `sameInstant`, `SeriesExceptionsUndo.restoreFailure`, the texts, `DeleteUndoFollow.removedIdentifier` and the
/// store (PR #558 fix round 4 changes none of them). The old behaviour on purpose: do not update them when the
/// current functions change their answers.
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
            outcome = try SeriesExceptionsUndo.restoreAtBase(exceptions, of: event, in: store)
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

/// PR #558 fix round 5 (verify finding Q4): the store-level restore of a whole-series delete's exceptions
/// as `main` runs it at 92d9b796 (#527's lookups, `DistinctInstants`, `InstantSet`, `InstantIndex`), which
/// `SeriesUndoOnMain.recreateDeletedEvent` calls. Copied without a change but the names (`…AtBase`) and the
/// comments (left out): `SeriesExceptionsUndo.restore` with its rollback, `SeriesExceptionsRestorer.restore`
/// and `SeriesExceptionsPlanner.surplusSlots`. The scan-based copies of ba98641 (`restoreOnMain`,
/// `surplusSlotsOnMain`) stay as the older oracle of `UndoSlotComparisonEquivalenceTests`. The old behaviour
/// on purpose: do not update these when the current functions change their answers.
extension SeriesExceptionsUndo {
    static func restoreAtBase<Store: SeriesExceptionsStoreSource>(_ exceptions: SeriesExceptions, of restored: Store.Event,
                                                            in store: Store) throws -> SeriesExceptionsRestorer.Outcome {
        let restoredIDs = store.identifiers(of: restored)
        guard let id = restoredIDs.eventIdentifier, !id.isEmpty, store.hasCalendar(restored) else {
            try rollbackRestoredSeriesAtBase(restored, exclusionsApplied: 0, in: store)
            throw EventKitError.seriesExceptionsRestoreFailed(
                reason: "Undo could not restore the exceptions of the recreated series (it has no identifier). The series was deleted again; nothing was restored. Retry undo.")
        }
        let seriesIDs = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: restoredIDs.externalIdentifier)
        var generated: [(slot: Date, occurrence: Store.Event)] = []
        var taken = DistinctInstants()
        for window in exceptions.windows {
            for occurrence in store.events(in: window, inCalendarOf: restored)
            where UndoPostState.isOccurrence(store.identifiers(of: occurrence), of: seriesIDs) {
                let slot = store.slot(of: occurrence)
                if taken.insert(slot) { generated.append((slot, occurrence)) }
            }
        }
        do {
            return try SeriesExceptionsRestorer.restoreAtBase(
                exceptions: exceptions, seriesStart: store.startDate(of: restored), generated: generated,
                remove: { try store.remove($0, span: .thisEvent) },
                createOneOff: { detached in
                    let oneOff = store.makeEvent()
                    do {
                        let calendar = try store.calendarNow(for: detached.snapshot, kind: .recreateDeleted)
                        store.apply(detached.snapshot, to: oneOff, calendar: calendar)
                        try store.save(oneOff)
                        return oneOff
                    } catch {
                        throw SeriesExceptionsOneOffWriteFailed(possiblyWritten: oneOff, underlying: error)
                    }
                },
                removeOneOff: { oneOff in
                    guard try store.isStored(oneOff) else { return }
                    try store.remove(oneOff, span: .thisEvent)
                },
                rollbackSeries: { try store.remove(restored, span: .futureEvents) })
        } catch let error as SeriesExceptionsRestoreError {
            store.markNeedsRefresh()
            throw restoreFailure(error)
        }
    }

    private static func rollbackRestoredSeriesAtBase<Store: SeriesExceptionsStoreSource>(_ restored: Store.Event, exclusionsApplied: Int,
                                                                                  in store: Store) throws {
        do { try store.remove(restored, span: .futureEvents); store.markNeedsRefresh() } catch {
            throw restoreFailure(.rollbackFailed(exclusionsApplied: exclusionsApplied))
        }
    }
}

extension SeriesExceptionsRestorer {
    static func restoreAtBase<Occurrence, OneOff>(
        exceptions: SeriesExceptions,
        seriesStart: Date,
        generated: [(slot: Date, occurrence: Occurrence)],
        remove: (Occurrence) throws -> Void,
        createOneOff: (DetachedOccurrence) throws -> OneOff,
        removeOneOff: (OneOff) throws -> Void,
        rollbackSeries: () throws -> Void
    ) throws -> Outcome {
        let generatedSlots = generated.map(\.slot)
        let generatedSet = InstantSet(generatedSlots)
        let generatedIndex = InstantIndex(generatedSlots)
        func isGenerated(_ slot: Date) -> Bool { generatedSet.contains(slot) }
        let firstSlotChecked = SeriesExceptionsPlanner.inWindows(seriesStart, exceptions.windows)
        guard !firstSlotChecked || isGenerated(seriesStart), exceptions.keptSlots.allSatisfy(isGenerated),
              exceptions.detached.allSatisfy({ isGenerated($0.slot) }) else {
            return Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true)
        }
        func isAnchor(_ slot: Date) -> Bool { UndoPostState.sameInstant(seriesStart, slot) }
        let allSurplus = SeriesExceptionsPlanner.surplusSlotsAtBase(generated: generatedSlots, exceptions: exceptions)
        let surplus = allSurplus.filter { !isAnchor($0) }
        let oneOffsToCreate = exceptions.detached.filter { !isAnchor($0.slot) }
        let firstKept = allSurplus.contains(where: isAnchor)
            || exceptions.detached.contains { isAnchor($0.slot) }

        var exclusionsApplied = 0
        var removeError: Error?
        do {
            exclusionsApplied = try ExclusionExecutor.run(
                dates: surplus,
                resolve: { slot in generatedIndex.firstPosition(sameInstantAs: slot).map { generated[$0].occurrence } },
                remove: { occurrence in
                    do { try remove(occurrence) } catch { removeError = error; throw error }
                },
                rollback: rollbackSeries).count
        } catch let error as ExclusionExecutionError {
            switch error {
            case .noOccurrence(let date): throw SeriesExceptionsRestoreError.surplusUnresolved(date)
            case .removeFailed(let date):
                let code = removeError.map { failureCode($0, oneOff: OneOff.self) } ?? "error_unknown"
                throw SeriesExceptionsRestoreError.removeFailed(date, code: code)
            case .rollbackFailed(let applied): throw SeriesExceptionsRestoreError.rollbackFailed(exclusionsApplied: applied.count)
            }
        }

        var created: [OneOff] = []
        for detached in oneOffsToCreate {
            do {
                created.append(try createOneOff(detached))
            } catch {
                let uncertain = (error as? SeriesExceptionsOneOffWriteFailed<OneOff>)?.possiblyWritten
                let code = failureCode(error, oneOff: OneOff.self)
                var confirmedCleaned = true
                for oneOff in created {
                    do { try removeOneOff(oneOff) } catch { confirmedCleaned = false }
                }
                var uncertainCleaned = true
                if let uncertain { do { try removeOneOff(uncertain) } catch { uncertainCleaned = false } }
                var seriesRemoved = true
                do { try rollbackSeries() } catch { seriesRemoved = false }
                if !seriesRemoved { throw SeriesExceptionsRestoreError.rollbackFailed(exclusionsApplied: exclusionsApplied) }
                if !confirmedCleaned { throw SeriesExceptionsRestoreError.strayOneOffs(detached.slot, code: code) }
                if !uncertainCleaned { throw SeriesExceptionsRestoreError.oneOffMaybeLeft(detached.slot, code: code) }
                throw SeriesExceptionsRestoreError.oneOffFailed(detached.slot, code: code)
            }
        }

        let detachedSet = InstantSet(exceptions.detached.map(\.slot))
        let stayedDeleted = surplus.filter { !detachedSet.contains($0) }.count
        return Outcome(stayedDeleted: stayedDeleted, oneOffs: created.count, firstOccurrenceKeptFromRule: firstKept)
    }
}

extension SeriesExceptionsPlanner {
    static func surplusSlotsAtBase(generated: [Date], exceptions: SeriesExceptions) -> [Date] {
        let kept = InstantSet(exceptions.keptSlots)
        return generated.filter { slot in
            SeriesExceptionsPlanner.inWindows(slot, exceptions.windows) && !kept.contains(slot)
        }
    }
}
