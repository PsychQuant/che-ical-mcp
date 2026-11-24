import EventKit
import Foundation

/// #578: which series a recurring `create_event` retry refers to once the series' first occurrence
/// was edited on its own, on the paths #544 left alone (no exclusions to check).
///
/// Measured on `main` (`88e5158a`, iCloud, 2026-11-24): a recurring retry over a series whose first
/// occurrence's notes were edited in place answered `skipped` with that occurrence's identifier
/// (`<series id>/RID=` and digits); a retry over one whose first occurrence was retitled in place
/// matched nothing in the start window and created a second series.
///
/// Both answers rest on `ExclusionRetryTarget.resolve` unchanged: the series named before `/RID=` is
/// taken only for its first occurrence edited in place, of a series that reads with rules, the
/// requested title and its first slot at the requested start. A one-off request is not affected:
/// for it the matched event is the answer, as on `main`. A series lookup that raises (#288) is read
/// as not resolved, so the call answers what `main` answered rather than failing.
///
/// Pure: events come in as `Candidate` values and the series object through `series`.
enum CreateRetryIdentity {
    /// What is read of one event of the start window.
    struct Candidate: Equatable {
        let match: ExclusionRetryTarget.Match
        let isAllDay: Bool
    }

    /// The series identifier a recurring retry's skipped answer gives when no exclusion check ran,
    /// or nil to keep the matched event's identifier (`main`'s answer).
    static func answeredSeries(recurring: Bool, match: ExclusionRetryTarget.Match, request: ExclusionRetryTarget.Request,
                               series: (String) throws -> ExclusionRetryTarget.SeriesFacts?) -> String? {
        guard recurring, case .series(let id, _)? = try? ExclusionRetryTarget.resolve(match: match, request: request, series: series),
              id != match.identifier else { return nil }
        return id
    }

    /// One occurrence edited on its own, at the requested start, whose series has the requested title.
    struct Retitled: Equatable {
        let occurrenceID: String
        let seriesID: String
    }

    /// For a recurring request whose title lookup found nothing: the first candidate of the same kind
    /// (timed or all-day) that `resolve` takes as its series' first occurrence edited in place, of a
    /// series with the requested title. Its own title is not read: it differs, or the title lookup
    /// would have found it.
    static func retitledFirstOccurrence(recurring: Bool, candidates: [Candidate], isAllDay: Bool, request: ExclusionRetryTarget.Request,
                                        series: (String) throws -> ExclusionRetryTarget.SeriesFacts?) -> Retitled? {
        guard recurring else { return nil }
        for candidate in candidates where candidate.isAllDay == isAllDay {
            guard case .series(let id, _)? = try? ExclusionRetryTarget.resolve(match: candidate.match, request: request, series: series),
                  id != candidate.match.identifier else { continue }
            return Retitled(occurrenceID: candidate.match.identifier, seriesID: id)
        }
        return nil
    }

    /// The refusal for `Retitled`. Both identifiers are written only in the shape the edited-occurrence
    /// refusals echo (the series' identifier is the occurrence's part before `/RID=`); otherwise the
    /// text points to `list_events`. No `<`, `>` or `&` (#166).
    static func retitledReason(seriesID: String, occurrenceID: String) -> String {
        let echoed = EditedOccurrenceAddress.echoed(occurrenceID, seriesID: seriesID)
        let series = echoed.map { _ in "An existing series (event ID \(seriesID))" } ?? "An existing series (list_events shows it)"
        let occurrence = echoed.map { "(event ID \($0))" } ?? "(the id list_events shows for it)"
        return "\(series) has this title and its first occurrence at this start, and that first occurrence was edited on its own and now has another title \(occurrence), so this server cannot tell whether this request is a retry of that series. Nothing was created or modified; if it is a new series, change its title or start, or create it in Calendar."
    }
}

extension CreateRetryIdentity.Candidate {
    /// nil for an event without an identifier.
    init?(_ event: EKEvent) {
        guard let identifier = event.eventIdentifier else { return nil }
        self.init(match: ExclusionRetryTarget.Match(identifier: identifier, isDetached: event.isDetached,
                                                    hasRecurrenceRules: event.hasRecurrenceRules, timeZone: event.timeZone,
                                                    start: event.startDate),
                  isAllDay: event.isAllDay)
    }
}
