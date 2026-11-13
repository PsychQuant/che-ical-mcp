import Foundation

/// #246: the undo record of an `update_event`, built after the save (the closure-seam variant,
/// #182). A calendar change across accounts changes the event's identifier (#226, on device), so
/// the record carries the identifier the event has after the save, as `.moveEvent` does; with the
/// requested one the undo looks the event up under an identifier that is gone and fails as not
/// found. #236: a one-off update also records the state it left, read under that identifier the
/// way the undo reads it; an update that touched a recurring event is only a marker, except the
/// whole-series update #263 restores, whose record the record site builds (`seriesRecord`).
enum EventUpdateRecord {
    static func operation(requestedID: String, identifierAfterSave: String?, oldSnapshot: EventSnapshot,
                          recurringKind: RecurringUpdateKind?, seriesRecord: SeriesUpdateRecord?,
                          postState: (String) -> EventSnapshot) -> UndoOperation {
        let id = identifierAfterSave ?? requestedID
        if recurringKind == .series, let seriesRecord { return .updateSeries(seriesRecord) }
        if let recurringKind {
            return .updateRecurringEvent(id: id, title: oldSnapshot.title, kind: recurringKind)
        }
        return .updateEvent(id: id, oldSnapshot: oldSnapshot, saved: postState(id))
    }

    /// #484: the identifier older undo and redo records of the event are moved to after an
    /// `update_event` save, or nil when they stay. A closed list of five conditions, all required:
    /// the call changed the calendar; it wrote the whole event (the event did not repeat, or span
    /// `all`); the identifier was not resolved through the stand-in (#326); the identifier is not an
    /// occurrence's own (#416); and the identifier after the save differs from the requested one in
    /// its series part and is not empty. Together they say "the save renamed what the identifier
    /// named". A split (span `future`, a write through one occurrence) starts a new series while the
    /// old identifier still resolves, so its records stay.
    static func identifierToFollow(requestedID: String, identifierAfterSave: String?, changedCalendar: Bool,
                                   wholeEvent: Bool, viaStandIn: Bool, ownOccurrenceID: Bool) -> String? {
        guard changedCalendar, wholeEvent, !viaStandIn, !ownOccurrenceID, let saved = identifierAfterSave,
              CalendarUndoManager.identifierChanged(from: requestedID, to: saved) else { return nil }
        return saved
    }

    /// #484: the answer of a one-off update's undo; it ends with the new identifier when the
    /// restore gave one, in the words the move's undo uses.
    static func updateUndoneText(title: String, newID: String?) -> String {
        "Undone: restored event '\(undoVisibleTitle(title))' to previous state" + newIdentifierSuffix(newID)
    }

    static func newIdentifierSuffix(_ id: String?) -> String {
        id.map { " (new ID: \($0))" } ?? ""
    }
}
