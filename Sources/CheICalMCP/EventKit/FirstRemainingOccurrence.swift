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
/// occurrence would stay behind while the call reported success. The series then stays not found,
/// and the edited occurrence's own `<series>/RID=…` id is the way in.
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
    }

    /// The index of the earliest qualifying candidate (the first listed on a tie), or nil, also
    /// when an edited occurrence of the series has a slot before it.
    ///
    /// `refuseWhenEditedBefore: false` skips that refusal, for the writes it does not apply to: a
    /// move changes the calendar of the whole series and a copy copies one occurrence, so neither
    /// leaves an edited occurrence behind (device, iCloud, 2026-10-21), whereas a delete from the
    /// stand-in does.
    static func pick(_ candidates: [Candidate], identifier: String, refuseWhenEditedBefore: Bool = true) -> Int? {
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
            guard candidate.isDetached else { return false }
            let id = candidate.eventIdentifier
            let ofTheSeries = id == identifier || (id?.hasPrefix(identifier + "/") ?? false) || candidate.sameSeriesByExternalID
            return ofTheSeries && (candidate.slot ?? candidate.start) < standIn
        }
        return editedBefore ? nil : best
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
    /// The earliest remaining occurrence of the series `stale` (a series object whose `refresh()`
    /// failed), refreshed, or nil when the series has none (`FirstRemainingOccurrence.pick`) in
    /// the scan window (`UndoPostState.seriesScanWindow`: from a day before the series' first
    /// start, at most 1460 days) or the occurrence does not refresh either.
    ///
    /// The object failed to refresh, so its fields are read with care (verify round 1): only a
    /// series with rules is searched (a one-off or a deleted event is not, which also spares the
    /// scan), `startDate` is optional-checked, and the series' own calendar is required, never
    /// widened to all calendars.
    func firstRemainingOccurrence(of stale: EKEvent, id: String, refuseWhenEditedBefore: Bool = true) -> EKEvent? {
        guard stale.hasRecurrenceRules, let calendar = stale.calendar else { return nil }
        let firstStart: Date? = stale.startDate
        guard let firstStart else { return nil }
        let ruleEnds = (stale.recurrenceRules ?? []).map { $0.recurrenceEnd?.endDate }
        let ruleEnd = ruleEnds.contains(where: { $0 == nil }) ? nil : ruleEnds.compactMap { $0 }.max()
        let window = UndoPostState.seriesScanWindow(firstStart: firstStart, ruleEnd: ruleEnd)
        let series = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: stale.calendarItemExternalIdentifier)
        var listed: [EKEvent] = []
        var byExternalID: [Bool] = []
        // The window and a year on each side, as #285's exception capture lists them (verify round
        // 3): an edited occurrence moved a few months out of the window blocks the stand-in too.
        for range in SeriesExceptionsPlanner.listingRanges(for: window) {
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
                sameSeriesByExternalID: external)
        }
        guard let index = FirstRemainingOccurrence.pick(candidates, identifier: id, refuseWhenEditedBefore: refuseWhenEditedBefore),
              listed[index].refresh() else { return nil }
        return listed[index]
    }
}
