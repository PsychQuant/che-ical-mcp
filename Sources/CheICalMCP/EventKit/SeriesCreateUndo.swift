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
    /// - any record other than the undo of a `create_event`: nil (no scan);
    /// - nothing stored under the identifier: nil, the plain not-found (no scan);
    /// - stored, but no remaining occurrence (`hasStandIn` false): nil, the plain not-found;
    /// - stored and a remaining occurrence: `UndoTargetMissingError.seriesFirstOccurrenceDeleted`,
    ///   kept like every not-found.
    static func missingError(of operation: UndoOperation, verb: UndoHistoryVerb, stored: Bool,
                             hasStandIn: () -> Bool) -> Error? {
        guard verb == .undo, case .createEvent(_, let title, _) = operation, stored, hasStandIn() else { return nil }
        return UndoTargetMissingError.seriesFirstOccurrenceDeleted(title: title)
    }
}
