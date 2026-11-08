import Foundation

/// #273: what a `create_calendar`, `update_calendar` or `delete_calendar` did, recorded only as a
/// marker (`UndoOperation.calendarOperation`). Undo of it is refused, writes nothing and discards
/// the record, as for `.updateRecurringEvent` (#236): the marker is there so that `undo` after a
/// calendar operation does not revert an older, unrelated operation in its place. A real undo is
/// either destructive (deleting a created calendar would delete whatever was added to it since) or
/// impossible (a deleted calendar's events or reminders are gone with it); the undo of a rename or
/// color change is left out as well, since it writes to a calendar that may have changed elsewhere
/// and would need its own post-state check.
enum CalendarOperationKind: String, Sendable, Hashable {
    case created
    case updated
    case deleted

    /// The `undo_history` listing's verb.
    var listingVerb: String {
        switch self {
        case .created: return "Created"
        case .updated: return "Updated"
        case .deleted: return "Deleted"
        }
    }

    /// The operation as the refusal and the redo instruction name it.
    var noun: String {
        switch self {
        case .created: return "creation"
        case .updated: return "update"
        case .deleted: return "deletion"
        }
    }

    /// Why undo does not revert it, and what to do instead.
    fileprivate var refusalReason: String {
        switch self {
        case .created:
            return "undo does not delete calendars, because the calendar may hold events or reminders added since it was created"
        case .updated:
            return "undo does not rename or recolor calendars back, because the calendar may have been changed again since, in Calendar or on another device"
        case .deleted:
            return "undo cannot recreate a deleted calendar or the events or reminders it held"
        }
    }

    fileprivate var remedy: String {
        switch self {
        case .created:
            return "If the calendar should go and is empty, delete it with delete_calendar and require_empty: true, which refuses while it holds events or reminders it can see (see delete_calendar); deleting it with what it holds is for the user to decide."
        case .updated:
            return "If the change should be reverted, revert it in Calendar (or with update_calendar)."
        case .deleted:
            return "If it should come back, recreate it in Calendar (or with create_calendar); the events or reminders it held are not restored."
        }
    }
}

extension UndoOperation {
    /// Undo of a calendar-operation marker: permanent (`UnrecoverableUndoError`, the record is
    /// discarded). Author-controlled text only. The calendar is not named: a trusted error never
    /// carries a calendar title, which for a shared or subscribed calendar is set by someone else
    /// (#37, as #269 / #290 word their refusals); the `undo_history` listing names it instead, as
    /// listings name titles. The message says what the next undo reverts, so an agent that runs
    /// undo again to reach the calendar does not revert an unrelated operation unknowingly.
    static func calendarOperationRefusal(kind: CalendarOperationKind) -> UnrecoverableUndoError {
        UnrecoverableUndoError(message: "Cannot undo the \(kind.noun) of a calendar: \(kind.refusalReason). Nothing was written. This history entry was discarded, so the next undo reverts the operation recorded before it, not this calendar operation: run undo again only to revert that earlier operation. \(kind.remedy)")
    }
}
