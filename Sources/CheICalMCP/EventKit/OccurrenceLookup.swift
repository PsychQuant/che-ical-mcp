import EventKit

/// #573: the query behind `findOccurrence` and `dayReadings`, with the store query injected so the
/// calendars it names can be tested. Both used to ask EventKit for the requested day's window in
/// every event calendar and filter by identifier afterwards. They now name the series' calendar,
/// as the other series queries already do (`FirstRemainingOccurrence`, `UndoPostStateGuard`,
/// `SeriesExceptionsStoreSource`).
///
/// Only events of the series are ever taken (the identifier and slot checks, and `/RID=` in
/// `EditedOccurrenceAddress`), so naming one calendar can only drop an occurrence of the series that
/// the store reports in another calendar. On iCloud a calendar given to one occurrence moved the
/// whole series (#426, device); other sources were not measured.
enum OccurrenceLookup {
    /// What the selection reads of an enumerated event.
    struct Candidate: Equatable {
        let eventIdentifier: String?
        let occurrenceDate: Date?
        let startDate: Date?
        let isAllDay: Bool
    }

    /// Enumerates the events from `start` to `end` in `calendars` (nil: every calendar); the body
    /// answers true to stop.
    typealias Enumerate<Event, Calendar> = (_ start: Date, _ end: Date, _ calendars: [Calendar]?, _ body: (Event) -> Bool) -> Void

    /// The calendars a lookup names: the series' own; every calendar only when the object has none
    /// (`EKEvent.calendar` is optional), the query `main` made for every lookup.
    static func scope<Calendar>(seriesCalendar: Calendar?) -> [Calendar]? {
        seriesCalendar.map { [$0] }
    }

    /// The occurrence of `identifier` that starts on the requested day in `timeZone` (#391), with
    /// `slot` the one whose `occurrenceDate` is that slot (#325); the first one enumerated.
    static func find<Event, Calendar>(identifier: String, on date: Date, in timeZone: TimeZone?, slot: Date?,
                                      seriesCalendar: Calendar?, host: TimeZone = .current,
                                      enumerate: Enumerate<Event, Calendar>, read: (Event) -> Candidate) -> Event? {
        // PR #394 verify round 1: the search day and the host day, so an all-day occurrence (a host day) is enumerated.
        guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone, host: host) else { return nil }
        var target: Event?
        withoutActuallyEscaping(read) { read in
            enumerate(window.start, window.end, scope(seriesCalendar: seriesCalendar)) { event in
                let facts = read(event)
                // #391: the occurrence must start on the requested day, not only overlap it.
                guard FutureDeletionCoverage.isRequested(eventIdentifier: facts.eventIdentifier, occurrenceDate: facts.occurrenceDate,
                                                         identifier: identifier, slot: slot),
                      OccurrenceDay.startsOnRequestedDay(occurrenceStart: facts.startDate, isAllDay: facts.isAllDay,
                                                         requested: date, in: timeZone, host: host) else { return false }
                target = event
                return true
            }
        }
        return target
    }

    /// #532: every event of the requested day's window (the window `find` enumerates) in the
    /// series' calendar, read for `EditedOccurrenceAddress`.
    static func dayReadings<Event, Calendar>(containing date: Date, in timeZone: TimeZone?, seriesCalendar: Calendar?,
                                             host: TimeZone = .current, enumerate: Enumerate<Event, Calendar>,
                                             read: (Event) -> EditedOccurrenceAddress.Reading) -> [EditedOccurrenceAddress.Reading] {
        guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone, host: host) else { return [] }
        var readings: [EditedOccurrenceAddress.Reading] = []
        withoutActuallyEscaping(read) { read in
            enumerate(window.start, window.end, scope(seriesCalendar: seriesCalendar)) { event in
                readings.append(read(event))
                return false
            }
        }
        return readings
    }
}

extension OccurrenceLookup.Candidate {
    init(_ event: EKEvent) {
        self.init(eventIdentifier: event.eventIdentifier, occurrenceDate: event.occurrenceDate,
                  startDate: event.startDate, isAllDay: event.isAllDay)
    }
}
