import EventKit
import Foundation

/// #326 (root cause #284): the stand-in for a series whose first occurrence was deleted.
///
/// For such a series `event(withIdentifier: <series id>)` still returns the series object, but
/// its `refresh()` returns false (device, iCloud, 2026-10-19), so `freshEvent` treated the series
/// as gone and `move_events_batch`, `update_event`, `copy_event` and the deletes answered "Event
/// not found" while every remaining occurrence was still listed under that identifier.
///
/// The earliest remaining occurrence stands in for the series. It must be an occurrence that
/// still belongs to the series as a series: the same event identifier, not detached, with the
/// rules. An occurrence edited on its own has no rules of its own, so a caller given one would
/// treat the series as a one-off; a different series, or a one-off that happens to share the
/// identifier, is not the series either.
///
/// One more refusal (verify round 1): an occurrence edited on its own whose slot is before the
/// stand-in. A write from the stand-in with `.futureEvents` covers its slot onward, so that
/// occurrence would stay behind while the call reported success. The stand-in is then refused, and
/// single occurrences can still be deleted or updated with span `this`. When that edited occurrence
/// is the earliest one left, `update_event` and `delete_event` with span `all` through the series'
/// id go through its own id instead (`earliestEdited`, #428), the way #416 left open.
enum FirstRemainingOccurrence {
    struct Candidate: Equatable {
        let eventIdentifier: String?
        let isDetached: Bool
        let hasRecurrenceRules: Bool
        let start: Date
        /// The slot an edited occurrence had in the series (from its `/RID=` identifier, else its
        /// `occurrenceDate`); nil when unknown, then its start stands in.
        var slot: Date? = nil
        /// Another store's edited occurrence: an unrelated identifier, the same iCalendar UID.
        var sameSeriesByExternalID: Bool = false
        /// `slot` was read from a `/RID=` (on either identifier, `slotIsFromRID`), so on an all-day
        /// series it is the wall-clock date read as UTC (`UndoPostState.ruleSlot(of:)`, verify r6).
        var slotFromRID: Bool = false
    }

    /// Whether `UndoPostState.originalSlot` reads the slot from a `/RID=` of either identifier.
    static func slotIsFromRID(eventIdentifier: String?, externalIdentifier: String?) -> Bool {
        UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier, occurrenceDate: nil) != nil
    }

    /// verify r5/r6: whether the series' first slot is gone, read as a rule slot: an all-day
    /// series' raw `/RID=` is not local midnight outside UTC.
    static func firstSlotDeleted(_ candidate: Candidate, firstStart: Date?, isAllDay: Bool, zone: TimeZone = .current) -> Bool {
        guard let firstStart else { return true }
        return !UndoPostState.sameInstant(UndoPostState.ruleSlot(of: candidate, isAllDay: isAllDay, zone: zone), firstStart)
    }

    /// The index of the earliest qualifying candidate (the first listed on a tie), or nil, also
    /// when an edited occurrence of the series has a slot before it.
    ///
    /// `refuseWhenEditedBefore: false` skips that refusal, for the writes it does not apply to: a
    /// move changes the calendar of the whole series and a copy copies one occurrence, so neither
    /// leaves an edited occurrence behind (device, iCloud, 2026-10-20), whereas a delete from the
    /// stand-in does.
    ///
    /// `goneInTheCall` (#416): identifiers an `event_ids` dry run has already passed. They do not
    /// count as edited before the stand-in, as they are deleted by the time the real call gets here.
    static func pick(_ candidates: [Candidate], identifier: String, refuseWhenEditedBefore: Bool = true,
                     goneInTheCall: Set<String> = []) -> Int? {
        var best: Int?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.eventIdentifier == identifier, !candidate.isDetached, candidate.hasRecurrenceRules else { continue }
            if let kept = best, candidates[kept].start <= candidate.start { continue }
            best = index
        }
        guard let best else { return nil }
        guard refuseWhenEditedBefore else { return best }
        let standIn = candidates[best].start
        let editedBefore = candidates.contains { candidate in
            guard candidate.isDetached, !goneInTheCall.contains(candidate.eventIdentifier ?? "") else { return false }
            let id = candidate.eventIdentifier
            let ofTheSeries = id == identifier || (id?.hasPrefix(identifier + "/") ?? false) || candidate.sameSeriesByExternalID
            return ofTheSeries && (candidate.slot ?? candidate.start) < standIn
        }
        return editedBefore ? nil : best
    }

    /// #428: the occurrence edited on its own that comes first in the series, when one does: the
    /// series' identifier reaches no stand-in then, and a whole-series write goes through that
    /// occurrence's own identifier, as measured. By slot, with the start standing in. Only an
    /// occurrence under the identifier's `/`-part: another store's shape was not measured.
    /// verify r3: it must not start after the next occurrence's slot; every measured row (the delete
    /// from it with span future included) had it there, and EventKit's cut by slot or by shown start
    /// past that was not measured.
    static func earliestEdited(_ candidates: [Candidate], identifier: String, isAllDay: Bool = false, zone: TimeZone = .current) -> Int? {
        // verify r6: rule slots, as the shown starts are local.
        func slot(_ index: Int) -> Date { UndoPostState.ruleSlot(of: candidates[index], isAllDay: isAllDay, zone: zone) }
        guard let first = candidates.indices.min(by: { slot($0) < slot($1) }),
              candidates[first].isDetached,
              DetachedOccurrenceSpan.seriesIdentifier(of: candidates[first].eventIdentifier ?? "") == identifier else { return nil }
        let others = candidates.indices.filter { $0 != first }
        if let next = others.map(slot).min(), candidates[first].start > next { return nil }
        // verify r4: nor may another occurrence show a start before its start.
        if others.contains(where: { candidates[$0].start < candidates[first].start }) { return nil }
        return first
    }

    /// Whether a delete or update resolves the stand-in with the edited-before refusal (verify
    /// round 5): a write that covers the rest of the series (`.futureEvents`, or a whole-series
    /// write) leaves an earlier edited occurrence behind; one occurrence (`.thisEvent`) cannot.
    static func refusesEditedBefore(span: EKSpan, wholeSeries: Bool = false) -> Bool {
        wholeSeries || span != .thisEvent
    }

    /// Whether a move leaves the account. EventKit does a move across accounts as a create plus a
    /// delete, and a delete from the stand-in is what leaves an earlier edited occurrence behind;
    /// the move exemption was only shown within one iCloud account, so a move across accounts (or
    /// with an unknown source) keeps the refusal.
    static func movesAcrossAccounts(fromSourceID: String?, toSourceID: String?) -> Bool {
        guard let fromSourceID, let toSourceID else { return true }
        return fromSourceID != toSourceID
    }

    /// Whether a move through the stand-in is refused (verify rounds 6-7): the whole series to
    /// another account. EventKit does that as a create plus a delete from a middle occurrence, and
    /// it was only shown safe within one account. One occurrence moved with span this is a copy
    /// plus a one-occurrence delete, as safe as deleting one, so it is not refused.
    static func refusesMoveThroughStandIn(viaStandIn: Bool, wholeSeries: Bool, acrossAccounts: Bool) -> Bool {
        viaStandIn && wholeSeries && acrossAccounts
    }

    /// Whether `update_event` through the stand-in is refused for a series-level property: a new
    /// calendar of another account (it moves the whole series even with span this, device) or a
    /// change of the recurrence rules (a series-level property like the calendar, so by the same
    /// reasoning, not shown on device). Refused whatever the span.
    static func refusesUpdateThroughStandIn(viaStandIn: Bool, changesAccount: Bool, changesRecurrence: Bool) -> Bool {
        viaStandIn && (changesAccount || changesRecurrence)
    }

    /// #335: whether a bare id that did not resolve should say so instead of "Event not found": the
    /// series is stored and recurring, its object fails to refresh, and a stand-in exists once the
    /// edited-before refusal is ignored, so that refusal alone hides it. Anything else (nothing
    /// stored, a series that refreshes, one with nothing left, a one-off) stays "Event not found".
    static func hintsEditedBefore(stored: Bool, refreshes: Bool, recurring: Bool, standInIgnoringTheRefusal: Bool) -> Bool {
        stored && !refreshes && recurring && standInIgnoringTheRefusal
    }

    /// #335 item 1: whether a bare id that did not resolve should say that every remaining
    /// occurrence was edited on its own. The series is stored, recurring and fails to refresh, no
    /// stand-in exists even without the edited-before refusal (an edited occurrence is never
    /// one), and the listing holds at least one edited occurrence of it. A series with nothing
    /// left has none, and stays "Event not found".
    static func hintsAllEdited(stored: Bool, refreshes: Bool, recurring: Bool,
                               standInIgnoringTheRefusal: Bool, editedOccurrences: Bool) -> Bool {
        stored && !refreshes && recurring && !standInIgnoringTheRefusal && editedOccurrences
    }

    /// Whether the listed occurrences of the series include one edited on its own. The candidates
    /// come from `seriesOccurrences`, which keeps only occurrences of the one series
    /// (`UndoPostState.isOccurrence`), so a detached event of another series is never in them.
    static func hasEditedOccurrence(_ candidates: [Candidate]) -> Bool {
        candidates.contains { $0.isDetached }
    }

    /// Whether any candidate could stand in for the series (`pick` without the edited-before
    /// refusal): the same test as `firstRemainingOccurrence`, before its refresh.
    static func hasStandInCandidate(_ candidates: [Candidate], identifier: String) -> Bool {
        pick(candidates, identifier: identifier, refuseWhenEditedBefore: false) != nil
    }

    /// Whether `update_event` with span future and an `occurrence_date` is refused: the occurrence
    /// found is the stand-in itself (or earlier), a whole-series save from a middle occurrence that
    /// splits the series into a new event id (verify rounds 3-4; `<=`, because the stand-in's own
    /// date is exactly the case).
    static func refusesFutureUpdate(viaStandIn: Bool, isFutureSpan: Bool, occurrenceStart: Date, standInStart: Date) -> Bool {
        viaStandIn && isFutureSpan && occurrenceStart <= standInStart
    }

    /// The flow of `freshEvent`, with the lookup result, the refresh and the stand-in injected so
    /// that each branch is tested without an event store: the stored object when it refreshes (the
    /// stand-in is not asked for), the stand-in when it does not, nil when nothing is stored or no
    /// stand-in exists.
    static func resolve<Event>(stored: Event?, refresh: (Event) -> Bool,
                               standIn: (Event) -> Event?) -> (event: Event, viaStandIn: Bool)? {
        guard let stored else { return nil }
        if refresh(stored) { return (stored, false) }
        return standIn(stored).map { ($0, true) }
    }
}

extension EventKitManager {
    /// The scan window of the series `stale`, read with care (see `firstRemainingOccurrence`).
    private func seriesScanWindow(of stale: EKEvent) -> DateInterval? {
        guard stale.hasRecurrenceRules else { return nil }
        let firstStart: Date? = stale.startDate
        guard let firstStart else { return nil }
        let ruleEnds = (stale.recurrenceRules ?? []).map { $0.recurrenceEnd?.endDate }
        let ruleEnd = ruleEnds.contains(where: { $0 == nil }) ? nil : ruleEnds.compactMap { $0 }.max()
        return UndoPostState.seriesScanWindow(firstStart: firstStart, ruleEnd: ruleEnd)
    }

    /// The occurrences of the series `stale` that the scan window lists (see
    /// `firstRemainingOccurrence`), with the candidate facts `FirstRemainingOccurrence` judges, or
    /// nil when the series has no rules or no readable calendar or start.
    /// #506: `ranges` replaces the listing ranges of the scan window (`SeriesExceptionsPlanner.listingRanges(for:)`).
    private func seriesOccurrences(of stale: EKEvent, id: String,
                                   ranges: [DateInterval]? = nil) -> ([EKEvent], [FirstRemainingOccurrence.Candidate])? {
        guard let calendar = stale.calendar, let window = seriesScanWindow(of: stale) else { return nil }
        let series = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: stale.calendarItemExternalIdentifier)
        var listed: [EKEvent] = []
        var byExternalID: [Bool] = []
        // The window and a year on each side, as #285's exception capture lists them (verify round
        // 3): an edited occurrence moved a few months out of the window blocks the stand-in too.
        for range in ranges ?? SeriesExceptionsPlanner.listingRanges(for: window) {
            let predicate = eventStore.predicateForEvents(withStart: range.start, end: range.end, calendars: [calendar])
            eventStore.enumerateEvents(matching: predicate) { event, _ in
                let ids = UndoPostState.OccurrenceIDs(eventIdentifier: event.eventIdentifier,
                                                      externalIdentifier: event.calendarItemExternalIdentifier)
                guard UndoPostState.isOccurrence(ids, of: series) else { return }
                // An occurrence overlapping two ranges is listed by both.
                guard !listed.contains(where: { $0.calendarItemIdentifier == event.calendarItemIdentifier
                                                 && $0.startDate == event.startDate }) else { return }
                listed.append(event)
                byExternalID.append(event.eventIdentifier != id && !(event.eventIdentifier?.hasPrefix(id + "/") ?? false))
            }
        }
        let candidates = zip(listed, byExternalID).map { event, external in
            FirstRemainingOccurrence.Candidate(
                eventIdentifier: event.eventIdentifier, isDetached: event.isDetached,
                hasRecurrenceRules: event.hasRecurrenceRules, start: event.startDate,
                slot: UndoPostState.originalSlot(eventIdentifier: event.eventIdentifier,
                                                 externalIdentifier: event.calendarItemExternalIdentifier,
                                                 occurrenceDate: event.occurrenceDate),
                sameSeriesByExternalID: external,
                slotFromRID: FirstRemainingOccurrence.slotIsFromRID(eventIdentifier: event.eventIdentifier,
                                                                    externalIdentifier: event.calendarItemExternalIdentifier))
        }
        return (listed, candidates)
    }

    /// #335 item 1: from one listing of the series `stale` in the scan window, whether a stand-in
    /// candidate exists (before its refresh) and whether an occurrence edited on its own exists.
    /// Both facts come from the same candidates, so they cannot disagree.
    func standInAndEditedFacts(of stale: EKEvent, id: String) -> (hasStandInCandidate: Bool, hasEdited: Bool) {
        guard let (_, candidates) = seriesOccurrences(of: stale, id: id) else { return (false, false) }
        return (FirstRemainingOccurrence.hasStandInCandidate(candidates, identifier: id),
                FirstRemainingOccurrence.hasEditedOccurrence(candidates))
    }

    /// #442 (cluster verify r2, r3): whether the series has an occurrence edited on its own, and
    /// whether the scan cannot rule one out: the series could not be listed (`listed` false), or the
    /// scan does not cover it whole (`DetachedOccurrenceSpan.editedOccurrenceUnknown`).
    func allDayEditFacts(of stale: EKEvent, id: String) -> (edited: Bool, unknown: Bool, listed: Bool) {
        guard let (_, candidates) = seriesOccurrences(of: stale, id: id), let window = seriesScanWindow(of: stale),
              let listedTo = SeriesExceptionsPlanner.listingRanges(for: window).map(\.end).max() else {
            return (false, true, false)
        }
        // Cluster verify r4 (LOW): an empty listing is not 'no edited occurrence' (as #285's capture reads it).
        guard !candidates.isEmpty else { return (false, true, false) }
        if FirstRemainingOccurrence.hasEditedOccurrence(candidates) { return (true, false, true) }
        let covers = DetachedOccurrenceSpan.coversWholeSeries(
            rules: (stale.recurrenceRules ?? []).map(DetachedOccurrenceSpan.RuleExtent.init),
            firstStart: stale.startDate, scannedTo: listedTo, calendar: Calendar.gregorian(in: stale.timeZone ?? .current))
        return (false, DetachedOccurrenceSpan.editedOccurrenceUnknown(coversWholeSeries: covers), true)
    }

    /// #503: whether an occurrence the write reaches (from `reachedFrom`, a rule slot; nil for a whole-
    /// series write) was deleted on its own, from one listing of `series` over the ranges #442 lists,
    /// compared with the rule's expected slots (`DeletedOccurrenceCheck`). `unknown` when the series
    /// cannot be listed, the listing is empty or does not cover the series (fail closed, as #442
    /// does), or the first slot cannot be proven (PR #505 round 1: `viaStandIn`, a detached object).
    /// #506: `horizonFrom` (now; nil: the whole series must be covered, as before) checks a series the
    /// listing does not cover up to now plus two years, in the zone the rule is expanded in, and lists
    /// the window around now as well when the listing from the first start ends before it.
    func deletedOccurrenceVerdict(of series: EKEvent, id: String, reachedFrom: Date?, viaStandIn: Bool,
                                  changesAllDay: Bool, horizonFrom now: Date? = nil) -> DeletedOccurrenceCheck.Verdict {
        let zone = series.isAllDay ? TimeZone.current : (series.timeZone ?? .current)
        let calendar = Calendar.gregorian(in: zone)
        let horizon = now.flatMap { DeletedOccurrenceCheck.horizon(now: $0, calendar: calendar) }
        guard let window = seriesScanWindow(of: series) else { return .unknown(.notListed) }
        let extents = (series.recurrenceRules ?? []).map(DetachedOccurrenceSpan.RuleExtent.init)
        let ranges = DeletedOccurrenceCheck.listingRanges(window: window, horizon: horizon, now: now ?? Date(), rules: extents, firstStart: series.startDate, calendar: calendar)
        guard let (_, candidates) = seriesOccurrences(of: series, id: id, ranges: ranges),
              let listedTo = ranges.map(\.end).max() else {
            return .unknown(.notListed)
        }
        guard !candidates.isEmpty else { return .unknown(.notListed) }
        func ruleSlot(_ candidate: FirstRemainingOccurrence.Candidate) -> Date {
            UndoPostState.ruleSlot(of: candidate, isAllDay: series.isAllDay, zone: zone)
        }
        // Round 2: the occurrence listed at the object's own start is the first occurrence.
        // Round 3: exactly one may be listed there, and no listed slot may lie before it.
        let atStart = candidates.filter { UndoPostState.sameInstant($0.start, series.startDate) }
        let occurrenceDate: Date? = series.occurrenceDate
        let firstSlot = DeletedOccurrenceCheck.firstSlotResult(
            occurrenceDate: occurrenceDate, startDate: series.startDate, startMatches: atStart.count,
            startRIDSlot: atStart.first.flatMap { $0.slotFromRID ? ruleSlot($0) : nil },
            earliestListedSlot: candidates.map(ruleSlot).min(),
            viaStandIn: viaStandIn, isDetached: series.isDetached)
        let firstStart = try? firstSlot.get()
        let firstSlotCause: DeletedOccurrenceCheck.FirstSlotCause = {
            if case .failure(let failure) = firstSlot { return failure.cause }
            return .notShown
        }()
        // #506: whole only up to the end of the unbroken listing from the first start (with no range
        // around now, the listing's end, as before).
        let covers = firstStart.map {
            DeletedOccurrenceCheck.coversWholeSeries(rules: extents, firstStart: $0, ranges: ranges, calendar: calendar)
        } ?? false
        return DeletedOccurrenceCheck.verdict(
            rules: (series.recurrenceRules ?? []).map(DeletedOccurrenceCheck.Rule.init),
            firstStart: firstStart,
            observedSlots: candidates.map(ruleSlot), uneditedSlots: candidates.filter { !$0.isDetached }.map(ruleSlot),
            slotsTrusted: !candidates.contains { $0.isDetached && !$0.slotFromRID },
            changesAllDay: changesAllDay, reachedFrom: reachedFrom, scannedTo: listedTo, coversWholeSeries: covers, calendar: calendar,
            isAllDay: series.isAllDay, firstSlotCause: firstSlotCause, listed: ranges, horizon: horizon)
    }

    /// PR #505 round 5 (MEDIUM): whether a whole-series write's planned dates can be compared with the
    /// stored ones. They are the first occurrence's shown times, which are its slot only when it was not
    /// edited on its own and its slot is shown; otherwise `.unproven`, and any date in the call is checked.
    /// Round 6 (LOW 5): also the proven first slot itself, which a planned start is compared with.
    func wholeSeriesBaseline(of series: EKEvent, id: String, viaStandIn: Bool) -> (baseline: DeletedOccurrenceCheck.StoredBaseline, slot: Date?) {
        guard let (_, candidates) = seriesOccurrences(of: series, id: id), !candidates.isEmpty else { return (.unproven, nil) }
        let zone = series.isAllDay ? TimeZone.current : (series.timeZone ?? .current)
        func ruleSlot(_ candidate: FirstRemainingOccurrence.Candidate) -> Date {
            UndoPostState.ruleSlot(of: candidate, isAllDay: series.isAllDay, zone: zone)
        }
        let atStart = candidates.filter { UndoPostState.sameInstant($0.start, series.startDate) }
        let slot = DeletedOccurrenceCheck.firstSlot(
            occurrenceDate: series.occurrenceDate, startDate: series.startDate, startMatches: atStart.count,
            startRIDSlot: atStart.first.flatMap { $0.slotFromRID ? ruleSlot($0) : nil },
            earliestListedSlot: candidates.map(ruleSlot).min(), viaStandIn: viaStandIn, isDetached: series.isDetached)
        return (DeletedOccurrenceCheck.baseline(firstSlot: slot, firstIsEdited: atStart.first?.isDetached ?? true, startDate: series.startDate), slot)
    }

    /// #416: the series object of the occurrence with this `/RID=` identifier, which may fail to
    /// refresh (#326). nil without a `/RID=` part: nothing says what the series' identifier is.
    func seriesObject(ofOccurrence id: String) throws -> EKEvent? {
        try DetachedOccurrenceSpan.seriesIdentifier(of: id).flatMap { try storedEvent(id: $0) }
    }

    /// #428: the identifier of the occurrence edited on its own that comes first in the series
    /// `id`, when `id` resolves to nothing else. A series with no stored object, or one with an
    /// unedited occurrence first, is not this.
    /// `excluding` (PR #465 verify r1): occurrences a dry run counts as deleted by earlier rows of
    /// the same call, so it answers as the real call does when it gets to this row.
    func firstEditedOccurrenceID(of id: String, excluding gone: Set<String> = []) throws -> (id: String, allEdited: Bool, firstDeleted: Bool)? {
        guard let stored = try storedEvent(id: id), let (_, listed) = seriesOccurrences(of: stored, id: id),
              case let candidates = listed.filter({ !gone.contains($0.eventIdentifier ?? "") }),
              let index = FirstRemainingOccurrence.earliestEdited(candidates, identifier: id, isAllDay: stored.isAllDay),
              let first = candidates[index].eventIdentifier else { return nil }
        let firstStart: Date? = stored.startDate
        return (first, !candidates.contains { !$0.isDetached },
                FirstRemainingOccurrence.firstSlotDeleted(candidates[index], firstStart: firstStart, isAllDay: stored.isAllDay))
    }

    /// #416: what is left of the series around `occurrence`, an occurrence edited on its own and
    /// addressed by its own `id`. nil when the series cannot be listed or the scan did not reach
    /// the occurrence. `seriesOccurrences` reads the series object with care, so one that fails to
    /// refresh (#326) is fine here. `namedInTheCall`: see `DetachedOccurrenceSpan.neighbours`.
    func occurrenceNeighbours(of occurrence: EKEvent, id: String, namedInTheCall: Set<String> = []) throws -> DetachedOccurrenceSpan.Neighbours? {
        guard let seriesID = DetachedOccurrenceSpan.seriesIdentifier(of: id),
              let series = try storedEvent(id: seriesID),
              let (listed, candidates) = seriesOccurrences(of: series, id: seriesID),
              let window = seriesScanWindow(of: series),
              let scannedTo = SeriesExceptionsPlanner.listingRanges(for: window).map(\.end).max(),
              let slot = UndoPostState.ruleSlot(eventIdentifier: id, externalIdentifier: occurrence.calendarItemExternalIdentifier,
                                                occurrenceDate: occurrence.occurrenceDate, isAllDay: series.isAllDay) else { return nil }
        let firstStart: Date? = series.startDate
        guard let firstStart else { return nil }
        let rules = series.recurrenceRules ?? []
        let covers = DetachedOccurrenceSpan.coversWholeSeries(
            rules: rules.map(DetachedOccurrenceSpan.RuleExtent.init),
            firstStart: firstStart, scannedTo: scannedTo, calendar: Calendar.gregorian(in: series.timeZone ?? .current))
        var known = DetachedOccurrenceSpan.neighbours(
            of: id, slot: slot, among: candidates, coversWholeSeries: covers, namedInTheCall: namedInTheCall,
            own: UndoPostState.ownValues(of: occurrence, slot: slot, firstStart: firstStart,
                                         series: listed.first { !$0.isDetached }),
            isAllDay: series.isAllDay)
        known?.seriesTime = DetachedOccurrenceSpan.seriesTimeFacts(
            of: id, among: candidates, coversWholeSeries: covers,
            measuredRule: DetachedOccurrenceSpan.isMeasuredSeries(isAllDay: series.isAllDay, rules: rules),
            countBounded: !rules.isEmpty && rules.allSatisfy { ($0.recurrenceEnd?.occurrenceCount ?? 0) > 0 },
            firstStart: firstStart, isAllDay: series.isAllDay)
        return known
    }

    /// #416: the refusal of a span `all` delete of `event`, resolved from `id`, or nil.
    /// verify r6: the refusal of `delete_event` span `future` through the first occurrence by slot
    /// when it was edited to start after another occurrence, or nil.
    func movedFirstDeleteRefusal(_ event: EKEvent, id: String) throws -> String? {
        try DetachedOccurrenceSpan.movedFirstDeleteRefusal(identifier: id, isDetached: event.isDetached,
                                                           neighbours: try occurrenceNeighbours(of: event, id: id))
    }

    func seriesDeleteRefusal(_ event: EKEvent, id: String, namedInTheCall: Set<String> = [], batch: Bool = false) throws -> String? {
        try DetachedOccurrenceSpan.seriesDeleteRefusal(identifier: id, isDetached: event.isDetached, batch: batch,
                                                       neighbours: try occurrenceNeighbours(of: event, id: id, namedInTheCall: namedInTheCall))
    }

    /// #416: whether `date` is the day of `occurrence`, by the time it shows or by its original slot:
    /// a caller can hold either for an occurrence that was moved.
    func occurrenceDateMatches(_ date: Date?, occurrence: EKEvent, id: String) -> Bool {
        guard let date else { return true }
        let slot = UndoPostState.originalSlot(eventIdentifier: id, externalIdentifier: occurrence.calendarItemExternalIdentifier,
                                              occurrenceDate: occurrence.occurrenceDate)
        return [occurrence.startDate, slot].contains {
            OccurrenceDay.startsOnRequestedDay(occurrenceStart: $0, isAllDay: occurrence.isAllDay, requested: date,
                                               in: Self.occurrenceZone(of: occurrence))
        }
    }

    /// The earliest remaining occurrence of the series `stale` (a series object whose `refresh()`
    /// failed), refreshed, or nil when the series has none (`FirstRemainingOccurrence.pick`) in
    /// the scan window (`UndoPostState.seriesScanWindow`: from a day before the series' first
    /// start, at most 1460 days) or the occurrence does not refresh either.
    ///
    /// The object failed to refresh, so its fields are read with care (verify round 1): only a
    /// series with rules is searched (a one-off or a deleted event is not, which also spares the
    /// scan), `startDate` is optional-checked, and the series' own calendar is required, never
    /// widened to all calendars.
    func firstRemainingOccurrence(of stale: EKEvent, id: String, refuseWhenEditedBefore: Bool = true,
                                  goneInTheCall: Set<String> = []) -> EKEvent? {
        guard let (listed, candidates) = seriesOccurrences(of: stale, id: id) else { return nil }
        guard let index = FirstRemainingOccurrence.pick(candidates, identifier: id, refuseWhenEditedBefore: refuseWhenEditedBefore,
                                                        goneInTheCall: goneInTheCall),
              listed[index].refresh() else { return nil }
        return listed[index]
    }
}
