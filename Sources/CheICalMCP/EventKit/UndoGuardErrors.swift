import CheMCPKit
import Foundation

/// #236 — the step every undo / redo arm runs before it writes, and the errors it produces.

/// The order an arm resolves and checks its target in: look the item up, `refresh()` it (a
/// long-lived store returns stale fields until then; diagnosis evidence 2, confirmed on device),
/// compare, and hand back the refreshed object, the only one the arm writes to. Generic over
/// the item so the order is unit-tested without EventKit (closure seam, like `ExclusionExecutor`).
/// The EventKit side (which lookup, the series scan, the #204 identity guard) is in
/// `EventKitManager+UndoGuard.swift`.
enum UndoTargetCheck {
    static func check<Item>(_ expected: UndoPostState, verb: UndoHistoryVerb,
                            lookup: () throws -> Item?, refresh: (Item) -> Bool,
                            conflicts: (Item) throws -> [String],
                            refusal: ((Item, [String]) -> Error)? = nil) throws -> Item {
        guard let item = try lookup(), refresh(item) else {
            throw UndoTargetMissingError(verb: verb, kind: expected.kind, title: expected.title)
        }
        let changed = try conflicts(item)
        guard changed.isEmpty else {
            throw refusal?(item, changed)
                ?? UndoTargetChangedError(verb: verb, kind: expected.kind, title: expected.title, changedFields: changed)
        }
        return item
    }
}

/// The title as an undo error shows it: store-derived and returned verbatim (the errors are
/// `TrustedErrorMessage`), so control characters are stripped and the length capped at 120
/// characters (PR #259 verify #19).
private func shownTitle(_ title: String) -> String {
    let clean = EventKitErrorSanitizer.sanitizeForInterpolation(title)
    return clean.count > 120 ? String(clean.prefix(120)) + "…" : clean
}

/// #236: the item an undo or redo would write to no longer holds the state the recorded
/// operation (for a redo: the undo) left, and the write would change it again. Nothing is
/// written, and the record is kept: the user can revert the change and retry, so the refusal is
/// not permanent (D2, the #206 posture for not-found), and `UndoFailureDisposition.of` maps it to
/// `.restore`.
///
/// The message is author-controlled text: the verb, the item kind and the field names come from
/// closed sets in this module, and the store-derived title passes `shownTitle`. That is the
/// condition under which this type conforms to `TrustedErrorMessage`.
struct UndoTargetChangedError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(verb: UndoHistoryVerb, kind: UndoPostState.Kind, title: String, changedFields: [String]) {
        let item = "\(kind.rawValue) '\(shownTitle(title))'"
        let fields = changedFields.joined(separator: ", ")
        switch verb {
        case .undo:
            message = "Cannot undo: the \(item) was changed after this operation, in another app or by the calendar server (\(fields)). Undoing now would overwrite or delete that change, so nothing was written and this history entry was kept. Revert the change and run undo again, or ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."
        case .redo:
            message = "Cannot redo: the \(item) was changed after the undo, in another app or by the calendar server (\(fields)). Redoing now would overwrite that change, so nothing was written and this redo entry was kept. Revert the change and run redo again; any new change clears the redo history."
        }
    }
}

extension UndoTargetChangedError: TrustedErrorMessage {}

/// #236, PR #259 verify #10 / #17: the item an undo or redo writes to was not found under its
/// recorded identifier (deleted, moved to another account, or not visible to the store yet).
/// Kept for a retry like every not-found (#191; `undo-history-discard` spec), and the message now
/// says how to drop the entry. `TrustedErrorMessage` on the same terms as
/// `UndoTargetChangedError`.
struct UndoTargetMissingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(verb: UndoHistoryVerb, kind: UndoPostState.Kind, title: String) {
        let item = "\(kind.rawValue) '\(shownTitle(title))'"
        switch verb {
        case .undo:
            message = "Cannot undo: the \(item) was not found under its recorded identifier (deleted, moved to another account, or not synced yet). Nothing was written and this history entry was kept: retry later, or ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."
        case .redo:
            message = "Cannot redo: the \(item) was not found under its recorded identifier (deleted, moved to another account, or not synced yet). Nothing was written and this redo entry was kept; any new change clears the redo history."
        }
    }
}

extension UndoTargetMissingError: TrustedErrorMessage {}

extension UndoOperation {
    /// The error for a post-state refusal. A legacy completion record (no #204 identity
    /// snapshot) on a recurring reminder whose completion no longer matches most likely points
    /// at a later occurrence now: EventKit advances a recurring reminder in place. No revert can
    /// bring the recorded occurrence back, so the record is discarded with that reason, as #204
    /// does for identifiable items (PR #259 verify #4 / #18 / #20). Every other refusal keeps the
    /// record.
    func postStateRefusal(verb: UndoHistoryVerb, changedFields: [String], itemIsRecurring: Bool) -> Error {
        if case .completeReminder(_, _, _, _, let title, _) = self, itemIsRecurring {
            return UnrecoverableUndoError(message: "Cannot \(verb.rawValue) completion of recurring reminder '\(shownTitle(title))': its identifier now resolves to a reminder whose completion differs from the one this operation left, most likely a later occurrence of the series (EventKit advances a recurring reminder in place). Act on the intended occurrence explicitly (list_reminders with completed=true, then complete_reminder). This history entry was discarded so earlier operations remain undoable.")
        }
        let kind = undoPostState?.kind ?? .reminder
        let title = undoPostState?.title ?? ""
        return UndoTargetChangedError(verb: verb, kind: kind, title: title, changedFields: changedFields)
    }
}
