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
        // Round 1, M3: an update that changed nothing undo restores takes the default undo.
        let changedByUpdate = UndoKeepLaterEdits.changedByUpdate(old: old, saved: saved)
        guard !changedByUpdate.isEmpty else { return try await executeUndo(operation) }
        // Round 2 (LOW 3): read before the guard (it suspends); its error counts only when the
        // calendar's group is restored, so a later move to another calendar is kept even when the
        // recorded calendar is gone.
        let calendarRead: Result<EKCalendar, Error>
        do { calendarRead = .success(try await restoreCalendar(for: old, kind: .revertUpdate)) } catch { calendarRead = .failure(error) }
        var merge: UndoKeepLaterEdits.Plan?
        let target = try await verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits: { _, elsewhere in
            guard let plan = UndoKeepLaterEdits.plan(changedByUpdate: changedByUpdate, changedElsewhere: elsewhere,
                                                     groups: UndoKeepLaterEdits.eventGroups),
                  plan.overlapping.isEmpty else { return elsewhere }
            merge = plan
            return []
        })
        // Round 1, LOW: a guard that passed without a plan (a changed field outside the table, with
        // nothing changed later; no tool writes such a record) takes the default undo, which keeps
        // the record if it refuses. Never a discard.
        guard let event = target as? EKEvent, let plan = merge else { return try await executeUndo(operation) }
        let calendar = plan.restored.contains("calendar") ? try calendarRead.get() : event.calendar
        guard let calendar else { return try await executeUndo(operation) }
        old.applyRestoring(Set(plan.restored), to: event, calendar: calendar)
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            event.rollback()
            throw error
        }
        markNeedsRefresh()
        return UndoKeepLaterEdits.undoneMessage(kind: .event, title: event.title ?? old.title, plan: plan)
    }

    private func undoUpdatedReminderKeepingLaterEdits(_ operation: UndoOperation, old: ReminderSnapshot,
                                                      saved: ReminderSnapshot) async throws -> String {
        let changedByUpdate = UndoKeepLaterEdits.changedByUpdate(old: old, saved: saved)
        guard !changedByUpdate.isEmpty else { return try await executeUndo(operation) }
        let lists = try await reminderListsForRestore()
        var merge: UndoKeepLaterEdits.Plan?
        let target = try await verifiedHistoryTarget(of: operation, verb: .undo, keepingLaterEdits: { _, elsewhere in
            guard let plan = UndoKeepLaterEdits.plan(changedByUpdate: changedByUpdate, changedElsewhere: elsewhere,
                                                     groups: UndoKeepLaterEdits.reminderGroups),
                  plan.overlapping.isEmpty else { return elsewhere }
            merge = plan
            return []
        })
        guard let reminder = target as? EKReminder, let plan = merge else { return try await executeUndo(operation) }
        // The recorded list is resolved before any write, as `ReminderSnapshot.apply(to:lists:for:now:)`
        // does (#242), so a missing list refuses with the reminder unchanged.
        // Round 2 (LOW 3): only when the list's group is restored.
        let list = plan.restored.contains("list") ? try old.resolveList(in: lists, identifier: { $0.calendarIdentifier }, for: .revertUpdate) : nil
        // PR #507 round 5: the verified reminder's identity, before the merge is applied to it.
        let occurrence = ReminderCompletionSnapshot(from: reminder)
        old.applyRestoring(Set(plan.restored), to: reminder, list: list, now: Date())
        let note = try saveForHistory(reminder, handler: "undo", occurrence: occurrence)
        markNeedsRefresh()
        return UndoKeepLaterEdits.undoneMessage(kind: .reminder, title: reminder.title ?? old.title, plan: plan) + note
    }
}
