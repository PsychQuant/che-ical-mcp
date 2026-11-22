import Foundation

/// #544: the series a `create_event` retry with `excluded_occurrence_dates` is checked against.
///
/// The duplicate lookup (`findDuplicateEvent`, title and start) returns whichever event of the start
/// window has the requested title. Once the series' first occurrence was edited on its own, that event
/// is the edited occurrence: it has no recurrence rules of its own and an identifier of its own (the
/// series' identifier, `/RID=` and digits, iCloud, 2026-11-13). The check used to run against it, so
/// the guard for a non-recurring match (#182 verify finding 8) answered a conflict naming the first
/// excluded date whatever the series held there, with the occurrence's identifier as the series'.
///
/// A match that addresses one occurrence (`DetachedOccurrenceSpan.addressesOneOccurrence`) is now
/// checked against the series named by the part of its identifier before `/RID=`, when that series
/// object reads and has rules. A match with rules of its own is checked against itself, and a match
/// that addresses no occurrence and has no rules keeps the conflict, both as before. The series is
/// taken whatever occurrence of it matched, as an unedited occurrence of a series at the requested
/// start is on `main`: the duplicate lookup reads a title and a start, not which series was asked for.
///
/// Pure: the series object is read through `series`, whose throw (a lookup that raised, #288) is
/// passed on as it is.
enum ExclusionRetryTarget {
    /// What is read of the series object.
    struct SeriesFacts: Equatable {
        let hasRecurrenceRules: Bool
        let timeZone: TimeZone?
    }

    enum Target: Equatable {
        /// Check the excluded dates against the series `id`, whose time zone is `zone`.
        case series(id: String, zone: TimeZone?)
        /// The match has no rules and addresses no occurrence: the conflict of #182 verify finding 8.
        case notRecurring(id: String)
        /// The match addresses one occurrence, and its series could not be read or has no rules.
        case seriesUnread(occurrenceID: String)
    }

    static func resolve(matchID: String, matchIsDetached: Bool, matchHasRules: Bool, matchZone: TimeZone?,
                        series: (String) throws -> SeriesFacts?) rethrows -> Target {
        if matchHasRules { return .series(id: matchID, zone: matchZone) }
        guard DetachedOccurrenceSpan.addressesOneOccurrence(identifier: matchID, isDetached: matchIsDetached) else {
            return .notRecurring(id: matchID)
        }
        guard let seriesID = DetachedOccurrenceSpan.seriesIdentifier(of: matchID),
              let facts = try series(seriesID), facts.hasRecurrenceRules else {
            return .seriesUnread(occurrenceID: matchID)
        }
        return .series(id: seriesID, zone: facts.timeZone)
    }

    /// The answer for `Target.seriesUnread`: the check did not run, and nothing was written. It names
    /// the matched occurrence's identifier only in the shape `EditedOccurrenceAddress.echoed` lets
    /// through; otherwise it says where to find it.
    static func seriesUnreadReason(occurrenceID: String) -> String {
        let named = DetachedOccurrenceSpan.seriesIdentifier(of: occurrenceID)
            .flatMap { EditedOccurrenceAddress.echoed(occurrenceID, seriesID: $0) }
            .map { "An occurrence edited on its own (event ID \($0))" } ?? "An occurrence edited on its own (the id list_events shows for it)"
        return "\(named) matches this event, and the series it belongs to could not be read as a recurring series, so the excluded dates were not checked. Nothing was created or modified; check the series in Calendar or change the request."
    }
}
