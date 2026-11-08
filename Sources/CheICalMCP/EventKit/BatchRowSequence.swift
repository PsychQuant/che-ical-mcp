import EventKit

/// #452: what the earlier rows of one `delete_events_batch` call (span `this` or `future`) did to a
/// later row. The real call (`EventKitManager.deleteEventsBatch`) and the `event_ids` dry run
/// (`previewDeletionRows`) ask it the same questions, so the two answer each row alike. Span `all`
/// goes another way (`goneInTheCall`).
///
/// Three things carry over from one row to the next, and nothing else:
/// - an event deleted whole (a one-off, or an occurrence by its own `<series>/RID=<slot>` id): the
///   same id again no longer resolves, so that row fails with `batchRowDeletedEarlier`;
/// - an id counted as already removed: a repeat of it fails the same way (review r1 item 2);
/// - with span `future`, the series an occurrence's removal cut, from its slot on
///   (`FutureDeletionCoverage`).
///
/// A row from a listing (by date range, with its occurrence date) that the cut reaches is skipped
/// before any lookup, as since #325. A row named by id (`event_ids`, no occurrence date) is looked
/// up first (review r1 item 1): it is counted in `already_removed` only when the lookup finds
/// nothing, the cut reaches its slot, and it resolved before the call. A covered row that still
/// resolves is handled as any other row, so an event is never skipped while it stays ("removed"
/// rests on a lookup not finding it, as `EventRemovalKind` does).
///
/// The cut is read from the slot in the id (`UndoPostState.originalSlot`), which does not parse a
/// negative slot (before 2001): such a delete covers no later row, which is then looked up and, when
/// gone, fails as not found (review r3 item 4; `UndoRefusalTests` keeps `/RID=-5` malformed).
struct BatchRowSequence {
    enum Answer: Equatable {
        /// The row is looked up and run.
        case lookUp
        /// The row fails with this reason.
        case failed(String)
        /// With span `future`, an earlier row removed this occurrence with its series (`already_removed`).
        case alreadyRemoved
    }

    private let span: EKSpan
    private var coverage = FutureDeletionCoverage()
    /// Ids deleted whole or counted as already removed: a repeat no longer resolves.
    private var finishedIds = Set<String>()
    /// Ids named without an occurrence date that resolved before the call's first removal.
    private var resolvedBefore = Set<String>()

    init(span: EKSpan) {
        self.span = span
    }

    /// Notes that an id named by `event_ids` resolved before the call. Only an event without rules is
    /// noted (review r2 LOW 1): one with rules is refused for want of a date, never deleted whole,
    /// and the dry run's deletions (`.deletes`) are without rules too.
    mutating func resolvedBeforeTheCall(_ identifier: String, hasRecurrenceRules: Bool) {
        guard !hasRecurrenceRules else { return }
        resolvedBefore.insert(identifier)
    }

    /// The dry run's answer for a row named by id that resolves (review r2 MEDIUM): whether an earlier
    /// row's cut reaches it. The dry run cannot tell whether the store removes it with that series
    /// (the real call then counts it in `already_removed`) or keeps it (the real call deletes it as
    /// its own row); it is gone after the call either way, so it is remembered as finished.
    mutating func coveredInTheDryRun(identifier: String) -> Bool {
        guard resolvedBefore.contains(identifier), removedByAnEarlierRow(identifier: identifier) else { return false }
        finishedIds.insert(identifier)
        return true
    }

    /// The answer before any lookup. `listed` is the row's occurrence date, given by date range only;
    /// a row named by id (`listed` nil) is never answered `.alreadyRemoved` here, only after its
    /// lookup (`notFound`). A repeated id is answered first: it is what the real lookup finds (nothing).
    mutating func before(identifier: String, listed: Date?, slot: Date?) -> Answer {
        if finishedIds.contains(identifier) { return .failed(EventKitManager.batchRowDeletedEarlier) }
        if listed != nil, span == .futureEvents, coverage.covers(identifier: identifier, slot: slot) {
            return .alreadyRemoved
        }
        return .lookUp
    }

    /// Whether an earlier row's cut reaches this row named by id: its series was cut with span
    /// `future` at or before its slot. Says nothing about whether the store removed it.
    func removedByAnEarlierRow(identifier: String) -> Bool {
        span == .futureEvents && coverage.covers(identifier: identifier, slot: nil)
    }

    /// The answer after a lookup that found nothing. A row named by id that the cut reaches and that
    /// resolved before the call was removed by this call (`already_removed`, and remembered); any
    /// other row fails with `reason` (asked only then).
    mutating func notFound(identifier: String, listed: Date?, reason: () -> String) -> Answer {
        if listed == nil, removedByAnEarlierRow(identifier: identifier), resolvedBefore.contains(identifier) {
            finishedIds.insert(identifier)
            return .alreadyRemoved
        }
        return .failed(reason())
    }

    /// One event removed whole: a one-off, or an occurrence by its own id (it reads back without
    /// rules). With span `future` the occurrence's removal takes its series from its slot on (device,
    /// iCloud, 2026-10-20). By `event_ids` no occurrence date is given; the row names one occurrence,
    /// so its own start is the requested one.
    mutating func deletedWhole(identifier: String, requested: Date?, requestedSlot: Date?,
                               removedStart: Date, removedSlot: Date?) {
        finishedIds.insert(identifier)
        guard Self.deletesLaterOccurrences(identifier: identifier, span: span) else { return }
        coverage.recordRemoval(identifier: identifier, requested: requested ?? removedStart, requestedSlot: requestedSlot,
                               removedStart: removedStart, removedSlot: removedSlot)
    }

    /// One occurrence removed from its series (by date range: the series' id and an occurrence date).
    /// Not remembered as finished: the series' other occurrences follow under the same id.
    mutating func deletedOccurrence(identifier: String, requested: Date, requestedSlot: Date?,
                                    removedStart: Date, removedSlot: Date?) {
        guard span == .futureEvents else { return }
        coverage.recordRemoval(identifier: identifier, requested: requested, requestedSlot: requestedSlot,
                               removedStart: removedStart, removedSlot: removedSlot)
    }

    /// Whether a row that deletes this id whole also deletes later occurrences of a series: an
    /// occurrence's own id with span `future`. Keyed on `/RID=` in the id, an iCloud form (#416).
    static func deletesLaterOccurrences(identifier: String, span: EKSpan) -> Bool {
        span == .futureEvents && identifier.contains("/RID=")
    }

    /// How the real call settles an answer (review r1 item 5), shared by the manager's loop and the
    /// test model: a failure is listed, an already removed row counted. True when the row is settled.
    /// The dry run turns answers into preview rows itself (`previewDeletionRows`).
    static func settle(_ answer: Answer, identifier: String, failures: inout [(String, String)],
                       coveredCount: inout Int) -> Bool {
        switch answer {
        case .lookUp:
            return false
        case .failed(let reason):
            failures.append((identifier, reason))
            return true
        case .alreadyRemoved:
            coveredCount += 1
            return true
        }
    }
}

extension EventKitManager {
    /// #452: the row of an id that an earlier row of the same `delete_events_batch` call deleted.
    static let batchRowDeletedEarlier = "Event not found: an earlier row of this call deleted it"
}
