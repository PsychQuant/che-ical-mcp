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
    /// #319: the series has occurrences before `window` (its first occurrence is before the
    /// window's start: it began more than three years before the delete, or its window was moved
    /// to reach the end of its rule), which come back from the rules alone.
    var seriesStartsBeforeWindow: Bool = false
    /// #319: the series has occurrences after `window`: an open-ended rule, or an end date at or
    /// past the window's end. They come back from the rules alone.
    var seriesContinuesAfterWindow: Bool = false
    /// #319 (PR #494 round 1): the series may have occurrences after `window`: a count whose last
    /// possible slot is at or past the window's end (an upper bound), or a count whose end cannot
    /// be shown. Never set together with `seriesContinuesAfterWindow`.
    var seriesMayContinueAfterWindow: Bool = false
    /// PR #494 rounds 4-5: further windows the occurrences were listed over, each one EventKit query
    /// long. A count whose window around the delete starts after its first occurrence records the
    /// window from its first occurrence here (the window before #319) beside `window`, always (round 7).
    /// Empty for every other series.
    var extraWindows: [DateInterval] = []

    /// `window` and `extraWindows`: every slot judged, kept or removed is inside one of them.
    var windows: [DateInterval] { [window] + extraWindows }
}

/// An occurrence edited on its own: undo recreates it as a one-off event (EventKit cannot put an
/// edited occurrence back into its series; #244 D1 precedent).
struct DetachedOccurrence {
    /// The start the series' rule gave this occurrence, from the `/RID=` of its identifier (#311): the
    /// instant reading (`SlotReadings.instant`), as before #539.
    let slot: Date
    /// The occurrence's own fields, without recurrence rules.
    let snapshot: EventSnapshot
    /// #539: every instant `slot` can be (`SlotReadings`): one for an all-day occurrence, one
    /// without a `/RID=`, and one of a series that had a time zone when it was captured (PR #558
    /// round 1, ruling A); for a timed `/RID=` of a series without one, also its wall-clock reading in
    /// the capturing zone. A record with that second reading stops the restore
    /// (`SeriesExceptionsPlanner.holdsAFloatingEdit`, PR #558 round 3).
    let readings: SlotReadings

    init(slot: Date, snapshot: EventSnapshot, readings: SlotReadings? = nil) {
        self.slot = slot
        self.snapshot = snapshot
        self.readings = readings ?? SlotReadings(instant: slot)
    }
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

        /// A rule that ends after a count of occurrences (`endsBy` or `unknown`).
        var isCount: Bool {
            switch self {
            case .endsBy, .unknown: return true
            case .open, .endsAt: return false
            }
        }
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
            guard let last = windowLastSlot(of: rule, firstStart: firstStart, calendar: calendar) else { return .unknown }
            if rule.endDate == nil { counted = true }
            latest = latest.map { max($0, last) } ?? last
        }
        guard let latest else { return .open }
        return counted ? .endsBy(latest) : .endsAt(latest)
    }

    /// The latest slot a rule can reach, for the delete window only: `lastPossibleSlot`, except that a
    /// weekly count on k > 1 weekdays (no other filter) is bounded by ceil(count / k) weeks of its
    /// interval plus the first week, since each week it runs holds k occurrences (the first week may
    /// hold fewer). PR #494 round 2: `lastPossibleSlot` gives count weeks there, about k times too
    /// late, which put the window of such a series that ended long ago after its last occurrence.
    /// `lastPossibleSlot` itself is not changed: the #442 and #455 refusals read it, and a looser
    /// bound keeps them refusing.
    static func windowLastSlot(of rule: DetachedOccurrenceSpan.RuleExtent, firstStart: Date, calendar: Calendar) -> Date? {
        if rule.endDate == nil, rule.frequency == .weekly, rule.occurrenceCount > 0, !rule.hasFilter, rule.weekdayCount > 1 {
            let weeks = (rule.occurrenceCount + rule.weekdayCount - 1) / rule.weekdayCount
            return calendar.date(byAdding: .day, value: 7 * weeks * rule.interval + 7, to: firstStart)
        }
        return DetachedOccurrenceSpan.lastPossibleSlot(of: rule, firstStart: firstStart, calendar: calendar)
    }

    /// #319: the window of a whole-series delete. It is one EventKit query long (1460 days), as
    /// the restore lists it in one query, and placed around the time of the delete: from three
    /// years (1094 days) before the delete, or from one day before the series' first occurrence
    /// when that is later, and moved earlier when the rule ends sooner, so that it reaches one day
    /// after the rule's end (an end date also cuts it there; a count's last possible slot only moves
    /// it). It so reaches at least a year past the delete; a series begun within about three years
    /// of the delete gets the window it had before #319. A series that ended long before the delete
    /// is listed toward its end: for an end date, over its last four years up to that date; for a
    /// count, the window from its first occurrence when its last possible slot is within 1459 days
    /// of the first occurrence, else the 1460 days before that slot (not cut at it). A count whose
    /// end cannot be shown is placed as open-ended here; for every count the capture adds the window
    /// from its first occurrence when this one starts later (PR #494 rounds 4-7).
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
        let lastSlot: Date?
        switch end {
        case .endsAt(let date), .endsBy(let date): lastSlot = date
        case .open, .unknown: lastSlot = nil
        }
        let ruleLimit = lastSlot.map { $0.addingTimeInterval(day) }
        var anchor = deletedAt.addingTimeInterval(-1094 * day)
        if let ruleLimit { anchor = min(anchor, ruleLimit.addingTimeInterval(-length)) }
        let start = max(fromFirst, anchor)
        let cap = start.addingTimeInterval(length)
        // An end date cuts the window (as `seriesScanWindow` does); a count's bound only moves it
        // earlier (round 2): it is an upper bound, and the old window, not cut, also saw an edited
        // occurrence moved past the series' end.
        let cutAt: Date? = { if case .endsAt = end { return ruleLimit } else { return nil } }()
        let windowEnd = max(start, cutAt.map { min($0, cap) } ?? cap)
        // Round 2 (LOW): an occurrence after the window starts at or after its end, so only a last
        // slot at or past the end leaves one there.
        let past = lastSlot.map { $0 >= windowEnd } ?? false
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
    static func ruleSlot(of occurrence: ObservedOccurrence, zone: TimeZone = .current) -> Date {
        UndoPostState.ruleSlot(eventIdentifier: occurrence.ids.eventIdentifier, externalIdentifier: occurrence.ids.externalIdentifier,
                               occurrenceDate: occurrence.occurrenceDate, isAllDay: occurrence.snapshot.isAllDay, zone: zone) ?? occurrence.startDate
    }

    /// #539: the readings of an occurrence's slot (`SlotReadings.of`), the instant one being
    /// `ruleSlot(of:zone:)`. PR #558 round 1 (ruling A): the wall-clock reading only when `floating`,
    /// the occurrence's series having no time zone when it is read; otherwise the instant alone, as
    /// before #539.
    static func slotReadings(of occurrence: ObservedOccurrence, zone: TimeZone = .current, floating: Bool = false) -> SlotReadings {
        guard floating else { return SlotReadings(instant: ruleSlot(of: occurrence, zone: zone)) }
        return SlotReadings.of(eventIdentifier: occurrence.ids.eventIdentifier, externalIdentifier: occurrence.ids.externalIdentifier,
                               occurrenceDate: occurrence.occurrenceDate, isAllDay: occurrence.snapshot.isAllDay, zone: zone)
            ?? SlotReadings(instant: ruleSlot(of: occurrence, zone: zone))
    }

    /// Whether a rule slot is inside the window: start inclusive, end EXCLUSIVE, like an EventKit
    /// query, which does not return an event that starts exactly at the end of its range (checked
    /// on device 2026-10-13). A closed end made an occurrence starting at the window end recorded
    /// but never listed on undo, which disabled the restore for open-ended daily series (PR #318
    /// verify round 3).
    static func inWindow(_ slot: Date, _ window: DateInterval) -> Bool {
        slot >= window.start && slot < window.end
    }

    /// Round 4: inside any of `windows` (`inWindow`).
    static func inWindows(_ slot: Date, _ windows: [DateInterval]) -> Bool {
        windows.contains { inWindow(slot, $0) }
    }

    /// Round 4: `capture(_:of:window:)` over several windows: a slot counts when it is inside any
    /// of them. The first is the record's `window`, the rest its `extraWindows`. Nil when none of
    /// the series' occurrences was listed inside any.
    ///
    /// #539: an occurrence edited on its own is recorded when either reading of its slot
    /// (`SlotReadings`, in `zone`) is inside a window. Before #539 only the instant reading was tested:
    /// an occurrence edited while its series had no time zone, whose true slot is inside the window and
    /// whose instant reading is outside, was not recorded, and its slot was then removed from the
    /// recreated series as one deleted on its own. Recorded, a record of two readings stops the restore
    /// (`holdsAFloatingEdit`, PR #558 round 3), so its true slot is not removed.
    /// PR #558 round 1 (ruling A): the two readings only when `floating`, the series having no time
    /// zone when it is read (`SeriesExceptionsStoreSource.isFloating`); otherwise each record has the
    /// instant reading alone and this is the capture of before #539.
    static func capture(_ observed: [ObservedOccurrence], of series: UndoPostState.OccurrenceIDs,
                        windows: [DateInterval], zone: TimeZone = .current, floating: Bool = false) -> SeriesExceptions? {
        guard let first = windows.first else { return nil }
        var kept: [Date] = []
        var detached: [DetachedOccurrence] = []
        for occurrence in observed where UndoPostState.isOccurrence(occurrence.ids, of: series) {
            if occurrence.isDetached {
                let readings = Self.slotReadings(of: occurrence, zone: zone, floating: floating)
                if readings.all.contains(where: { Self.inWindows($0, windows) }) {
                    detached.append(DetachedOccurrence(slot: readings.instant, snapshot: occurrence.snapshot, readings: readings))
                }
            } else {
                let slot = occurrence.occurrenceDate ?? occurrence.startDate
                if Self.inWindows(slot, windows) { kept.append(slot) }
            }
        }
        guard !kept.isEmpty || !detached.isEmpty else { return nil }
        return SeriesExceptions(window: first, keptSlots: kept.sorted(), detached: detached.sorted { $0.slot < $1.slot },
                                extraWindows: Array(windows.dropFirst()))
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

    /// PR #494 round 6: the ranges to list several windows over, in one pass: the listing ranges of
    /// each window (`listingRanges(for:)`), merged where they meet or overlap, then cut into pieces
    /// of at most 1460 days (one EventKit query each). Disjoint and in order, so no range is queried
    /// twice and the gap between two windows far apart is not queried at all.
    static func listingRanges(covering windows: [DateInterval]) -> [DateInterval] {
        let limit: TimeInterval = 1460 * 86_400
        var merged: [DateInterval] = []
        for range in windows.flatMap(listingRanges(for:)).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged.flatMap { range -> [DateInterval] in
            var pieces: [DateInterval] = []
            var start = range.start
            while start < range.end {
                let end = min(start.addingTimeInterval(limit), range.end)
                pieces.append(DateInterval(start: start, end: end))
                start = end
            }
            return pieces
        }
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
                        window: DateInterval, zone: TimeZone = .current, floating: Bool = false) -> SeriesExceptions? {
        capture(observed, of: series, windows: [window], zone: zone, floating: floating)
    }

    /// PR #558 round 3 (verify findings J1, J2; the placement of rounds 0 to 2 withdrawn): whether the record
    /// holds an occurrence edited on its own whose recorded time has two readings, an instant and wall-clock
    /// time (`SlotReadings`): an occurrence of a series with no time zone, read on a host whose offset from
    /// UTC at that time is not 0. Its original slot cannot be read reliably: it was placed on the one reading
    /// that is a slot of the recreated series, and when the series had been moved after the edit, that reading
    /// could be the wrong slot (rounds 1 to 3 each found a shape that lost an occurrence or wrote a second
    /// event, the last with the true slot outside every window, J1). When this holds, the restore applies none
    /// of the recorded exceptions (`Outcome.floatingEdit`) and the forecast at the delete counts every
    /// recorded edit (`unplacedEdits`). A record of one reading is never the reason: with none of two
    /// readings this is false, and the restore is the one of before #539.
    static func holdsAFloatingEdit(_ exceptions: SeriesExceptions) -> Bool {
        exceptions.detached.contains { $0.readings.wallClock != nil }
    }

    /// #539 step 6: how many of the recorded occurrences edited on their own the restore is expected not to
    /// apply, read at the delete, before anything is removed. PR #558 round 3: when the record holds a
    /// floating edit (`holdsAFloatingEdit`), every recorded edited occurrence, without the expander: the
    /// restore applies none of them. Otherwise every record has one reading (its instant), and a record
    /// counts when that slot is no slot the rule gives from `firstSlot` (`DeletedOccurrenceCheck`'s
    /// expander, in `calendar`'s zone) up to the last window's end, as the restore's consistency check would
    /// not apply it (cell N1: a zoned series moved after the edit). A count above 0 forecasts that undo
    /// restores the series from its rules alone. A record that ends before it starts is not counted
    /// (`endsBeforeItStarts`; the delete gives no note for it).
    /// Nil when the expander cannot tell, so the delete says nothing rather than guess: not exactly one
    /// rule, no first slot (a stand-in, or a first occurrence edited on its own), a rule the expander
    /// does not follow, more slots than it takes, or (PR #558 round 1, ruling G, the #503 verdict's own
    /// guard) a recorded occurrence not edited on its own that is no slot of the expander, so the
    /// expander is wrong here.
    static func unplacedEdits(_ exceptions: SeriesExceptions, rules: [DeletedOccurrenceCheck.Rule], firstSlot: Date?,
                              calendar: Calendar) -> Int? {
        guard !exceptions.detached.isEmpty else { return 0 }
        if holdsAFloatingEdit(exceptions) { return exceptions.detached.count }
        guard rules.count == 1, let firstSlot, let end = exceptions.windows.map(\.end).max() else { return nil }
        guard case .slots(let slots) = DeletedOccurrenceCheck.expansion(of: rules[0], firstStart: firstSlot, until: end,
                                                                         calendar: calendar) else { return nil }
        let set = InstantSet(slots)
        guard exceptions.keptSlots.allSatisfy(set.contains) else { return nil }
        return exceptions.detached.filter { !set.contains($0.slot) }.count
    }

    /// #539 (device cell DS1, iCloud, 2026-11-17): whether a recorded edited occurrence ends before it
    /// starts. A floating occurrence whose wall-clock times fall across a daylight-saving gap of the reading
    /// zone (02:30 to 03:00 on 2027-03-14 at America/Los_Angeles) was listed from 03:30 to 03:00, and its
    /// one-off failed to save (EKErrorDatesInverted), so the undo rolled back and restored nothing. Such a
    /// record stops the restore instead (fail closed: the series comes back from its rules), and so does
    /// one on the series' first slot, although the restore keeps that slot from the rule and writes no
    /// one-off for it (PR #558 round 2, H25). PR #558 round 3: asked after `holdsAFloatingEdit`, so it
    /// decides only for records of one reading (DS1's record has two at Los Angeles and stops there); a
    /// record of one reading (a host at offset 0 before the spring change, Europe/London) failed the same
    /// way before #539 (ruling E, F7).
    static func endsBeforeItStarts(_ exceptions: SeriesExceptions) -> Bool {
        exceptions.detached.contains { $0.snapshot.endDate < $0.snapshot.startDate }
    }

    /// The slots of the recreated series (`generated`) that undo must remove: inside the window
    /// and not the slot of an occurrence that existed and was not edited on its own. A detached
    /// occurrence's slot is not in `keptSlots`, so it is removed here and comes back as a one-off.
    /// Slots outside the window are left to the series' rule: they were never listed.
    /// Slots compare as instants, to the second (`UndoPostState.sameInstant`).
    /// #527: the kept slots are asked through an `InstantSet` (the same comparison, without a scan
    /// of them for every generated slot).
    static func surplusSlots(generated: [Date], exceptions: SeriesExceptions) -> [Date] {
        let kept = InstantSet(exceptions.keptSlots)
        return generated.filter { slot in
            SeriesExceptionsPlanner.inWindows(slot, exceptions.windows) && !kept.contains(slot)
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
        /// #539 (device cell DS1): with `notApplied`, why: a recorded edited occurrence ends before it
        /// starts as this process reads it, so no one-off can be saved for it (ruling E).
        var endsBeforeStart: Bool = false
        /// PR #558 round 3: with `notApplied`, why: the series had no time zone and an occurrence of it
        /// edited on its own has a recorded time of two readings (`SeriesExceptionsPlanner.holdsAFloatingEdit`).
        var floatingEdit: Bool = false
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

    /// `generated` lists the recreated series' occurrences inside `exceptions.windows`, as
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
        // #527: the generated slots are asked through a set, and an occurrence is found by its slot
        // through an index, instead of a scan of `generated` per slot. The comparison is
        // `UndoPostState.sameInstant` as before, and the index answers with the first entry of
        // `generated` at the slot, in its own order, as `first { }` did.
        let generatedSlots = generated.map(\.slot)
        // PR #558 round 3: a record of two readings applies nothing (the placement is withdrawn).
        if SeriesExceptionsPlanner.holdsAFloatingEdit(exceptions) {
            return Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true, floatingEdit: true)
        }
        // #539: fail closed for a record no one-off can be saved for.
        if SeriesExceptionsPlanner.endsBeforeItStarts(exceptions) {
            return Outcome(stayedDeleted: 0, oneOffs: 0, notApplied: true, endsBeforeStart: true)
        }
        let generatedSet = InstantSet(generatedSlots)
        let generatedIndex = InstantIndex(generatedSlots)
        func isGenerated(_ slot: Date) -> Bool { generatedSet.contains(slot) }
        // #319: the window may start after the series' first occurrence (a series begun more than a
        // few years before the delete), where the listing cannot show it; it is required only inside.
        let firstSlotChecked = SeriesExceptionsPlanner.inWindows(seriesStart, exceptions.windows)
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

        let detachedSet = InstantSet(exceptions.detached.map(\.slot))
        let stayedDeleted = surplus.filter { !detachedSet.contains($0) }.count
        return Outcome(stayedDeleted: stayedDeleted, oneOffs: created.count, firstOccurrenceKeptFromRule: firstKept)
    }
}

/// #321: what ties a deleted occurrence to its series: the series' identifiers and the slot the
/// series' rule gave the occurrence, not its (possibly edited) title and start.
struct OccurrenceOrigin: Equatable {
    let series: UndoPostState.OccurrenceIDs
    /// The instant reading of the slot (`SlotReadings.instant`): where the guard lists the holders.
    let slot: Date
    /// #321 r1: the occurrence was edited on its own before its delete (detached, or a `/RID=`
    /// identifier): a series that holds its slot holds it without that edit.
    var edited: Bool = false
    /// #539: the wall-clock reading of the slot (`SlotReadings.wallClock`), taken only for an
    /// occurrence of a series that had no time zone when it was read (PR #558 round 1, ruling A); nil
    /// otherwise, and for an all-day occurrence or one without a `/RID=`.
    var wallClock: Date? = nil

    /// From an occurrence's identifiers: the series is the part before a `/RID=` suffix
    /// (`DetachedOccurrenceSpan.seriesIdentifier`), the slot the rule slot (`UndoPostState.ruleSlot`:
    /// the RID when there is one, otherwise `occurrenceDate`). Nil without either: nothing ties the
    /// occurrence to its series, and the guard cannot decide. `floating`: the series had no time zone
    /// when the occurrence was read, so a timed `/RID=` is also read as wall-clock time (`SlotReadings`).
    static func of(eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?, isAllDay: Bool,
                   isDetached: Bool = false, floating: Bool = false, zone: TimeZone = .current) -> OccurrenceOrigin? {
        guard let series = seriesIDs(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier),
              let readings = SlotReadings.of(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                             occurrenceDate: occurrenceDate, isAllDay: isAllDay, zone: zone) else { return nil }
        let rid = UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier, occurrenceDate: nil)
        return OccurrenceOrigin(series: series, slot: readings.instant, edited: isDetached || rid != nil,
                                wallClock: floating ? readings.wallClock : nil)
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
        /// The instant reading of the holder's slot (`UndoPostState.ruleSlot`).
        let slot: Date
        /// PR #558 round 1 (ruling F): the holder is edited on its own (detached, or a `/RID=`
        /// identifier), so its `slot` is read from digits that may be wall-clock time; it is compared
        /// by that instant reading only, as before #539. A holder not edited on its own has its
        /// `occurrenceDate`, a true instant.
        var edited: Bool = false
    }

    /// PR #558 round 1 (ruling F): what the guard answers.
    enum Answer: Equatable {
        /// No occurrence of the series is at the slot: the occurrence is written as a one-off.
        case free
        /// An occurrence of the series is at the instant reading of the slot: nothing is written and
        /// the record is used up, as before #539.
        case held
        /// Only an occurrence of the series not edited on its own is at the wall-clock reading of the
        /// slot. Which reading is the slot cannot be told here (#539: the digits of an occurrence edited
        /// while its series had no time zone are wall-clock time, those of one edited while it had a
        /// zone are an instant, and a series can hold both, cell R2), so the undo writes nothing and is
        /// refused with the record kept (`OccurrenceSlotWallClockRefusal`).
        case heldAtWallClockOnly
    }

    /// #321: the answer for the recorded slot among `holders`: only an occurrence of the recorded
    /// series, or of a series undo recreated from it (`recreated`), counts, tied by identifier
    /// (`UndoPostState.isOccurrence`), never by title: before #321 any recurring event with the title
    /// at that second held the slot, an unrelated series included, and an occurrence retitled or moved
    /// before its delete was compared by its edit. A one-off at the slot does not count: it is not what
    /// the series' restore brings back, and refusing to write beside it would hide a real second write.
    ///
    /// #539 and PR #558 round 1 (ruling F): `held` when such an occurrence is at the instant reading of
    /// the origin's slot (to the second), as before #539; `heldAtWallClockOnly` when only one not edited
    /// on its own is at the origin's wall-clock reading (`OccurrenceOrigin.wallClock`, taken only for an
    /// occurrence of a series without a time zone). An edited holder is compared by its instant reading
    /// only: two readings compared with two readings can meet where neither occurrence's slot is (a
    /// `/RID=` of each kind on adjacent days at a host 12 hours from UTC, PR #558 verify F1, F4). So the
    /// guard answers `held` only where it did before #539, and the new case writes nothing and keeps the
    /// record. Not covered: a holder edited on its own at the origin's true slot whose `/RID=` is of the
    /// other kind (an instant where the origin's digits are wall-clock time, or the reverse) does not meet
    /// the origin's instant reading, so the one-off is written beside it, as before #539.
    static func answer(_ origin: OccurrenceOrigin, recreatedAs recreated: [UndoPostState.OccurrenceIDs],
                       by holders: [SeriesHolder]) -> Answer {
        let series = [origin.series] + recreated
        let ofSeries = holders.filter { holder in series.contains { UndoPostState.isOccurrence(holder.ids, of: $0) } }
        if ofSeries.contains(where: { UndoPostState.sameInstant($0.slot, origin.slot) }) { return .held }
        if let wallClock = origin.wallClock,
           ofSeries.contains(where: { !$0.edited && UndoPostState.sameInstant($0.slot, wallClock) }) {
            return .heldAtWallClockOnly
        }
        return .free
    }

    /// #321: true when `answer` is `held` (the answer of before #539).
    static func isHeld(_ origin: OccurrenceOrigin, recreatedAs recreated: [UndoPostState.OccurrenceIDs],
                       by holders: [SeriesHolder]) -> Bool {
        answer(origin, recreatedAs: recreated, by: holders) == .held
    }

    /// The range the slot's holders are listed over: the slot for the occurrence's length (at
    /// least a minute) and a year (366 days) on each side, in one query (at most 1460 days for any
    /// occurrence up to two years long). PR #494 round 2: an EventKit query matches events by the
    /// time they show, so an occurrence of the series edited on its own and moved off its slot
    /// (`<series>/RID=<slot>`) was not listed at the slot alone, and the undo wrote a second event
    /// there. It is found by its rule slot anywhere within the year; one moved further is not seen,
    /// as in the capture (`SeriesExceptionsPlanner.listingRanges`).
    static func listingRange(slot: Date, length: TimeInterval) -> DateInterval {
        let margin: TimeInterval = 366 * 86_400
        return DateInterval(start: slot.addingTimeInterval(-margin), end: slot.addingTimeInterval(max(length, 60) + margin))
    }

    /// A holder from an event listed at the slot: its rule slot is `UndoPostState.ruleSlot` (the
    /// RID of an occurrence edited on its own, otherwise `occurrenceDate`), else its start.
    /// PR #494 round 5: nil for a plain one-off event (no rules of its own, not detached, no
    /// `/RID=`): only an occurrence of a recurring series holds a slot. A series that lost its rule
    /// but kept its identifier, with its one remaining event moved onto the slot, is no series; the
    /// guard before #321 required rules too. An occurrence edited on its own has no rules of its own
    /// (iCloud) but is detached, or carries `/RID=`, so it still counts.
    static func holder(eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?, isAllDay: Bool,
                       startDate: Date, hasRecurrenceRules: Bool, isDetached: Bool, zone: TimeZone = .current) -> SeriesHolder? {
        let hasSlotSuffix = UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                                       occurrenceDate: nil) != nil
        guard hasRecurrenceRules || isDetached || hasSlotSuffix else { return nil }
        return SeriesHolder(ids: .init(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier),
                            slot: UndoPostState.ruleSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                                         occurrenceDate: occurrenceDate, isAllDay: isAllDay, zone: zone) ?? startDate,
                            edited: isDetached || hasSlotSuffix)
    }
}
