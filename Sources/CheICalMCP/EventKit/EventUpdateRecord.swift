import Foundation

/// #246: the undo record of an `update_event`, built after the save (the closure-seam variant,
/// #182). A calendar change across accounts changes the event's identifier (#226, on device), so
/// the record carries the identifier the event has after the save, as `.moveEvent` does; with the
/// requested one the undo looks the event up under an identifier that is gone and fails as not
/// found. #236: a one-off update also records the state it left, read under that identifier the
/// way the undo reads it; an update that touched a recurring event is only a marker.
enum EventUpdateRecord {
    static func operation(requestedID: String, identifierAfterSave: String?, oldSnapshot: EventSnapshot,
                          recurringKind: RecurringUpdateKind?,
                          postState: (String) -> EventSnapshot) -> UndoOperation {
        let id = identifierAfterSave ?? requestedID
        if let recurringKind {
            return .updateRecurringEvent(id: id, title: oldSnapshot.title, kind: recurringKind)
        }
        return .updateEvent(id: id, oldSnapshot: oldSnapshot, saved: postState(id))
    }
}
