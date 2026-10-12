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

    /// Splits what was listed into the slots that stay and the occurrences edited on their own.
    /// Occurrences of other series (same calendar, same window) are ignored.
    static func capture(_ observed: [ObservedOccurrence], of series: UndoPostState.OccurrenceIDs,
                        window: DateInterval) -> SeriesExceptions {
        var kept: [Date] = []
        var detached: [DetachedOccurrence] = []
        for occurrence in observed where UndoPostState.isOccurrence(occurrence.ids, of: series) {
            if occurrence.isDetached {
                let slot = UndoPostState.originalSlot(eventIdentifier: occurrence.ids.eventIdentifier,
                                                      externalIdentifier: occurrence.ids.externalIdentifier,
                                                      occurrenceDate: occurrence.occurrenceDate) ?? occurrence.startDate
                detached.append(DetachedOccurrence(slot: slot, snapshot: occurrence.snapshot))
            } else {
                kept.append(occurrence.occurrenceDate ?? occurrence.startDate)
            }
        }
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
    }

    /// `generated` lists the recreated series' occurrences inside `exceptions.window`, as
    /// EventKit expanded the rules. Throws `SeriesExceptionsRestoreError`.
    static func restore<Occurrence, OneOff>(
        exceptions: SeriesExceptions,
        generated: [(slot: Date, occurrence: Occurrence)],
        remove: (Occurrence) throws -> Void,
        createOneOff: (DetachedOccurrence) throws -> OneOff,
        removeOneOff: (OneOff) throws -> Void,
        rollbackSeries: () throws -> Void
    ) throws -> Outcome {
        let surplus = SeriesExceptionsPlanner.surplusSlots(generated: generated.map(\.slot), exceptions: exceptions)
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
        for detached in exceptions.detached {
            do {
                created.append(try createOneOff(detached))
            } catch {
                var cleanedUp = true
                for oneOff in created {
                    do { try removeOneOff(oneOff) } catch { cleanedUp = false }
                }
                do { try rollbackSeries() } catch { cleanedUp = false }
                throw cleanedUp ? SeriesExceptionsRestoreError.oneOffFailed(detached.slot)
                                : SeriesExceptionsRestoreError.rollbackFailed(exclusionsApplied: exclusionsApplied)
            }
        }

        let stayedDeleted = surplus.filter { slot in
            !exceptions.detached.contains { UndoPostState.sameInstant($0.slot, slot) }
        }.count
        return Outcome(stayedDeleted: stayedDeleted, oneOffs: created.count)
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
