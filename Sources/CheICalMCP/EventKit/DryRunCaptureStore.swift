import EventKit
import Foundation

/// PR #558 fix round 5 (verify finding Q2): the store the forecast of a `delete_events_batch` dry run captures
/// a series through (`EventKitManager.previewUndoForecast`). It is `base`, except that a listing leaves out the
/// events whose own event identifier is in `gone`: the occurrences the call's earlier rows delete, which the
/// real call's series row, run after them, no longer lists. They are left out by identity, before the capture
/// reduces an occurrence to its slot, so an occurrence whose `/RID=` is only in its external identifier is left
/// out too, and another occurrence recorded at the same slot is kept. The series' own identifier, which its
/// occurrences not edited on their own share, is never left out. The capture itself
/// (`SeriesExceptionsUndo.capture`) is `main`'s, and no delete captures through this store.
struct DryRunCaptureStore<Base: SeriesExceptionsStoreSource>: SeriesExceptionsStoreSource {
    typealias Event = Base.Event
    typealias Calendar = Base.Calendar

    let base: Base
    let gone: Set<String>

    func events(in range: DateInterval, inCalendarOf event: Event) -> [Event] {
        let left = gone.subtracting([base.identifiers(of: event).eventIdentifier ?? ""])
        return base.events(in: range, inCalendarOf: event).filter { !left.contains(base.identifiers(of: $0).eventIdentifier ?? "") }
    }

    func identifiers(of event: Event) -> UndoPostState.OccurrenceIDs { base.identifiers(of: event) }
    func hasCalendar(_ event: Event) -> Bool { base.hasCalendar(event) }
    func seriesEnd(of series: Event) -> SeriesExceptionsPlanner.SeriesEnd { base.seriesEnd(of: series) }
    func startDate(of event: Event) -> Date { base.startDate(of: event) }
    func slot(of occurrence: Event) -> Date { base.slot(of: occurrence) }
    func observed(_ occurrence: Event) -> SeriesExceptionsPlanner.ObservedOccurrence { base.observed(occurrence) }
    func makeEvent() -> Event { base.makeEvent() }
    func restoreCalendar(for snapshot: EventSnapshot, kind: EventRestoreKind) async throws -> Calendar {
        try await base.restoreCalendar(for: snapshot, kind: kind)
    }
    func calendarNow(for snapshot: EventSnapshot, kind: EventRestoreKind) throws -> Calendar { try base.calendarNow(for: snapshot, kind: kind) }
    func apply(_ snapshot: EventSnapshot, to event: Event, calendar: Calendar) { base.apply(snapshot, to: event, calendar: calendar) }
    func save(_ event: Event) throws { try base.save(event) }
    func remove(_ event: Event, span: EKSpan) throws { try base.remove(event, span: span) }
    func isStored(_ event: Event) throws -> Bool { try base.isStored(event) }
    func markNeedsRefresh() { base.markNeedsRefresh() }
    func slotHolders(at slot: Date, length: TimeInterval, in calendar: Calendar) -> [OccurrenceSlotGuard.SeriesHolder] {
        base.slotHolders(at: slot, length: length, in: calendar)
    }
    func noteRecreation(of recorded: UndoPostState.OccurrenceIDs, as recreated: UndoPostState.OccurrenceIDs) {
        base.noteRecreation(of: recorded, as: recreated)
    }
    func recreations(of recorded: UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs] { base.recreations(of: recorded) }
}
