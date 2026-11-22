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

    /// How the `/RID=` digits are read.
    /// - `floating`: a date, the day the digits give at 00:00 UTC.
    /// - `instant`: an instant, compared as `main` compares it (fix round 1, X2).
    /// - `unknown`: either; a day is taken only when both readings give it.
    enum Reading: Equatable {
        case floating, instant, unknown
    }

    /// What the digits of a `/RID=` mean depends on the series when the occurrence was first edited
    /// on its own (#539 cell R2), not on the series now: an all-day series writes a floating date, a
    /// timed one an instant (#539: a timed series with no time zone writes its wall-clock time as if
    /// UTC, which this check reads as an instant, as `main` did; that stays open in #569). A floating
    /// date is always 00:00 UTC, so digits that are not are not one, whatever the flags.
    /// For digits at 00:00 UTC the flags of now decide only when the series can be read and it and
    /// the occurrence agree; the series can be converted after the edit (#428 (h), or another app), so
    /// that is an assumption, wrong only for a timed slot at exactly 00:00 UTC whose series and
    /// occurrence were both made all-day after the edit.
    /// - `seriesIsAllDay`: the series' flag, nil when the series cannot be read.
    static func reading(rid: Date, seriesIsAllDay: Bool?, startIsAllDay: Bool) -> Reading {
        guard isWholeUTCDay(rid) else { return .instant }
        switch (seriesIsAllDay, startIsAllDay) {
        case (true?, true): return .floating
        case (false?, false): return .instant
        default: return .unknown
        }
    }

    static func isWholeUTCDay(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400) == 0
    }

    /// - `start`, `startIsAllDay`: the occurrence's shown start and its own all-day flag.
    /// - `zone`: the zone `occurrence_date` was read in, the occurrence's (nil: `host`).
    /// - `eventIdentifier`, `externalIdentifier`, `occurrenceDate`: where the original slot is read
    ///   (the `/RID=` of the event identifier, else of the external one, else `occurrenceDate`).
    /// - `seriesIsAllDay`: the all-day flag of the series the occurrence belongs to; nil when the
    ///   series object cannot be read.
    static func answer(requested: Date, start: Date?, startIsAllDay: Bool, zone: TimeZone?,
                       eventIdentifier: String?, externalIdentifier: String?, occurrenceDate: Date?,
                       seriesIsAllDay: Bool?, host: TimeZone) -> Answer {
        // `main`'s comparison, with the occurrence's own flag and zone.
        func onRequestedDay(_ instant: Date?) -> Bool {
            OccurrenceDay.startsOnRequestedDay(occurrenceStart: instant, isAllDay: startIsAllDay, requested: requested,
                                               in: zone, host: host)
        }
        if onRequestedDay(start) { return .matches }
        let rid = UndoPostState.originalSlot(eventIdentifier: eventIdentifier, externalIdentifier: externalIdentifier,
                                             occurrenceDate: nil)
        let asInstant = onRequestedDay(rid ?? occurrenceDate)
        guard let rid else { return asInstant ? .matches : .differs }
        // X3: the floating date against the requested civil date directly, not through a host
        // instant, which a host that skipped the day (Pacific/Apia, 2011-12-30) cannot give.
        let asDate = civilDay(of: rid, in: TimeZone(identifier: "UTC")!) == civilDay(of: requested, in: zone ?? host)
        switch reading(rid: rid, seriesIsAllDay: seriesIsAllDay, startIsAllDay: startIsAllDay) {
        case .floating: return asDate ? .matches : .differs
        case .instant: return asInstant ? .matches : .differs
        case .unknown:
            if asDate == asInstant { return asDate ? .matches : .differs }
            return .undetermined
        }
    }

    private static func civilDay(of date: Date, in zone: TimeZone) -> DateComponents {
        Calendar.gregorian(in: zone).dateComponents([.era, .year, .month, .day], from: date)
    }
}
