import Foundation

/// #538: the undo of a delete writes a new item from the record's snapshot, and the store gives it
/// a new identifier (measured on iCloud, 2026-11-13, for a one-off event and a reminder; for a
/// series under #335). Older undo and redo records still name the removed identifier; this type
/// holds the rule for when they follow the recreated item.
enum DeleteUndoFollow {
    /// The identifier a delete record holds: the event's own, and for an event with rules the
    /// series' identifier without a `/RID=` part (the #326 stand-in is an occurrence whose
    /// identifier can carry one). Empty when the event had none.
    static func removedIdentifier(eventIdentifier: String?, hasRules: Bool) -> String {
        guard let id = eventIdentifier, !id.isEmpty else { return "" }
        return hasRules ? (DetachedOccurrenceSpan.seriesIdentifier(of: id) ?? id) : id
    }
}
