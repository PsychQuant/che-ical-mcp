import Foundation

/// #285: the exceptions of a recurring series that a whole-series delete would otherwise lose:
/// occurrences deleted on their own (their slot is simply absent) and occurrences edited on their
/// own (detached). EventKit has no API to read either as such, so they are recorded as the set of
/// slots that existed, read from the occurrences themselves before the delete removes anything.
struct SeriesExceptions {
    /// The window the occurrences were listed over (`SeriesExceptionsPlanner.deleteWindow`, #319).
    /// Nothing outside it was seen, so nothing outside it is restored or removed.
    let window: DateInterval
    /// Slots, inside `window`, of the occurrences that existed and were not edited on their own.
    let keptSlots: [Date]
    /// Occurrences edited on their own, inside `window`, each with the slot its rule gave it.
    let detached: [DetachedOccurrence]
    /// #319: the series has occurrences before `window` (it began more than a year before the
    /// delete), which come back from the rules alone.
    var seriesStartsBeforeWindow: Bool = false
    /// #319: the series has, or may have, occurrences after `window` (open-ended, count-based, or a
    /// rule that ends later), which come back from the rules alone.
    var seriesContinuesAfterWindow: Bool = false
    /// #319 r1: the series may have occurrences after `window` (see `DeleteWindow`).
    var seriesMayContinueAfterWindow: Bool = false
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
    /// #319: the window a whole-series delete lists the series' exceptions over, and whether the
    /// series reaches past it on either side.
    struct DeleteWindow: Equatable {
        let window: DateInterval
        let seriesStartsBefore: Bool
        let seriesContinuesAfter: Bool
        /// #319 r1: the series may have occurrences after the window (a count bound past it, or a
        /// count whose end cannot be shown); false when `seriesContinuesAfter`.
        var seriesMayContinueAfter: Bool = false
    }

    /// #319 r1: how a series ends, as far as its rules show.
    enum SeriesEnd: Equatable {
        /// An open-ended rule: the series goes on.
        case open
        /// Every rule has an end date; the latest.
        case endsAt(Date)
        /// A count rule (with or without end dates beside it): the latest slot it can reach
        /// (`DetachedOccurrenceSpan.lastPossibleSlot`), an upper bound.
        case endsBy(Date)
        /// A count rule whose end cannot be shown (a filter, a day after the 28th).
        case unknown
    }

    /// How `rules` end, from `firstStart` (`calendar` in the event's zone): any open-ended rule
    /// makes the series open; else any count whose end cannot be shown makes it unknown; else the
    /// latest of the end dates and the counts' last possible slots
    /// (`DetachedOccurrenceSpan.lastPossibleSlot`, an upper bound), `endsBy` when a count is among
    /// them. Before PR #494 round 1 a count was read as open-ended (`UndoPostState.seriesRuleEnd`),
    /// which placed the window of a count series that ended long ago after its last occurrence.
    static func seriesEnd(rules: [DetachedOccurrenceSpan.RuleExtent], firstStart: Date, calendar: Calendar) -> SeriesEnd {
        guard !rules.isEmpty else { return .open }
        if rules.contains(where: { $0.endDate == nil && $0.occurrenceCount <= 0 }) { return .open }
        var latest: Date?
        var counted = false
        for rule in rules {
            guard let last = DetachedOccurrenceSpan.lastPossibleSlot(of: rule, firstStart: firstStart, calendar: calendar) else { return .unknown }
            if rule.endDate == nil { counted = true }
            latest = latest.map { max($0, last) } ?? last
        }
        guard let latest else { return .open }
        return counted ? .endsBy(latest) : .endsAt(latest)
    }

    /// #319: the window of a whole-series delete. It is one EventKit query long (1460 days), as
    /// the restore lists it in one query, and placed around the time of the delete: from three
    /// years (1094 days) before the delete, or from one day before the series' first occurrence
    /// when that is later, and moved earlier when the rule ends sooner, so that it ends one day
    /// after the rule's end (a count's last possible slot). It so reaches at least a year past the
    /// delete; a series begun within about three years of the delete gets the window it had
    /// before #319, and a series that ended long before the delete is listed over its last four years.
    ///
    /// Before #319 this was the create-undo window (`UndoPostState.seriesScanWindow`, #259),
    /// anchored at the first occurrence; for a series begun more than about four years before the
    /// delete it lay entirely in the past, so the exceptions that mattered were never listed. The
    /// create-undo window is unchanged: a series it checks was just created. PR #494 round 1: the
    /// look-back was one year, which lost the older exceptions of a series begun one to four years
    /// before the delete that the old window held.
    static func deleteWindow(firstStart: Date, end: SeriesEnd, deletedAt: Date) -> DeleteWindow {
        let day: TimeInterval = 86_400
        let length = 1460 * day
        let fromFirst = firstStart.addingTimeInterval(-day)
        let ruleLimit: Date?
        switch end {
        case .endsAt(let date), .endsBy(let date): ruleLimit = date.addingTimeInterval(day)
        case .open, .unknown: ruleLimit = nil
        }
        var anchor = deletedAt.addingTimeInterval(-1094 * day)
        if let ruleLimit { anchor = min(anchor, ruleLimit.addingTimeInterval(-length)) }
        let start = max(fromFirst, anchor)
        let cap = start.addingTimeInterval(length)
        let windowEnd = max(start, ruleLimit.map { min($0, cap) } ?? cap)
        let past = ruleLimit.map { $0.timeIntervalSince(windowEnd) >= 1 } ?? false
        let continues: Bool, may: Bool
        switch end {
        case .open: (continues, may) = (true, false)
        case .unknown: (continues, may) = (false, true)
        case .endsAt: (continues, may) = (past, false)
        case .endsBy: (continues, may) = (false, past)
        }
        // Round 1 (LOW): occurrences before the window are those before the first occurrence.
        return DeleteWindow(window: DateInterval(start: start, end: windowEnd),
                            seriesStartsBefore: start.timeIntervalSince(firstStart) >= 1,
                            seriesContinuesAfter: continues, seriesMayContinueAfter: may)
    }

    /// One occurrence as the enumeration of the series' window reports it.
    struct ObservedOccurrence {
        let ids: UndoPostState.OccurrenceIDs
        let isDetached: Bool
        let occurrenceDate: Date?
        let startDate: Date
        /// The occurrence as an `EventSnapshot` without rules (used for a detached one).
        let snapshot: EventSnapshot
    }

    /// `UndoPostState.ruleSlot` of an occurrence. Compared as an instant, an all-day RID never
    /// matched, which made the consistency guard apply nothing for every all-day series with an edit.
    static func ruleSlot(of occurrence: ObservedOccurrence) -> Date {
        UndoPostState.ruleSlot(eventIdentifier: occurrence.ids.eventIdentifier, externalIdentifier: occurrence.ids.externalIdentifier,
                               occurrenceDate: occurrence.occurrenceDate, isAllDay: occurrence.snapshot.isAllDay) ?? occurrence.startDate
    }

    /// Whether a rule slot is inside the window: start inclusive, end EXCLUSIVE, like an EventKit
    /// query, which does not return an event that starts exactly at the end of its range (checked
    /// on device 2026-10-13). A closed end made an occurrence starting at the window end recorded
    /// but never listed on undo, which disabled the restore for open-ended daily series (PR #318
    /// verify round 3).
    static func inWindow(_ slot: Date, _ window: DateInterval) -> Bool {
        slot >= window.start && slot < window.end
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
    /// Nil when no occurrence of the series was listed INSIDE the window: an empty listing is not
    /// "the series had no exceptions", and treating it so would make every generated slot surplus
    /// on undo (round 2, B). Occurrences found only in the margins do not count (round 3: the
    /// margin queries always find an open-ended series' own occurrences).
    static func capture(_ observed: [ObservedOccurrence], of series: UndoPostState.OccurrenceIDs,
                        window: DateInterval) -> SeriesExceptions? {
        var kept: [Date] = []
        var detached: [DetachedOccurrence] = []
        for occurrence in observed where UndoPostState.isOccurrence(occurrence.ids, of: series) {
            if occurrence.isDetached {
                let slot = Self.ruleSlot(of: occurrence)
                if Self.inWindow(slot, window) { detached.append(DetachedOccurrence(slot: slot, snapshot: occurrence.snapshot)) }
            } else {
                let slot = occurrence.occurrenceDate ?? occurrence.startDate
                if Self.inWindow(slot, window) { kept.append(slot) }
            }
        }
        guard !kept.isEmpty || !detached.isEmpty else { return nil }
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
            SeriesExceptionsPlanner.inWindow(slot, exceptions.window)
                && !exceptions.keptSlots.contains { UndoPostState.sameInstant($0, slot) }
        }
    }
}

/// Why restoring a series' exceptions stopped (#285). Every case but `rollbackFailed` means the
/// recreated series and anything created for the exceptions were deleted again, so nothing of the
/// restore is left and the undo can be retried. `rollbackFailed` means the compensating delete
/// itself failed: the series exists, with some exceptions applied.
///
/// `code` is the failed write's sanitized code (`SeriesExceptionsRestorer.failureCode`, #398):
/// `eventkit_error_<N>` for an EventKit error, otherwise the sanitizer's generic code. It is the
/// only part of the underlying error kept, so a failure that recurs on every retry can be told
/// from a passing one without an EventKit description (which can quote calendar data, #37)
/// reaching the text.
enum SeriesExceptionsRestoreError: Error, Equatable {
    /// A surplus slot could not be found among the recreated series' occurrences. Nothing was removed.
    case surplusUnresolved(Date)
    /// Removing the surplus occurrence at this slot failed.
    case removeFailed(Date, code: String)
    /// Recreating the occurrence edited on its own at this slot failed.
    case oneOffFailed(Date, code: String)
    /// The compensating delete failed after one of the above; `exclusionsApplied` surplus
    /// occurrences had been removed by then.
    case rollbackFailed(exclusionsApplied: Int)
    /// The recreated series was deleted again, but a one-off event created for an exception could
    /// not be removed: it remains in the calendar (round 2, C). `code` is the save's.
    case strayOneOffs(Date, code: String)
    /// The recreated series was deleted again; a one-off whose save threw may or may not have been
    /// written and could not be removed, so it may remain. `code` is the save's.
    case oneOffMaybeLeft(Date, code: String)
}

/// A one-off save that threw after the store may have taken the write: the closure hands the
/// event back so the restore can clean it up (PR #318 verify B3), with the save's error so the
/// restore can name its code (#398).
struct SeriesExceptionsOneOffWriteFailed<OneOff>: Error {
    let possiblyWritten: OneOff
    let underlying: Error
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

    /// The sanitized code of a failed write (#398): `eventkit_error_<N>`, `error_<domain>_<N>` for
    /// another NSError, otherwise `error_unknown`. `sanitize`, not `sanitizeForResponse`: for a
    /// trusted error the latter's "code" is the error's whole text. The one trusted error that can
    /// reach a one-off's creation is `undoCalendarMissing` (from `calendarNow`), a complete
    /// instruction to give the undo up; in the "(code)" slot of a text that says the restore was
    /// rolled back and can be retried, it would contradict that text. So only the code is kept.
    /// The description behind it goes to stderr for an operator (escaped and capped, through
    /// `writeFailureLog`, which logs untrusted errors only), never into the text (PR #405 verify).
    static func failureCode<OneOff>(_ error: Error, oneOff: OneOff.Type) -> String {
        let underlying = (error as? SeriesExceptionsOneOffWriteFailed<OneOff>)?.underlying ?? error
        _ = EventKitErrorSanitizer.writeFailureLog(handler: "undo", identifier: "series exceptions restore", error: underlying)
        return EventKitErrorSanitizer.sanitize(underlying).code
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
        // same series: every recorded slot (kept and edited) is generated, and so is the series' own first slot.
        let generatedSlots = generated.map(\.slot)
        func isGenerated(_ slot: Date) -> Bool { generatedSlots.contains { UndoPostState.sameInstant($0, slot) } }
        // #319: the window may start after the series' first occurrence (a series begun more than a
        // few years before the delete), where the listing cannot show it; it is required only inside.
        let firstSlotChecked = SeriesExceptionsPlanner.inWindow(seriesStart, exceptions.window)
        guard !firstSlotChecked || isGenerated(seriesStart), exceptions.keptSlots.allSatisfy(isGenerated),
              exceptions.detached.allSatisfy({ isGenerated($0.slot) }) else {
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

/// #321: what ties a deleted occurrence to its series: the series' identifiers and the slot the
/// series' rule gave the occurrence, not its (possibly edited) title and start.
struct OccurrenceOrigin: Equatable {
    let series: UndoPostState.OccurrenceIDs
    let slot: Date
    /// #321 r1: the occurrence was edited on its own before its delete (detached, or a `/RID=`
    /// identifier): a series that holds its slot holds it without that edit.
    var edited: Bool = false

    /// From an occurrence's identifiers: the series is the part before a `/RID=` suffix
    /// (`DetachedOccurrenceSpan.seriesIdentifier`), the slot the rule slot (`UndoPostState.ruleSlot`:
    /// the RID when there is one, otherwise `occurrenceDate`). Nil without either: nothing ties the
    /// occurrence to its series, and the guard cannot decide.
    static func of(eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?, isAllDay: Bool,
                   isDetached: Bool = false, zone: TimeZone = .current) -> OccurrenceOrigin? {
        guard let series = seriesIDs(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier),
              let slot = UndoPostState.ruleSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                                occurrenceDate: occurrenceDate, isAllDay: isAllDay, zone: zone) else { return nil }
        let rid = UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier, occurrenceDate: nil)
        return OccurrenceOrigin(series: series, slot: slot, edited: isDetached || rid != nil)
    }

    /// The identifiers of the series an occurrence belongs to: each without its `/RID=` suffix.
    /// Nil when neither is a non-empty identifier.
    static func seriesIDs(eventIdentifier: String?, externalIdentifier: String?) -> UndoPostState.OccurrenceIDs? {
        func base(_ id: String?) -> String? {
            guard let id, !id.isEmpty else { return nil }
            return DetachedOccurrenceSpan.seriesIdentifier(of: id) ?? id
        }
        let event = base(eventIdentifier), external = base(externalIdentifier)
        guard event != nil || external != nil else { return nil }
        return UndoPostState.OccurrenceIDs(eventIdentifier: event, externalIdentifier: external)
    }
}

/// #321: the series that undo recreated in this process, by the series they were recorded as. The
/// undo of a whole-series delete writes a new series with new identifiers, so an occurrence record
/// of the original series could not otherwise tell that series' occurrences from another's. Kept
/// in memory for the life of the server, as the undo history is; a fact once noted stays true.
struct SeriesRecreations {
    private var links: [(recorded: UndoPostState.OccurrenceIDs, recreated: UndoPostState.OccurrenceIDs)] = []

    mutating func note(_ recorded: UndoPostState.OccurrenceIDs, recreatedAs recreated: UndoPostState.OccurrenceIDs) {
        links.append((recorded, recreated))
    }

    /// The series recreated from `series`, and from those in turn, in the order they were noted.
    func recreations(of series: UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs] {
        var found: [UndoPostState.OccurrenceIDs] = []
        var frontier = [series]
        while let current = frontier.popLast() {
            for link in links where Self.sameSeries(link.recorded, current) {
                guard !Self.sameSeries(link.recreated, series), !found.contains(where: { Self.sameSeries($0, link.recreated) }) else { continue }
                found.append(link.recreated)
                frontier.append(link.recreated)
            }
        }
        return found
    }

    /// The same series: an equal non-empty event identifier or external identifier.
    static func sameSeries(_ a: UndoPostState.OccurrenceIDs, _ b: UndoPostState.OccurrenceIDs) -> Bool {
        func same(_ x: String?, _ y: String?) -> Bool { x.map { !$0.isEmpty && $0 == y } ?? false }
        return same(a.eventIdentifier, b.eventIdentifier) || same(a.externalIdentifier, b.externalIdentifier)
    }
}

/// #285: whether an occurrence delete's slot is already held by the recreated series. When a
/// whole-series delete is undone first, the series' rules bring every slot back, so undoing the
/// earlier delete of one occurrence would write a second event there.
enum OccurrenceSlotGuard {
    /// #321: an event listed at the slot: its identifiers and the slot its rule gave it.
    struct SeriesHolder: Equatable {
        let ids: UndoPostState.OccurrenceIDs
        let slot: Date
    }

    /// #321: true when one of `holders` is an occurrence of the recorded series, or of a series
    /// undo recreated from it (`recreated`), at the recorded rule slot (to the second). Tied by
    /// identifier (`UndoPostState.isOccurrence`), never by title: before #321 any recurring event
    /// with the title at that second held the slot, an unrelated series included, and an occurrence
    /// retitled or moved before its delete was compared by its edit. A one-off at the slot does not
    /// count: it is not what the series' restore brings back, and refusing to write beside it would
    /// hide a real second write.
    static func isHeld(_ origin: OccurrenceOrigin, recreatedAs recreated: [UndoPostState.OccurrenceIDs],
                       by holders: [SeriesHolder]) -> Bool {
        let series = [origin.series] + recreated
        return holders.contains { holder in
            UndoPostState.sameInstant(holder.slot, origin.slot)
                && series.contains { UndoPostState.isOccurrence(holder.ids, of: $0) }
        }
    }

    /// A holder from an event listed at the slot: its rule slot is `UndoPostState.ruleSlot` (the
    /// RID of an occurrence edited on its own, otherwise `occurrenceDate`), else its start.
    static func holder(eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?, isAllDay: Bool,
                       startDate: Date, zone: TimeZone = .current) -> SeriesHolder {
        SeriesHolder(ids: .init(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier),
                     slot: UndoPostState.ruleSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                                  occurrenceDate: occurrenceDate, isAllDay: isAllDay, zone: zone) ?? startDate)
    }
}
