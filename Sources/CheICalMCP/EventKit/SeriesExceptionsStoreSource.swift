import EventKit
import Foundation

/// #322: the narrow seam of the delete-undo exceptions layer (#285), per the CLAUDE.md Test Seam
/// Convention: a `<Domain>Source` scoped to what `SeriesExceptionsUndo` needs, not a widening of
/// `EventKitManaging`. `Event` is the store's event type (`EKEvent` in production), so the code
/// runs against a fake in tests. Production uses `EventKitSeriesExceptionsStore`, built by
/// `EventKitManager` on its own store. A test runs `SeriesExceptionsUndo` on a fake directly, or
/// passes one through `EventKitManager.forTesting(probe:seriesExceptionsStore:)`, which only the two
/// undo arms read: the record sites' capture always runs on the manager's own store.
///
/// Every requirement is one EventKit call (or the manager helper that already wrapped it), so
/// moving the code behind the seam keeps the order of the calls (#322: no behaviour change).
protocol SeriesExceptionsStoreSource {
    associatedtype Event
    associatedtype Calendar

    /// The event's identifier and external identifier (`UndoPostState.OccurrenceIDs`).
    func identifiers(of event: Event) -> UndoPostState.OccurrenceIDs
    /// Whether the event has a calendar (a series without one is not listed or restored).
    func hasCalendar(_ event: Event) -> Bool
    /// `UndoPostState.seriesScanWindow(of:)` of a series.
    func scanWindow(of series: Event) -> DateInterval
    func startDate(of event: Event) -> Date
    /// The slot the rules gave an occurrence: its `occurrenceDate`, else its start.
    func slot(of occurrence: Event) -> Date
    /// The occurrence as the capture records it.
    func observed(_ occurrence: Event) -> SeriesExceptionsPlanner.ObservedOccurrence
    /// The events of one query over `range` in `event`'s calendar, in the order the store lists
    /// them (none when it has no calendar). Callers pass only a listing range of the scan window
    /// or the recorded window, at most 1460 days plus a year (`EventRangeQueryTests` pins them).
    func events(in range: DateInterval, inCalendarOf event: Event) -> [Event]

    /// A new, unsaved event in the store.
    func makeEvent() -> Event
    /// The recorded calendar of `snapshot` as an event undo reads it (#269,
    /// `EventKitManager.restoreCalendar(for:kind:)`): access checked, the view refreshed, and read
    /// once more after a miss before `EventKitError.undoCalendarMissing` stands.
    func restoreCalendar(for snapshot: EventSnapshot, kind: EventRestoreKind) async throws -> Calendar
    /// The recorded calendar of `snapshot` from the calendars the store lists now, without the
    /// #269 read (the one-offs of an exceptions restore, which go into the calendar the recreated
    /// series was just saved in).
    func calendarNow(for snapshot: EventSnapshot, kind: EventRestoreKind) throws -> Calendar
    /// Writes `snapshot`'s fields onto `event` in `calendar` (`EventSnapshot.apply`).
    func apply(_ snapshot: EventSnapshot, to event: Event, calendar: Calendar)
    /// Saves `event` with span "this".
    func save(_ event: Event) throws
    func remove(_ event: Event, span: EKSpan) throws
    /// Whether the store holds an event under `event`'s identifier.
    /// Throws when the lookup failed (#288): that is not "not stored".
    func isStored(_ event: Event) throws -> Bool
    func markNeedsRefresh()

    /// The events in `calendar` from `snapshot`'s start for its length (at least a minute), read
    /// after a refresh when this server wrote since the last one (`OccurrenceSlotGuard`).
    func slotHolders(for snapshot: EventSnapshot, in calendar: Calendar) -> [OccurrenceSlotGuard.Holder]
}

/// The production `SeriesExceptionsStoreSource`: `EventKitManager`'s store, and the manager's own
/// helpers for the calls that need it (`restoreCalendar(for:kind:)`, `eventLookup`, the refresh
/// flags), passed in as closures. `EventKitManager` builds it inside its own isolation and uses it there only.
final class EventKitSeriesExceptionsStore: SeriesExceptionsStoreSource {
    typealias Event = EKEvent
    typealias Calendar = EKCalendar

    private let eventStore: EKEventStore
    private let readRestoreCalendar: (EventSnapshot, EventRestoreKind) async throws -> EKCalendar
    private let eventLookup: (String) -> EventLookupOutcome
    private let markRefresh: () -> Void
    private let refreshIfNeeded: () -> Void

    init(eventStore: EKEventStore,
         restoreCalendar: @escaping (EventSnapshot, EventRestoreKind) async throws -> EKCalendar,
         eventLookup: @escaping (String) -> EventLookupOutcome,
         markNeedsRefresh: @escaping () -> Void,
         refreshIfNeeded: @escaping () -> Void) {
        self.eventStore = eventStore
        self.readRestoreCalendar = restoreCalendar
        self.eventLookup = eventLookup
        self.markRefresh = markNeedsRefresh
        self.refreshIfNeeded = refreshIfNeeded
    }

    func identifiers(of event: EKEvent) -> UndoPostState.OccurrenceIDs {
        UndoPostState.OccurrenceIDs(eventIdentifier: event.eventIdentifier, externalIdentifier: event.calendarItemExternalIdentifier)
    }

    func hasCalendar(_ event: EKEvent) -> Bool { event.calendar != nil }

    func scanWindow(of series: EKEvent) -> DateInterval { UndoPostState.seriesScanWindow(of: series) }

    func startDate(of event: EKEvent) -> Date { event.startDate }

    func slot(of occurrence: EKEvent) -> Date { occurrence.occurrenceDate ?? occurrence.startDate }

    func observed(_ occurrence: EKEvent) -> SeriesExceptionsPlanner.ObservedOccurrence {
        SeriesExceptionsPlanner.ObservedOccurrence(
            ids: .init(eventIdentifier: occurrence.eventIdentifier, externalIdentifier: occurrence.calendarItemExternalIdentifier),
            isDetached: occurrence.isDetached, occurrenceDate: occurrence.occurrenceDate, startDate: occurrence.startDate,
            snapshot: EventSnapshot(from: occurrence, includeRecurrence: false))
    }

    func events(in range: DateInterval, inCalendarOf event: EKEvent) -> [EKEvent] {
        guard let calendar = event.calendar else { return [] }
        var listed: [EKEvent] = []
        eventStore.enumerateEvents(matching: eventStore.predicateForEvents(withStart: range.start, end: range.end,
                                                                           calendars: [calendar])) { occurrence, _ in
            listed.append(occurrence)
        }
        return listed
    }

    func makeEvent() -> EKEvent { EKEvent(eventStore: eventStore) }

    func restoreCalendar(for snapshot: EventSnapshot, kind: EventRestoreKind) async throws -> EKCalendar {
        try await readRestoreCalendar(snapshot, kind)
    }

    func calendarNow(for snapshot: EventSnapshot, kind: EventRestoreKind) throws -> EKCalendar {
        try snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier }, for: kind)
    }

    func apply(_ snapshot: EventSnapshot, to event: EKEvent, calendar: EKCalendar) { snapshot.apply(to: event, calendar: calendar) }

    func save(_ event: EKEvent) throws { try eventStore.save(event, span: .thisEvent) }

    func remove(_ event: EKEvent, span: EKSpan) throws { try eventStore.remove(event, span: span) }

    func isStored(_ event: EKEvent) throws -> Bool {
        guard let id = event.eventIdentifier else { return false }
        switch eventLookup(id) {
        case .found: return true
        case .absent: return false
        case .failed: throw EventKitError.eventLookupFailed(identifier: id)
        }
    }

    func markNeedsRefresh() { markRefresh() }

    func slotHolders(for snapshot: EventSnapshot, in calendar: EKCalendar) -> [OccurrenceSlotGuard.Holder] {
        refreshIfNeeded()
        let end = max(snapshot.endDate, snapshot.startDate.addingTimeInterval(60))
        var holders: [OccurrenceSlotGuard.Holder] = []
        eventStore.enumerateEvents(matching: eventStore.predicateForEvents(withStart: snapshot.startDate, end: end,
                                                                           calendars: [calendar])) { event, _ in
            holders.append(.init(title: event.title, startDate: event.startDate, hasRecurrenceRules: event.hasRecurrenceRules))
        }
        return holders
    }
}
