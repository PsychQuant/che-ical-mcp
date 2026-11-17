import EventKit
import Foundation
@testable import CheICalMCP

/// #322: an in-memory `SeriesExceptionsStoreSource` for the delete-undo exceptions layer
/// (`SeriesExceptionsUndo`). Its events follow what the device showed for iCloud (#285, #311):
/// the occurrences of a series share the series' identifier and external identifier, report
/// `hasRecurrenceRules`, and carry the slot their rule gave them in `occurrenceDate`. An
/// occurrence edited on its own is `detached`; a test that needs it as iCloud shows it sets its
/// identifiers to `<series id>/RID=<seconds since 2001>` and may let its `occurrenceDate` drift
/// (`SeriesExceptionsUndoTests` does, for the capture). Saving and listing are simplified: a saved
/// series generates `seriesSlots`, a listing is every event starting in the range.
/// `log` records every write and listing in order, so a test can pin the order of the calls.
final class FakeSeriesExceptionsStore: SeriesExceptionsStoreSource {
    final class Event {
        var id: String?
        var external: String?
        var calendar: String?
        var title: String
        var start: Date
        var occurrenceDate: Date?
        var detached: Bool
        var hasRules: Bool
        /// #539: the end its snapshot reads; an hour after `start` when nil.
        var end: Date?
        /// PR #558 round 1 (ruling A): the event is timed and has no time zone (`isFloating`). False
        /// by default, as a new event has a zone, so a test of a series without one says so.
        var floating = false

        init(id: String? = nil, external: String? = nil, calendar: String? = nil, title: String = "",
             start: Date = .distantPast, occurrenceDate: Date? = nil, detached: Bool = false, hasRules: Bool = false) {
            self.id = id
            self.external = external
            self.calendar = calendar
            self.title = title
            self.start = start
            self.occurrenceDate = occurrenceDate
            self.detached = detached
            self.hasRules = hasRules
        }
    }

    typealias Calendar = String

    struct Failure: Error, Equatable { let what: String }

    /// What the store holds.
    private(set) var events: [Event] = []
    private(set) var log: [String] = []
    private(set) var refreshMarks = 0
    /// The slots a series saved into this store generates (its own start first).
    var seriesSlots: [Date] = []
    /// #319: `seriesEnd(of:)` of every series.
    var seriesEnd: SeriesExceptionsPlanner.SeriesEnd = .open
    /// #319: how many occurrences `observed(_:)` built a snapshot for.
    private(set) var observedCount = 0
    /// Saves of events with these titles throw (after taking an identifier, as a save that may have
    /// written would leave it).
    var failingSaveTitles: Set<String> = []
    /// What those saves throw; the fake's own `Failure` when nil (#398).
    var saveFailure: Error?
    /// `remove(_:span: .thisEvent)` of an occurrence at one of these slots throws `removalFailure`
    /// (the fake's own `Failure` when nil) and removes nothing (#398).
    var failingRemovalSlots: Set<Date> = []
    var removalFailure: Error?
    /// `remove(_:span: .futureEvents)` throws.
    var seriesRemovalFails = false
    /// Calendar identifiers the store does not hold: the restore's calendar reads throw for them
    /// what production throws (`EventSnapshot.resolveCalendar` over no matching calendar, #269).
    var missingCalendars: Set<String> = []
    private var nextID = 1
    /// #539: the host zone `slotHolders` reads an all-day `/RID=`'s local day in.
    var zone: TimeZone = .current

    /// A series already in the store: one occurrence per slot, sharing `id`. `floating`: the series
    /// has no time zone (PR #558 round 1).
    @discardableResult
    func addSeries(id: String, calendar: String, title: String, slots: [Date], floating: Bool = false) -> [Event] {
        let occurrences = slots.map { slot -> Event in
            let event = Event(id: id, external: "X-\(id)", calendar: calendar, title: title, start: slot, occurrenceDate: slot, hasRules: true)
            event.floating = floating
            return event
        }
        events += occurrences
        return occurrences
    }

    func add(_ event: Event) { events.append(event) }

    /// #539: takes `event` out of the store, as a delete does (no log entry).
    func drop(_ event: Event) { events.removeAll { $0 === event } }

    /// #538 fix 1 (F20): a saved series reads back under its first occurrence's own identifier
    /// (`<id>/RID=<seconds since 2001>`), as a store can hand back an occurrence for a series.
    var seriesReadsBackAsItsFirstOccurrence = false

    func identifiers(of event: Event) -> UndoPostState.OccurrenceIDs {
        if seriesReadsBackAsItsFirstOccurrence, event.hasRules, let id = event.id {
            return UndoPostState.OccurrenceIDs(eventIdentifier: "\(id)/RID=\(Int(event.start.timeIntervalSinceReferenceDate))",
                                               externalIdentifier: event.external)
        }
        return UndoPostState.OccurrenceIDs(eventIdentifier: event.id, externalIdentifier: event.external)
    }

    func hasCalendar(_ event: Event) -> Bool { event.calendar != nil }

    func seriesEnd(of series: Event) -> SeriesExceptionsPlanner.SeriesEnd { seriesEnd }

    func startDate(of event: Event) -> Date { event.start }

    func isFloating(_ series: Event) -> Bool { series.floating }

    func slot(of occurrence: Event) -> Date { occurrence.occurrenceDate ?? occurrence.start }

    func observed(_ occurrence: Event) -> SeriesExceptionsPlanner.ObservedOccurrence {
        observedCount += 1
        return SeriesExceptionsPlanner.ObservedOccurrence(
            ids: identifiers(of: occurrence), isDetached: occurrence.detached, occurrenceDate: occurrence.occurrenceDate,
            startDate: occurrence.start, snapshot: UndoSnapshotFixtures.event(title: occurrence.title, startDate: occurrence.start,
                                                                              endDate: occurrence.end))
    }

    func events(in range: DateInterval, inCalendarOf event: Event) -> [Event] {
        guard let calendar = event.calendar else { return [] }
        log.append("list")
        return events.filter { $0.calendar == calendar && $0.start >= range.start && $0.start < range.end }
    }

    func makeEvent() -> Event { Event() }

    func restoreCalendar(for snapshot: EventSnapshot, kind: EventRestoreKind) async throws -> String {
        log.append("calendar")
        return try calendarNow(for: snapshot, kind: kind)
    }

    func calendarNow(for snapshot: EventSnapshot, kind: EventRestoreKind) throws -> String {
        let known = missingCalendars.contains(snapshot.calendarIdentifier) ? [] : [snapshot.calendarIdentifier]
        return try snapshot.resolveCalendar(in: known, identifier: { $0 }, for: kind)
    }

    func apply(_ snapshot: EventSnapshot, to event: Event, calendar: String) {
        event.title = snapshot.title
        event.start = snapshot.startDate
        event.calendar = calendar
        event.hasRules = snapshot.restoresFromRules
    }

    func save(_ event: Event) throws {
        let id = "E\(nextID)"
        nextID += 1
        event.id = id
        event.external = "X-\(id)"
        if failingSaveTitles.contains(event.title) {
            log.append("save failed \(event.title)")
            throw saveFailure ?? Failure(what: "save \(event.title)")
        }
        log.append(event.hasRules ? "save series \(event.title)" : "save \(event.title)")
        events.append(event)
        guard event.hasRules else { return }
        // The saved object is the series' first occurrence; the rules generate the rest.
        event.occurrenceDate = event.start
        for slot in seriesSlots where slot != event.start {
            events.append(Event(id: id, external: event.external, calendar: event.calendar, title: event.title,
                                start: slot, occurrenceDate: slot, hasRules: true))
        }
    }

    func remove(_ event: Event, span: EKSpan) throws {
        if span == .futureEvents {
            if seriesRemovalFails {
                log.append("remove series failed")
                throw Failure(what: "remove series")
            }
            log.append("remove series")
            events.removeAll { $0.id != nil && $0.id == event.id }
        } else {
            if failingRemovalSlots.contains(slot(of: event)) {
                log.append("remove failed \(slot(of: event).timeIntervalSince1970)")
                throw removalFailure ?? Failure(what: "remove occurrence")
            }
            log.append("remove \(slot(of: event).timeIntervalSince1970)")
            events.removeAll { $0 === event }
        }
    }

    /// #288: makes `isStored` throw, as a failed event lookup does.
    var isStoredFails = false

    func isStored(_ event: Event) throws -> Bool {
        if isStoredFails { throw EventKitError.eventLookupFailed(identifier: event.id ?? "") }
        guard let id = event.id else { return false }
        return events.contains { $0.id == id }
    }

    func markNeedsRefresh() { refreshMarks += 1 }

    func slotHolders(at slot: Date, length: TimeInterval, in calendar: String) -> [OccurrenceSlotGuard.SeriesHolder] {
        log.append("holders")
        let range = OccurrenceSlotGuard.listingRange(slot: slot, length: length)
        return events
            .filter { $0.calendar == calendar && $0.start >= range.start && $0.start < range.end }
            .compactMap { OccurrenceSlotGuard.holder(eventIdentifier: $0.id, externalIdentifier: $0.external,
                                                     occurrenceDate: $0.occurrenceDate, isAllDay: false, startDate: $0.start,
                                                     hasRecurrenceRules: $0.hasRules, isDetached: $0.detached, zone: zone) }
    }

    /// #321: what `noteRecreation` was told, in order.
    private(set) var recreationLog = SeriesRecreations()
    private(set) var notedRecreations: [(recorded: UndoPostState.OccurrenceIDs, recreated: UndoPostState.OccurrenceIDs)] = []

    func noteRecreation(of recorded: UndoPostState.OccurrenceIDs, as recreated: UndoPostState.OccurrenceIDs) {
        notedRecreations.append((recorded, recreated))
        recreationLog.note(recorded, recreatedAs: recreated)
    }

    func recreations(of recorded: UndoPostState.OccurrenceIDs) -> [UndoPostState.OccurrenceIDs] {
        recreationLog.recreations(of: recorded)
    }

    /// The starts of what the store holds under `id`, sorted.
    func starts(of id: String?) -> [Date] {
        events.filter { $0.id == id }.map(\.start).sorted()
    }
}
