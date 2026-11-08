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
/// resolves is handled as any other row, so an event is never skipped while it stays.
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

    /// Notes that an id named by `event_ids` resolved before the call.
    mutating func resolvedBeforeTheCall(_ identifier: String) {
        resolvedBefore.insert(identifier)
    }

    /// The answer before any lookup. `listed` is the row's occurrence date, given by date range only.
    /// A repeated id is answered first: it is what the real lookup finds (nothing).
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

    /// The one switch over an answer (review r1 item 5), shared by the manager's loop and the test
    /// model: a failure is listed, an already removed row counted. True when the row is settled.
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
