import Foundation

/// #416 / #543: whether `occurrence_date`, passed with an occurrence's own identifier, names that
/// occurrence: the day it starts on, or its original day. A caller can hold either for an
/// occurrence that was moved.
///
/// Pure: the occurrence comes in as values and `host` (this Mac's zone, in which all-day events are
/// whole days, #364) is a parameter.
enum OccurrenceDateMatch {
    /// `undetermined`: the date is not the day the occurrence starts on, and it is its original day
    /// by one reading of the `/RID=` digits and not by the other, with nothing to tell which holds.
    enum Answer: Equatable {
        case matches, differs, undetermined
    }

    static func isWholeUTCDay(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400) == 0
    }

    /// - `start`, `startIsAllDay`: the occurrence's shown start and its own all-day flag.
    /// - `zone`: the zone `occurrence_date` was read in, the occurrence's (nil: `host`).
    /// - `eventIdentifier`, `externalIdentifier`, `occurrenceDate`: where the original slot is read
    ///   (the `/RID=` of the event identifier, else of the external one, else `occurrenceDate`).
    static func answer(requested: Date, start: Date?, startIsAllDay: Bool, zone: TimeZone?,
                       eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?,
                       host: TimeZone) -> Answer {
        // `main`'s comparison, with the occurrence's own flag and zone.
        func onRequestedDay(_ instant: Date?) -> Bool {
            OccurrenceDay.startsOnRequestedDay(occurrenceStart: instant, isAllDay: startIsAllDay, requested: requested,
                                               in: zone, host: host)
        }
        if onRequestedDay(start) { return .matches }
        let rid = UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                             occurrenceDate: nil)
        let asInstant = onRequestedDay(rid ?? occurrenceDate)
        guard let rid, isWholeUTCDay(rid) else { return asInstant ? .matches : .differs }

        // What these digits encode depends on the series at the first edit (#539 cell R2).
        // A floating date and an instant can both be midnight UTC. The series and occurrence
        // can both have changed since the edit, so their current flags cannot settle the reading.
        // A floating timed slot's wall-clock digits otherwise keep the old comparison (#569).
        // X3: the floating date against the requested civil date directly, not through a host
        // instant, which a host that skipped the day (Pacific/Apia, 2011-12-30) cannot give.
        let asDate = civilDay(of: rid, in: TimeZone(identifier: "UTC")!) == civilDay(of: requested, in: zone ?? host)
        if asDate != asInstant { return .undetermined }
        return asDate ? .matches : .differs
    }

    private static func civilDay(of date: Date, in zone: TimeZone) -> DateComponents {
        Calendar.gregorian(in: zone).dateComponents([.era, .year, .month, .day], from: date)
    }
}
