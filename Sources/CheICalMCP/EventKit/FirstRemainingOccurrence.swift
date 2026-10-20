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
enum FirstRemainingOccurrence {
    struct Candidate: Equatable {
        let eventIdentifier: String?
        let isDetached: Bool
        let hasRecurrenceRules: Bool
        let start: Date
    }

    /// The index of the earliest qualifying candidate (the first listed on a tie), or nil.
    static func pick(_ candidates: [Candidate], identifier: String) -> Int? {
        var best: Int?
        for (index, candidate) in candidates.enumerated() {
            guard candidate.eventIdentifier == identifier, !candidate.isDetached, candidate.hasRecurrenceRules else { continue }
            if let kept = best, candidates[kept].start <= candidate.start { continue }
            best = index
        }
        return best
    }
}

extension EventKitManager {
    /// The earliest remaining occurrence of the series `stale` (a series object whose `refresh()`
    /// failed), refreshed, or nil when the series has none left in the scan window
    /// (`UndoPostState.seriesScanWindow`: from a day before the series' first start, at most 1460
    /// days) or the occurrence does not refresh either. The series' own calendar is read when it
    /// can be, all calendars otherwise; the identifier decides.
    func firstRemainingOccurrence(of stale: EKEvent, id: String) -> EKEvent? {
        let window = UndoPostState.seriesScanWindow(of: stale)
        let calendars = stale.calendar.map { [$0] }
        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        var listed: [EKEvent] = []
        eventStore.enumerateEvents(matching: predicate) { event, _ in
            if event.eventIdentifier == id { listed.append(event) }
        }
        let candidates = listed.map {
            FirstRemainingOccurrence.Candidate(eventIdentifier: $0.eventIdentifier, isDetached: $0.isDetached,
                                               hasRecurrenceRules: $0.hasRecurrenceRules, start: $0.startDate)
        }
        guard let index = FirstRemainingOccurrence.pick(candidates, identifier: id), listed[index].refresh() else { return nil }
        return listed[index]
    }
}
