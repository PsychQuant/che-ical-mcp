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
    }

    /// The index of the earliest qualifying candidate (the first listed on a tie), or nil, also
    /// when an edited occurrence of the series has a slot before it.
    static func pick(_ candidates: [Candidate], identifier: String) -> Int? {
        var best: Int?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.eventIdentifier == identifier, !candidate.isDetached, candidate.hasRecurrenceRules else { continue }
            if let kept = best, candidates[kept].start <= candidate.start { continue }
            best = index
        }
        guard let best else { return nil }
        let standIn = candidates[best].start
        let editedBefore = candidates.contains { candidate in
            guard candidate.isDetached, let id = candidate.eventIdentifier, id.hasPrefix(identifier + "/") else { return false }
            return (candidate.slot ?? candidate.start) < standIn
        }
        return editedBefore ? nil : best
    }

    /// The flow of `freshEvent`, with the lookup result, the refresh and the stand-in injected so
    /// that each branch is tested without an event store: the stored object when it refreshes (the
    /// stand-in is not asked for), the stand-in when it does not, nil when nothing is stored or no
    /// stand-in exists.
    static func resolve<Event>(stored: Event?, refresh: (Event) -> Bool, standIn: (Event) -> Event?) -> Event? {
        guard let stored else { return nil }
        return refresh(stored) ? stored : standIn(stored)
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
    func firstRemainingOccurrence(of stale: EKEvent, id: String) -> EKEvent? {
        guard stale.hasRecurrenceRules, let calendar = stale.calendar else { return nil }
        let firstStart: Date? = stale.startDate
        guard let firstStart else { return nil }
        let ruleEnds = (stale.recurrenceRules ?? []).map { $0.recurrenceEnd?.endDate }
        let ruleEnd = ruleEnds.contains(where: { $0 == nil }) ? nil : ruleEnds.compactMap { $0 }.max()
        let window = UndoPostState.seriesScanWindow(firstStart: firstStart, ruleEnd: ruleEnd)
        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
        var listed: [EKEvent] = []
        eventStore.enumerateEvents(matching: predicate) { event, _ in
            let ids = UndoPostState.OccurrenceIDs(eventIdentifier: event.eventIdentifier,
                                                  externalIdentifier: event.calendarItemExternalIdentifier)
            if event.eventIdentifier == id
                || UndoPostState.isOccurrence(ids, of: .init(eventIdentifier: id, externalIdentifier: nil)) {
                listed.append(event)
            }
        }
        let candidates = listed.map {
            FirstRemainingOccurrence.Candidate(
                eventIdentifier: $0.eventIdentifier, isDetached: $0.isDetached,
                hasRecurrenceRules: $0.hasRecurrenceRules, start: $0.startDate,
                slot: UndoPostState.originalSlot(eventIdentifier: $0.eventIdentifier, externalIdentifier: nil,
                                                 occurrenceDate: $0.occurrenceDate))
        }
        guard let index = FirstRemainingOccurrence.pick(candidates, identifier: id), listed[index].refresh() else { return nil }
        return listed[index]
    }
}
