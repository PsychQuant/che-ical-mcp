import EventKit

/// #452: what the earlier rows of one `delete_events_batch` call (span `this` or `future`) did to a
/// later row. The real call (`EventKitManager.deleteEventsBatch`) asks it before each row and tells
/// it after each deletion; the `event_ids` dry run (`previewDeletionRows`) does the same over its
/// preview rows, so the two answer each row alike. Span `all` goes another way (`goneInTheCall`).
///
/// Two things carry over from one row to the next, and nothing else:
/// - an event deleted whole (a one-off, or an occurrence by its own `<series>/RID=<slot>` id): the
///   same id again no longer resolves, so that row fails with `batchRowDeletedEarlier`;
/// - with span `future`, the series an occurrence's removal cut, from its slot on
///   (`FutureDeletionCoverage`): a later occurrence of it is skipped and counted in `already_removed`.
///
/// An occurrence removed from its series by the series' id and an occurrence date (by date range)
/// is not an event deleted whole: the same id names the series' other occurrences.
struct BatchRowSequence {
    enum Before: Equatable {
        /// The row is looked up and run.
        case lookUp
        /// An earlier row of the call deleted this id; the row fails (`batchRowDeletedEarlier`).
        case deletedEarlier
        /// With span `future`, an earlier row removed this occurrence with its series (`already_removed`).
        case alreadyRemoved
    }

    private let span: EKSpan
    private var coverage = FutureDeletionCoverage()
    private var deletedWholeIds = Set<String>()

    init(span: EKSpan) {
        self.span = span
    }

    /// What the row is before any lookup. A repeated id is answered first: it is what the real
    /// lookup finds (nothing), even when the coverage also reaches it.
    func before(identifier: String, slot: Date?) -> Before {
        if deletedWholeIds.contains(identifier) { return .deletedEarlier }
        if span == .futureEvents, coverage.covers(identifier: identifier, slot: slot) { return .alreadyRemoved }
        return .lookUp
    }

    /// One event removed whole: a one-off, or an occurrence by its own id (it reads back without
    /// rules). With span `future` the occurrence's removal takes its series from its slot on (device,
    /// iCloud, 2026-10-20). By `event_ids` no occurrence date is given; the row names one occurrence,
    /// so its own start is the requested one.
    mutating func deletedWhole(identifier: String, requested: Date?, requestedSlot: Date?,
                               removedStart: Date, removedSlot: Date?) {
        deletedWholeIds.insert(identifier)
        guard Self.deletesLaterOccurrences(identifier: identifier, span: span) else { return }
        coverage.recordRemoval(identifier: identifier, requested: requested ?? removedStart, requestedSlot: requestedSlot,
                               removedStart: removedStart, removedSlot: removedSlot)
    }

    /// One occurrence removed from its series (by date range: the series' id and an occurrence date).
    mutating func deletedOccurrence(identifier: String, requested: Date, requestedSlot: Date?,
                                    removedStart: Date, removedSlot: Date?) {
        guard span == .futureEvents else { return }
        coverage.recordRemoval(identifier: identifier, requested: requested, requestedSlot: requestedSlot,
                               removedStart: removedStart, removedSlot: removedSlot)
    }

    /// Whether a row that deletes this id whole also deletes later occurrences of a series: an
    /// occurrence's own id with span `future`.
    static func deletesLaterOccurrences(identifier: String, span: EKSpan) -> Bool {
        span == .futureEvents && identifier.contains("/RID=")
    }
}

extension EventKitManager {
    /// #452: the row of an id that an earlier row of the same `delete_events_batch` call deleted.
    static let batchRowDeletedEarlier = "Event not found: an earlier row of this call deleted it"
}
