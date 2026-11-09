import EventKit
import Foundation

/// #265 — `undo` with `keep_later_edits: true`. Only the undo of `update_event` on a one-off event
/// and of `update_reminder` is merged: the guard runs as for the plain undo (lookup, refresh, the
/// recurring refusal), and the fields it finds changed later block only when they are in a group
/// the update changed (`UndoKeepLaterEdits.plan`). Then only the update's groups are written. The
/// arms keep the update arms' order (calendar or lists read first, nothing suspends between the
/// check and the write; the actor excludes this server's other calls, not another process's save).
/// Every other record undoes as without the flag. `UndoKeepLaterEditsWiringTests` pins this file.
extension EventKitManager {
    func executeUndoKeepingLaterEdits(_ operation: UndoOperation) async throws -> String {
        switch operation {
        case .updateEvent(_, let old, let saved):
            return try await undoUpdatedEventKeepingLaterEdits(operation, old: old, saved: saved)
        case .updateReminder(_, let old, let saved):
            return try await undoUpdatedReminderKeepingLaterEdits(operation, old: old, saved: saved)
        default: return try await executeUndo(operation)
        }
    }

    private func undoUpdatedEventKeepingLaterEdits(_ operation: UndoOperation, old: EventSnapshot,
                                                   saved: EventSnapshot) async throws -> String {
        let calendar = try await restoreCalendar(for: old, kind: .revertUpdate)
        let changedByUpdate = old.changedFields(in: saved, restoring: nil)
        var merge: UndoKeepLaterEdits.Plan?
        let target = try await verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits: { _, elsewhere in
            guard let plan = UndoKeepLaterEdits.plan(changedByUpdate: changedByUpdate, changedElsewhere: elsewhere,
                                                     groups: UndoKeepLaterEdits.eventGroups),
                  plan.overlapping.isEmpty else { return elsewhere }
            merge = plan
            return []
        })
        guard let event = target as? EKEvent, let plan = merge else {
            throw UnrecoverableUndoError(message: "Undo record has no event post-state.")
        }
        old.applyRestoring(Set(plan.restored), to: event, calendar: calendar)
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            event.rollback()
            throw error
        }
        markNeedsRefresh()
        return UndoKeepLaterEdits.undoneMessage(kind: .event, title: old.title, plan: plan)
    }

    private func undoUpdatedReminderKeepingLaterEdits(_ operation: UndoOperation, old: ReminderSnapshot,
                                                      saved: ReminderSnapshot) async throws -> String {
        let lists = try await reminderListsForRestore()
        let changedByUpdate = old.changedFields(in: saved, restoring: nil)
        var merge: UndoKeepLaterEdits.Plan?
        let target = try await verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits: { _, elsewhere in
            guard let plan = UndoKeepLaterEdits.plan(changedByUpdate: changedByUpdate, changedElsewhere: elsewhere,
                                                     groups: UndoKeepLaterEdits.reminderGroups),
                  plan.overlapping.isEmpty else { return elsewhere }
            merge = plan
            return []
        })
        guard let reminder = target as? EKReminder, let plan = merge else {
            throw UnrecoverableUndoError(message: "Undo record has no reminder post-state.")
        }
        // The recorded list is resolved before any write, as `ReminderSnapshot.apply(to:lists:for:now:)`
        // does (#242), so a missing list refuses with the reminder unchanged.
        let list = try old.resolveList(in: lists, identifier: { $0.calendarIdentifier }, for: .revertUpdate)
        old.applyRestoring(Set(plan.restored), to: reminder, list: list, now: Date())
        try saveExistingReminder(reminder, handler: "undo")
        markNeedsRefresh()
        return UndoKeepLaterEdits.undoneMessage(kind: .reminder, title: old.title, plan: plan)
    }
}
