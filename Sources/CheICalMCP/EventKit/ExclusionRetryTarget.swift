import Foundation

/// #544: the series a `create_event` retry with `excluded_occurrence_dates` is checked against.
///
/// The duplicate lookup (`findDuplicateEvent`) reads a title, the 30-second window around the
/// requested start, the calendar and timed or all-day. Once the series' first occurrence was edited
/// on its own, the event it returns is that occurrence: no recurrence rules of its own and an
/// identifier of its own (the series' identifier, `/RID=` and digits, iCloud, 2026-11-13). The check
/// used to run against it, so the guard for a non-recurring match (#182 verify finding 8) answered
/// a conflict naming the first excluded date, with the occurrence's identifier as the series'.
///
/// A match that addresses one occurrence (`DetachedOccurrenceSpan.addressesOneOccurrence`) is
/// checked against the series named before its `/RID=` only in that shape: the series' first
/// occurrence edited in place. Its original slot (`UndoPostState.ruleSlot`, an all-day series'
/// `/RID=` read on this Mac's day) and its start are both the requested start, within one second
/// (`UndoPostState.sameInstant`; a retry passes the start the series was created with, and an
/// occurrence edited in place keeps both), and the series object reads with rules and the
/// requested title. Anything else that addresses one occurrence is not checked (`notChecked`), and
/// writes nothing: an occurrence of another series retitled on its own, one moved onto the start
/// from another slot, or one moved within the lookup's window (PR #582 verify round 1, X1 and X3,
/// where `main` answered the conflict and a wider rule answered `skipped` for an unrelated series).
/// The series' own first slot, as its object reads it (`occurrenceDate`, else `startDate`), must
/// be the requested start too (verify round 2, Y1): a later occurrence of another same-titled series
/// edited in place at that start is not checked. In the #544 shape the occurrence was edited in
/// place, so whichever of the master or the edited first occurrence the object is, its first slot
/// is the requested start.
///
/// A match that addresses one occurrence goes through its series even when it reports rules of its
/// own (X4; no store was measured to do so; checked under its own identifier its dates would all
/// read absent). A match with rules that addresses no occurrence is checked against itself, and a
/// one-off match keeps the conflict, both as on `main`.
///
/// Pure: the series object is read through `series`, whose throw (a lookup that raised, #288) is
/// passed on as it is.
enum ExclusionRetryTarget {
    /// What is read of the matched event.
    struct Match: Equatable {
        let identifier: String
        let isDetached: Bool
        let hasRecurrenceRules: Bool
        let timeZone: TimeZone?
        let start: Date?
    }

    /// What was asked: the title and the start `createEvent` looks up (all-day: the first instant
    /// of the day), and this Mac's zone, where an all-day `/RID=` is read.
    struct Request: Equatable {
        let title: String
        let start: Date
        let host: TimeZone
    }

    /// What is read of the series object.
    struct SeriesFacts: Equatable {
        let hasRecurrenceRules: Bool
        let timeZone: TimeZone?
        let title: String?
        let isAllDay: Bool
        /// The series' first slot as its object reads it (`occurrenceDate`, else `startDate`).
        var firstStart: Date? = nil
    }

    enum Target: Equatable {
        /// Check the excluded dates against the series `id`, whose time zone is `zone`.
        case series(id: String, zone: TimeZone?)
        /// The match has no rules and addresses no occurrence: the conflict of #182 verify finding 8.
        case notRecurring(id: String)
        /// The match addresses one occurrence, and it was not shown to be its series' first
        /// occurrence edited in place, of a recurring series with the requested title.
        case notChecked(occurrenceID: String)
    }

    static func resolve(match: Match, request: Request, series: (String) throws -> SeriesFacts?) rethrows -> Target {
        if DetachedOccurrenceSpan.addressesOneOccurrence(identifier: match.identifier, isDetached: match.isDetached) {
            guard let seriesID = DetachedOccurrenceSpan.seriesIdentifier(of: match.identifier),
                  let facts = try series(seriesID), facts.hasRecurrenceRules, facts.title == request.title,
                  facts.firstStart != nil, UndoPostState.sameInstant(facts.firstStart, request.start),
                  firstEditedInPlace(match: match, request: request, seriesIsAllDay: facts.isAllDay) else {
                return .notChecked(occurrenceID: match.identifier)
            }
            return .series(id: seriesID, zone: facts.timeZone)
        }
        if match.hasRecurrenceRules { return .series(id: match.identifier, zone: match.timeZone) }
        return .notRecurring(id: match.identifier)
    }

    /// Whether the match's original slot (from its `/RID=`, an all-day series' read on this Mac's
    /// day) and its start are both the requested start, within one second.
    static func firstEditedInPlace(match: Match, request: Request, seriesIsAllDay: Bool) -> Bool {
        let slot = UndoPostState.ruleSlot(eventIdentifier: match.identifier, externalIdentifier: nil, occurrenceDate: nil,
                                          isAllDay: seriesIsAllDay, zone: request.host)
        return slot != nil && UndoPostState.sameInstant(slot, request.start) && UndoPostState.sameInstant(match.start, request.start)
    }

    /// The answer for `Target.notChecked`: the check did not run, and nothing was written. It names
    /// the matched occurrence's identifier only in the shape `EditedOccurrenceAddress.echoed` lets
    /// through; otherwise it says where to find it. The series part passed to `echoed` is cut from
    /// that same identifier, so here its prefix check holds by construction and only the character
    /// set and the length limit bound what is echoed (X19); the conflicts echo store identifiers
    /// unchecked, as on `main`.
    static func notCheckedReason(occurrenceID: String) -> String {
        let named = DetachedOccurrenceSpan.seriesIdentifier(of: occurrenceID)
            .flatMap { EditedOccurrenceAddress.echoed(occurrenceID, seriesID: $0) }
            .map { "An occurrence edited on its own (event ID \($0))" } ?? "An occurrence edited on its own (the id list_events shows for it)"
        return "\(named) matches this event. A retry is checked against the series of such an occurrence only when it is that series' first occurrence, edited in place (its original start and its start are the requested start), and the series reads as a recurring series with the requested title; that was not shown, so the excluded dates were not checked. Nothing was created or modified; check the series in Calendar or change the request."
    }
}
