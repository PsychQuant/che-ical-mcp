import Foundation

/// #285: the exceptions of a recurring series that a whole-series delete would otherwise lose:
/// occurrences deleted on their own (their slot is simply absent) and occurrences edited on their
/// own (detached). EventKit has no API to read either as such, so they are recorded as the set of
/// slots that existed, read from the occurrences themselves before the delete removes anything.
struct SeriesExceptions {
    /// The scan window the occurrences were listed over (`UndoPostState.seriesScanWindow`).
    /// Nothing outside it was seen, so nothing outside it is restored or removed.
    let window: DateInterval
    /// Slots, inside `window`, of the occurrences that existed and were not edited on their own.
    let keptSlots: [Date]
    /// Occurrences edited on their own, inside `window`, each with the slot its rule gave it.
    let detached: [DetachedOccurrence]
}

/// An occurrence edited on its own: undo recreates it as a one-off event (EventKit cannot put an
/// edited occurrence back into its series; #244 D1 precedent).
struct DetachedOccurrence {
    /// The start the series' rule gave this occurrence, from the `/RID=` of its identifier (#311).
    let slot: Date
    /// The occurrence's own fields, without recurrence rules.
    let snapshot: EventSnapshot
}

/// The two decisions of the restore, as pure functions over values read from EventKit.
enum SeriesExceptionsPlanner {
    /// One occurrence as the enumeration of the series' window reports it.
    struct ObservedOccurrence {
        let ids: UndoPostState.OccurrenceIDs
        let isDetached: Bool
        let occurrenceDate: Date?
        let startDate: Date
        /// The occurrence as an `EventSnapshot` without rules (used for a detached one).
        let snapshot: EventSnapshot
    }

    /// The ranges to LIST occurrences over: the window, and a year on each side of it, as three
    /// separate queries. An occurrence edited on its own is matched by its current (edited) time,
    /// not by its rule slot, so listing only the window loses one that was moved out of it (PR #318
    /// verify B1). The four-year limit of an EventKit predicate applies to each query, so the
    /// margins do not depend on the window's length (round 2, A: open-ended and count-based rules
    /// give a 1460-day window, which left no margin when the limit was applied to the whole listing).
    /// One moved more than a year past the window is still not seen; the undo text says so.
    static func listingRanges(for window: DateInterval) -> [DateInterval] {
        let margin: TimeInterval = 366 * 86_400
        return [window,
                DateInterval(start: window.start.addingTimeInterval(-margin), end: window.start),
                DateInterval(start: window.end, end: window.end.addingTimeInterval(margin))]
    }

    /// Splits what was listed into the slots that stay and the occurrences edited on their own.
    /// Occurrences of other series (same calendar, same range) are ignored. Everything is judged
    /// by RULE SLOT against `window`, never by where an occurrence currently sits: a slot outside
    /// the window is left to the rule (an edited occurrence there is not restored as a one-off, or
    /// the rule's own occurrence outside the window would be duplicated).
    ///
    /// Nil when no occurrence of the series was listed at all: an empty listing is not "the series
    /// had no exceptions", and treating it so would make every generated slot surplus on undo
    /// (round 2, B).
    static func capture(_ observed: [ObservedOccurrence], of series: UndoPostState.OccurrenceIDs,
                        window: DateInterval) -> SeriesExceptions? {
        var kept: [Date] = []
        var detached: [DetachedOccurrence] = []
        var sawSeries = false
        for occurrence in observed where UndoPostState.isOccurrence(occurrence.ids, of: series) {
            sawSeries = true
            if occurrence.isDetached {
                let slot = UndoPostState.originalSlot(eventIdentifier: occurrence.ids.eventIdentifier,
                                                      externalIdentifier: occurrence.ids.externalIdentifier,
                                                      occurrenceDate: occurrence.occurrenceDate) ?? occurrence.startDate
                if window.contains(slot) { detached.append(DetachedOccurrence(slot: slot, snapshot: occurrence.snapshot)) }
            } else {
                let slot = occurrence.occurrenceDate ?? occurrence.startDate
                if window.contains(slot) { kept.append(slot) }
            }
        }
        guard sawSeries else { return nil }
        return SeriesExceptions(window: window, keptSlots: kept.sorted(),
                                detached: detached.sorted { $0.slot < $1.slot })
    }

    /// The slots of the recreated series (`generated`) that undo must remove: inside the window
    /// and not the slot of an occurrence that existed and was not edited on its own. A detached
    /// occurrence's slot is not in `keptSlots`, so it is removed here and comes back as a one-off.
    /// Slots outside the window are left to the series' rule: they were never listed.
    /// Slots compare as instants, to the second (`UndoPostState.sameInstant`).
    static func surplusSlots(generated: [Date], exceptions: SeriesExceptions) -> [Date] {
        generated.filter { slot in
            exceptions.window.contains(slot)
                && !exceptions.keptSlots.contains { UndoPostState.sameInstant($0, slot) }
        }
    }
}

/// Why restoring a series' exceptions stopped (#285). Every case but `rollbackFailed` means the
/// recreated series and anything created for the exceptions were deleted again, so nothing of the
/// restore is left and the undo can be retried. `rollbackFailed` means the compensating delete
/// itself failed: the series exists, with some exceptions applied.
enum SeriesExceptionsRestoreError: Error, Equatable {
    /// A surplus slot could not be found among the recreated series' occurrences. Nothing was removed.
    case surplusUnresolved(Date)
    /// Removing the surplus occurrence at this slot failed.
    case removeFailed(Date)
    /// Recreating the occurrence edited on its own at this slot failed.
    case oneOffFailed(Date)
    /// The compensating delete failed after one of the above; `exclusionsApplied` surplus
    /// occurrences had been removed by then.
    case rollbackFailed(exclusionsApplied: Int)
    /// The recreated series was deleted again, but a one-off event created for an exception could
    /// not be removed: it remains in the calendar (round 2, C).
    case strayOneOffs(Date)
    /// The recreated series was deleted again; a one-off whose save threw may or may not have been
    /// written and could not be removed, so it may remain.
    case oneOffMaybeLeft(Date)
}

/// A one-off save that threw after the store may have taken the write: the closure hands the
/// event back so the restore can clean it up (PR #318 verify B3).
struct SeriesExceptionsOneOffWriteFailed<OneOff>: Error {
    let possiblyWritten: OneOff
}

/// The restore after undo recreated a series from its rules: remove the surplus slots, then
/// recreate the occurrences edited on their own as one-off events, all or nothing. EventKit is
/// behind closures (the `ExclusionExecutor` seam of #182), so the sequence is tested without it.
enum SeriesExceptionsRestorer {
    struct Outcome: Equatable {
        /// Surplus occurrences removed that were deleted on their own before the series delete.
        let stayedDeleted: Int
        /// Occurrences edited on their own that came back as one-off events.
        let oneOffs: Int
        /// The series' first occurrence was an exception (edited or deleted on its own) but the
        /// restored series keeps it from the rule: removing it would remove the series' anchor
        /// (#182 forbids excluding it; on iCloud the id stops resolving, #284).
        var firstOccurrenceKeptFromRule: Bool = false
        /// The recorded exceptions did not match the recreated series (empty listing, a recorded
        /// slot the series does not generate, or no slot at the series' own start), so none was
        /// applied and the series stands as the rules made it (round 2, B).
        var notApplied: Bool = false
    }

    /// `generated` lists the recreated series' occurrences inside `exceptions.window`, as
    /// EventKit expanded the rules; `seriesStart` is the start of the recreated series itself.
    /// Throws `SeriesExceptionsRestoreError`.
    static func restore<Occurrence, OneOff>(
        exceptions: SeriesExceptions,
        seriesStart: Date,
        generated: [(slot: Date, occurrence: Occurrence)],
        remove: (Occurrence) throws -> Void,
        createOneOff: (DetachedOccurrence) throws -> OneOff,
        removeOneOff: (OneOff) throws -> Void,
        rollbackSeries: () throws -> Void
    ) throws -> Outcome {
        // Nothing is removed or created unless the record and the recreated series describe the
        // same series: every recorded slot is generated, and so is the series' own first slot.
        let generatedSlots = generated.map(\.slot)
        func isGenerated(_ slot: Date) -> Bool { generatedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        guard isGenerated(seriesStart), exceptions.keptSlots.allSatisfy(isGenerated) else {
            return Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true)
        }
        // The series' first occurrence is its anchor: never removed.
        func isAnchor(_ slot: Date) -> Bool { UndoPostState.sameInstant(seriesStart, slot) }
        let allSurplus = SeriesExceptionsPlanner.surplusSlots(generated: generatedSlots, exceptions: exceptions)
        let surplus = allSurplus.filter { !isAnchor($0) }
        let oneOffsToCreate = exceptions.detached.filter { !isAnchor($0.slot) }
        let firstKept = allSurplus.contains(where: isAnchor)
            || exceptions.detached.contains { isAnchor($0.slot) }

        var exclusionsApplied = 0
        do {
            exclusionsApplied = try ExclusionExecutor.run(
                dates: surplus,
                resolve: { slot in generated.first { UndoPostState.sameInstant($0.slot, slot) }?.occurrence },
                remove: remove,
                rollback: rollbackSeries).count
        } catch let error as ExclusionExecutionError {
            switch error {
            case .noOccurrence(let date): throw SeriesExceptionsRestoreError.surplusUnresolved(date)
            case .removeFailed(let date): throw SeriesExceptionsRestoreError.removeFailed(date)
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
                var confirmedCleaned = true
                for oneOff in created {
                    do { try removeOneOff(oneOff) } catch { confirmedCleaned = false }
                }
                var uncertainCleaned = true
                if let uncertain { do { try removeOneOff(uncertain) } catch { uncertainCleaned = false } }
                var seriesRemoved = true
                do { try rollbackSeries() } catch { seriesRemoved = false }
                if !seriesRemoved { throw SeriesExceptionsRestoreError.rollbackFailed(exclusionsApplied: exclusionsApplied) }
                if !confirmedCleaned { throw SeriesExceptionsRestoreError.strayOneOffs(detached.slot) }
                if !uncertainCleaned { throw SeriesExceptionsRestoreError.oneOffMaybeLeft(detached.slot) }
                throw SeriesExceptionsRestoreError.oneOffFailed(detached.slot)
            }
        }

        let stayedDeleted = surplus.filter { slot in
            !exceptions.detached.contains { UndoPostState.sameInstant($0.slot, slot) }
        }.count
        return Outcome(stayedDeleted: stayedDeleted, oneOffs: created.count, firstOccurrenceKeptFromRule: firstKept)
    }
}

/// #285: whether an occurrence delete's slot is already held by the recreated series. When a
/// whole-series delete is undone first, the series' rules bring every slot back, so undoing the
/// earlier delete of one occurrence would write a second event there.
enum OccurrenceSlotGuard {
    /// An event found at the slot.
    struct Holder {
        let title: String?
        let startDate: Date
        let hasRecurrenceRules: Bool
    }

    /// True when one of `holders` is an occurrence of a recurring series with this title starting at
    /// this instant (to the second). A one-off at the slot does not count: it is not what the
    /// series' restore brings back, and refusing to write beside it would hide a real second write.
    static func isHeld(title: String, start: Date, by holders: [Holder]) -> Bool {
        holders.contains {
            $0.hasRecurrenceRules && ($0.title ?? "") == title && UndoPostState.sameInstant($0.startDate, start)
        }
    }
}
