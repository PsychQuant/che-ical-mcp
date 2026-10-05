import EventKit
import Foundation

/// #236, maintainer decision after PR #259 round 4: undo of an `update_event` that touched a
/// recurring event is refused, never attempted. Restoring one could move the wrong occurrence,
/// detach it, or delete the rest of the series, and every restore strategy tried had a
/// store-dependent way to do so. The update is recorded only as a marker
/// (`UndoOperation.updateRecurringEvent`); undo on it writes nothing and discards it, as #204
/// does, so earlier operations stay undoable.
enum RecurringUpdateKind: String, Sendable, Hashable {
    /// One occurrence (span "this" with `occurrence_date`).
    case occurrence
    /// An occurrence and the following ones (span "future" with `occurrence_date`).
    case future
    /// A one-off event made to repeat.
    case rulesAdded
    /// A repeating event made a one-off.
    case rulesRemoved
    /// The whole series (span "all"). Its undo used to save the first occurrence alone, which on
    /// iCloud detached it and deleted the rest of the series (#262).
    case series

    /// Which kind of recurring update this was, or nil when the update touched no recurring event
    /// (a one-off event before and after; its undo restores the event as before). `hasRulesAfter` is what the request leaves the
    /// series with, not a read of the saved object: a detached occurrence reads back with no rules
    /// even though its series still repeats.
    static func of(hadRules: Bool, hasRulesAfter: Bool, onOccurrence: Bool, span: EKSpan) -> RecurringUpdateKind? {
        guard hadRules || hasRulesAfter || onOccurrence else { return nil }
        if !hadRules { return .rulesAdded }
        if !hasRulesAfter { return .rulesRemoved }
        if onOccurrence { return span == .futureEvents ? .future : .occurrence }
        return .series
    }

    var reason: String {
        switch self {
        case .occurrence: return "it changed one occurrence of the series"
        case .future: return "it changed an occurrence and the following occurrences of the series"
        case .rulesAdded: return "it made a one-off event repeat"
        case .rulesRemoved: return "it removed the event's repetition"
        case .series: return "it changed the whole series"
        }
    }
}

extension UndoOperation {
    /// Undo of a recurring-update marker: permanent (`UnrecoverableUndoError`, the record is
    /// discarded). Author-controlled text; the store-derived title passes `undoShownTitle`.
    static func recurringUpdateRefusal(title: String, kind: RecurringUpdateKind) -> UnrecoverableUndoError {
        UnrecoverableUndoError(message: "Cannot undo the update of the recurring event '\(undoShownTitle(title))': \(kind.reason). Undo does not restore updates that touched a recurring event, because restoring one can move, detach or delete occurrences of the series. Nothing was written. This history entry was discarded so earlier operations remain undoable. If the change should be reverted, revert it in Calendar (or with update_event).")
    }
}
