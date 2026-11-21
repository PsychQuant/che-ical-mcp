import Foundation

/// #416 / #543: whether `occurrence_date`, passed with an occurrence's own identifier, names that
/// occurrence: the day it starts on, or its original day. A caller can hold either for an
/// occurrence that was moved.
///
/// Pure: the occurrence comes in as values and `host` (this Mac's zone, in which all-day events are
/// whole days, #364) is a parameter, given to both readings below.
enum OccurrenceDateMatch {
    /// - `start`, `startIsAllDay`: the occurrence's shown start and its own all-day flag.
    /// - `zone`: the zone `occurrence_date` was read in, the occurrence's (nil: `host`).
    /// - `eventIdentifier`, `externalIdentifier`, `occurrenceDate`: where the original slot is read.
    /// - `seriesIsAllDay`: the all-day flag of the series the occurrence belongs to.
    static func matches(requested: Date, start: Date?, startIsAllDay: Bool, zone: TimeZone?,
                        eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?,
                        seriesIsAllDay: Bool, host: TimeZone) -> Bool {
        // #543: the /RID= digits follow the series when the occurrence was first edited on its own: an
        // all-day series' are a floating date (the day at 00:00 UTC), which `ruleSlot` places on that day
        // in `host`; read as an instant (`originalSlot`), a host west of UTC took the day before. A timed
        // series' are an instant, read as before (#539's second reading is PR #558's).
        let slot = UndoPostState.ruleSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                          occurrenceDate: occurrenceDate, isAllDay: seriesIsAllDay, zone: host)
        return OccurrenceDay.startsOnRequestedDay(occurrenceStart: start, isAllDay: startIsAllDay, requested: requested,
                                                  in: zone, host: host)
            || OccurrenceDay.startsOnRequestedDay(occurrenceStart: slot, isAllDay: seriesIsAllDay, requested: requested,
                                                  in: zone, host: host)
    }
}
