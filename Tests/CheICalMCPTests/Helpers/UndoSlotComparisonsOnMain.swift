import EventKit
import Foundation
@testable import CheICalMCP

/// #527: the functions of the undo paths that compare slots, as they were on `main` at ba98641,
/// before their scans (`contains { sameInstant }`, `first { sameInstant }`) were replaced by
/// `InstantSet`, `InstantIndex` and `DistinctInstants`. Each is copied without a change but its name
/// and the names of the copies it calls (`surplusSlotsOnMain`, `sameSlotsOnMain`,
/// `restoreOnMain`, `rollbackRestoredSeriesOnMain`), so no copy reaches a new helper; they run beside
/// the current functions over the same inputs (`UndoSlotComparisonEquivalenceTests`). They are the
/// old behaviour, kept on purpose: do not update them when the current functions change their
/// answers; drop the comparison then.
extension SeriesExceptionsPlanner {
    static func surplusSlotsOnMain(generated: [Date], exceptions: SeriesExceptions) -> [Date] {
        generated.filter { slot in
            SeriesExceptionsPlanner.inWindows(slot, exceptions.windows)
                && !exceptions.keptSlots.contains { UndoPostState.sameInstant($0, slot) }
        }
    }
}

extension SeriesExceptionsRestorer {
    static func restoreOnMain<Occurrence, OneOff>(
        exceptions: SeriesExceptions,
        seriesStart: Date,
        generated: [(slot: Date, occurrence: Occurrence)],
        remove: (Occurrence) throws -> Void,
        createOneOff: (DetachedOccurrence) throws -> OneOff,
        removeOneOff: (OneOff) throws -> Void,
        rollbackSeries: () throws -> Void
    ) throws -> Outcome {
        // Nothing is removed or created unless the record and the recreated series describe the
        // same series: every recorded slot (kept and edited) is generated, and so is the series' own first slot.
        let generatedSlots = generated.map(\.slot)
        func isGenerated(_ slot: Date) -> Bool { generatedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        // #319: the window may start after the series' first occurrence (a series begun more than a
        // few years before the delete), where the listing cannot show it; it is required only inside.
        let firstSlotChecked = SeriesExceptionsPlanner.inWindows(seriesStart, exceptions.windows)
        guard !firstSlotChecked || isGenerated(seriesStart), exceptions.keptSlots.allSatisfy(isGenerated),
              exceptions.detached.allSatisfy({ isGenerated($0.slot) }) else {
            return Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true)
        }
        // The series' first occurrence is its anchor: never removed.
        func isAnchor(_ slot: Date) -> Bool { UndoPostState.sameInstant(seriesStart, slot) }
        let allSurplus = SeriesExceptionsPlanner.surplusSlotsOnMain(generated: generatedSlots, exceptions: exceptions)
        let surplus = allSurplus.filter { !isAnchor($0) }
        let oneOffsToCreate = exceptions.detached.filter { !isAnchor($0.slot) }
        let firstKept = allSurplus.contains(where: isAnchor)
            || exceptions.detached.contains { isAnchor($0.slot) }

        var exclusionsApplied = 0
        // The executor reports which slot failed, not why; the removal's error is kept here (#398).
        var removeError: Error?
        do {
            exclusionsApplied = try ExclusionExecutor.run(
                dates: surplus,
                resolve: { slot in generated.first { UndoPostState.sameInstant($0.slot, slot) }?.occurrence },
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
                // Cleaned up apart from the rest: a save that threw may or may not have written,
                // so a failure to remove it proves nothing (round 2, C).
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

        let stayedDeleted = surplus.filter { slot in
            !exceptions.detached.contains { UndoPostState.sameInstant($0.slot, slot) }
        }.count
        return Outcome(stayedDeleted: stayedDeleted, oneOffs: created.count, firstOccurrenceKeptFromRule: firstKept)
    }
}

extension SeriesExceptionsUndo {
    static func restoreOnMain<Store: SeriesExceptionsStoreSource>(_ exceptions: SeriesExceptions, of restored: Store.Event,
                                                            in store: Store) throws -> SeriesExceptionsRestorer.Outcome {
        let restoredIDs = store.identifiers(of: restored)
        guard let id = restoredIDs.eventIdentifier, !id.isEmpty, store.hasCalendar(restored) else {
            try rollbackRestoredSeriesOnMain(restored, exclusionsApplied: 0, in: store)
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
            return try SeriesExceptionsRestorer.restoreOnMain(
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

    private static func rollbackRestoredSeriesOnMain<Store: SeriesExceptionsStoreSource>(_ restored: Store.Event, exclusionsApplied: Int,
                                                                                  in store: Store) throws {
        do { try store.remove(restored, span: .futureEvents); store.markNeedsRefresh() } catch {
            throw restoreFailure(.rollbackFailed(exclusionsApplied: exclusionsApplied))
        }
    }
}

extension SeriesUpdateUndo {
    static func occurrencesFollowOrKeepOnMain(before: SeriesExceptions, after: SeriesExceptions, old: EventSnapshot,
                                        written: [String: String], fields: [String]) -> Bool {
        guard fields.allSatisfy({ written[$0] != nil }) else { return false }
        guard before.detached.count == after.detached.count else { return false }
        // Verify r2 (4a): the same plain occurrences too, so a deletion or a return between the two
        // listings keeps the marker instead of being found only by the read-back after the undo writes.
        guard sameSlotsOnMain(before.keptSlots, after.keptSlots) else { return false }
        if fields.contains("location"), before.detached.contains(where: { $0.snapshot.structuredLocationLat != nil }) { return false }
        for was in before.detached {
            guard let now = after.detached.first(where: { UndoPostState.sameInstant($0.slot, was.slot) }) else { return false }
            var changed = Set(changedFields(was.snapshot, now.snapshot))
            // Verify r2: EventKit couples a location string with the place title, so a place without
            // coordinates whose title is the location string on both sides moved with `location`.
            if fields.contains("location"), placeIsLocation(was.snapshot), placeIsLocation(now.snapshot) {
                changed.remove("structured_location")
            }
            guard changed.isSubset(of: Set(fields)) else { return false }
            for field in fields {
                guard let b = normalised(field, was.snapshot), let a = normalised(field, now.snapshot),
                      let o = normalised(field, old), let n = written[field] else { return false }
                let follows = b == o && a == n
                let keeps = b == a && b != n && b != o
                guard follows != keeps else { return false }
            }
        }
        return true
    }

    static func sameSlotsOnMain(_ a: [Date], _ b: [Date]) -> Bool {
        a.count == b.count && a.allSatisfy { slot in b.contains { UndoPostState.sameInstant($0, slot) } }
    }

    static func diffOnMain(recorded: SeriesExceptions, current: SeriesExceptions) -> ExceptionsDiff {
        var result = ExceptionsDiff()
        guard recorded.windows == current.windows else {
            result.otherWindows = true
            return result
        }
        func contains(_ slots: [Date], _ slot: Date) -> Bool { slots.contains { UndoPostState.sameInstant($0, slot) } }
        func detached(_ list: [DetachedOccurrence], at slot: Date) -> DetachedOccurrence? {
            list.first { UndoPostState.sameInstant($0.slot, slot) }
        }
        let recordedSlots = recorded.keptSlots + recorded.detached.map(\.slot)
        let currentSlots = current.keptSlots + current.detached.map(\.slot)
        for slot in recordedSlots where !contains(currentSlots, slot) { result.deleted.append(slot) }
        for slot in currentSlots where !contains(recordedSlots, slot) { result.added.append(slot) }
        for slot in recordedSlots where contains(currentSlots, slot) {
            switch (detached(recorded.detached, at: slot), detached(current.detached, at: slot)) {
            case (nil, nil): continue
            case let (was?, now?):
                if !changedFields(was.snapshot, now.snapshot).isEmpty { result.edited.append(slot) }
            default:
                result.edited.append(slot)
            }
        }
        result.deleted.sort()
        result.added.sort()
        result.edited.sort()
        return result
    }
}
