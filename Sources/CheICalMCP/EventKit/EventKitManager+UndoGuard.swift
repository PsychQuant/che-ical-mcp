import EventKit
import Foundation

/// #236 — the manager side of the post-state guard (the comparison is in
/// `UndoPostStateGuard.swift`). A record captures the state its write left by reading the item
/// back the way undo will read it; undo resolves the item, refreshes it, compares, and refuses
/// with `UndoTargetChangedError` before writing anything.
extension EventKitManager {
    /// The state an undo of this event write compares with, read the way the undo reads it
    /// (by identifier, refreshed): for a recurring event that is the series' first occurrence,
    /// not necessarily the object the write saved. Falls back to the saved object when the
    /// identifier does not resolve yet; the undo then fails as not found, which keeps the record.
    func postWriteSnapshot(eventID: String, saved: EKEvent) -> EventSnapshot {
        if !eventID.isEmpty, let event = eventStore.event(withIdentifier: eventID), event.refresh() {
            return EventSnapshot(from: event)
        }
        return EventSnapshot(from: saved)
    }

    /// Reminder counterpart of `postWriteSnapshot(eventID:saved:)`.
    func postWriteSnapshot(reminderID: String, saved: EKReminder) -> ReminderSnapshot {
        if !reminderID.isEmpty, let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder,
           reminder.refresh() {
            return ReminderSnapshot(from: reminder)
        }
        return ReminderSnapshot(from: saved)
    }
}
