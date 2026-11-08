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
    /// #319: how a series' rules end (`SeriesExceptionsPlanner.seriesEnd`): open, by end date, by a
    /// count's last possible slot, or unknown. With the series' start it places
    /// `SeriesExceptionsPlanner.deleteWindow`.
    func seriesEnd(of series: Event) -> SeriesExceptionsPlanner.SeriesEnd
    func startDate(of event: Event) -> Date
    /// The slot the rules gave an occurrence: its `occurrenceDate`, else its start.
    func slot(of occurrence: Event) -> Date
    /// The occurrence as the capture records it.
    func observed(_ occurrence: Event) -> SeriesExceptionsPlanner.ObservedOccurrence
    /// The events of one query over `range` in `event`'s calendar, in the order the store lists
    /// them (none when it has no calendar). Callers pass only a listing range of the delete window
    /// (#319) or the recorded window, at most 1460 days plus a year (`EventRangeQueryTests` pins them).
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

    /// The events in `calendar` from `slot` for `length` (at least a minute), each with its
    /// identifiers and rule slot, read after a refresh when this server wrote since the last one
    /// (`OccurrenceSlotGuard`, #321).
    func slotHolders(at slot: Date, length: TimeInterval, in calendar: Calendar) -> [OccurrenceSlotGuard.SeriesHolder]
    /// #321: notes that undo recreated the series recorded as `recorded` as `recreated`.
    func noteRecreation(of recorded: UndoPostState.OccurrenceIDs, as recreated: UndoPostState.OccurrenceIDs)
    /// #321: the series undo recreated from `recorded` in this process (`SeriesRecreations`).
    func recreations(of recorded: UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs]
}

/// The production `SeriesExceptionsStoreSource`: `EventKitManager`'s store, and the manager's own
/// helpers for the calls that need it (`restoreCalendar(for:kind:)`, `storedEvent`, the refresh
/// flags), passed in as closures. `EventKitManager` builds it inside its own isolation and uses it there only.
final class EventKitSeriesExceptionsStore: SeriesExceptionsStoreSource {
    typealias Event = EKEvent
    typealias Calendar = EKCalendar

    private let eventStore: EKEventStore
    private let readRestoreCalendar: (EventSnapshot, EventRestoreKind) async throws -> EKCalendar
    private let storedEvent: (String) throws -> EKEvent?
    private let markRefresh: () -> Void
    private let refreshIfNeeded: () -> Void
    private let note: (UndoPostState.OccurrenceIDs, UndoPostState.OccurrenceIDs) -> Void
    private let readRecreations: (UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs]

    init(eventStore: EKEventStore,
         restoreCalendar: @escaping (EventSnapshot, EventRestoreKind) async throws -> EKCalendar,
         storedEvent: @escaping (String) throws -> EKEvent?,
         markNeedsRefresh: @escaping () -> Void,
         refreshIfNeeded: @escaping () -> Void,
         noteRecreation: @escaping (UndoPostState.OccurrenceIDs, UndoPostState.OccurrenceIDs) -> Void,
         recreations: @escaping (UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs]) {
        self.eventStore = eventStore
        self.readRestoreCalendar = restoreCalendar
        self.storedEvent = storedEvent
        self.markRefresh = markNeedsRefresh
        self.refreshIfNeeded = refreshIfNeeded
        self.note = noteRecreation
        self.readRecreations = recreations
    }

    func identifiers(of event: EKEvent) -> UndoPostState.OccurrenceIDs {
        UndoPostState.OccurrenceIDs(eventIdentifier: event.eventIdentifier, externalIdentifier: event.calendarItemExternalIdentifier)
    }

    func hasCalendar(_ event: EKEvent) -> Bool { event.calendar != nil }

    func seriesEnd(of series: EKEvent) -> SeriesExceptionsPlanner.SeriesEnd {
        // In the event's zone, where the rule runs (as `DetachedOccurrenceSpan.coversWholeSeries`' callers read it).
        SeriesExceptionsPlanner.seriesEnd(rules: (series.recurrenceRules ?? []).map(DetachedOccurrenceSpan.RuleExtent.init),
                                          firstStart: series.startDate, calendar: Foundation.Calendar.gregorian(in: series.timeZone ?? .current))
    }

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
        return try storedEvent(id) != nil
    }

    func markNeedsRefresh() { markRefresh() }

    func slotHolders(at slot: Date, length: TimeInterval, in calendar: EKCalendar) -> [OccurrenceSlotGuard.SeriesHolder] {
        refreshIfNeeded()
        let end = slot.addingTimeInterval(max(length, 60))
        var holders: [OccurrenceSlotGuard.SeriesHolder] = []
        eventStore.enumerateEvents(matching: eventStore.predicateForEvents(withStart: slot, end: end,
                                                                           calendars: [calendar])) { event, _ in
            holders.append(OccurrenceSlotGuard.holder(eventIdentifier: event.eventIdentifier,
                                                      externalIdentifier: event.calendarItemExternalIdentifier,
                                                      occurrenceDate: event.occurrenceDate, isAllDay: event.isAllDay,
                                                      startDate: event.startDate))
        }
        return holders
    }

    func noteRecreation(of recorded: UndoPostState.OccurrenceIDs, as recreated: UndoPostState.OccurrenceIDs) {
        note(recorded, recreated)
    }

    func recreations(of recorded: UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs] {
        readRecreations(recorded)
    }
}
