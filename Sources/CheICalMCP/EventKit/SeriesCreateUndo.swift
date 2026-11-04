import Foundation

/// #377: the not-found message of the undo of `create_event` for a series, decided from facts the
/// caller reads from the store. Asked only on the failure path of `UndoTargetCheck` (the lookup
/// found nothing, or found an object that did not refresh), so a series that refreshes pays
/// nothing. Pure (closure seam, like `SeriesMoveUndo`); the EventKit side is
/// `EventKitManager.createUndoMissingError`.
///
/// The undo does not resolve through the stand-in, as the undo of a whole-series move does
/// (#369): it compares the recorded snapshot of the series object, which a middle occurrence never
/// matches, and its delete would start from that occurrence. It refuses instead, naming the shape.
enum SeriesCreateUndo {
    /// - any record other than the undo of a `create_event`, nothing stored under the identifier,
    ///   or a stored event that does not repeat: nil, the plain not-found (no scan);
    /// - a stored series with no remaining occurrence that can stand in (none left, or every one
    ///   left edited on its own, which the pick skips): the #369 residual wording, which names the
    ///   possible causes;
    /// - a stand-in that starts after the series' recorded start, the slot a deleted first
    ///   occurrence leaves: `seriesFirstOccurrenceDeleted`, which names that shape;
    /// - a stand-in that does not: `seriesUnreadable`, which claims no cause and no permanence.
    /// All are `UndoTargetMissingError`, kept like every not-found.
    ///
    /// `standInStartsAfterSeriesStart` is asked last and only for a stored series: nil when no
    /// occurrence stands in.
    static func missingError(of operation: UndoOperation, verb: UndoHistoryVerb, stored: Bool, recurring: Bool,
                             standInStartsAfterSeriesStart: () -> Bool?) -> Error? {
        guard verb == .undo, case .createEvent(_, let title, _) = operation, stored, recurring else { return nil }
        switch standInStartsAfterSeriesStart() {
        case nil:
            return UndoTargetMissingError(verb: verb, kind: .event, title: title, hasIdentifier: true,
                                          seriesWithoutStandIn: true)
        case true?:
            return UndoTargetMissingError.seriesFirstOccurrenceDeleted(title: title)
        case false?:
            return UndoTargetMissingError.seriesUnreadable(title: title)
        }
    }
}
