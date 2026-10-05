import CheMCPKit
import EventKit
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
            throw UndoTargetMissingError(verb: verb, kind: expected.kind, title: expected.title,
                                         hasIdentifier: !expected.itemID.isEmpty)
        }
        let changed = try conflicts(item)
        guard changed.isEmpty else {
            throw refusal?(item, changed)
                ?? UndoTargetChangedError(verb: verb, kind: expected.kind, title: expected.title, changedFields: changed)
        }
        return item
    }
}

/// The title as an undo error, the undo history or a redo instruction shows it. The errors are
/// `TrustedErrorMessage`, so the store-derived title reaches the client verbatim, between quotes
/// and next to instructions. Best effort (PR #259 rounds 4–6), not a guarantee:
/// - every format character (general category Cf: zero-width, bidirectional controls, soft
///   hyphen, invisible operators, tags, annotation marks…) is dropped, except a keep-list of the
///   ones that show or join something: ZWNJ U+200C and ZWJ U+200D (Persian words, emoji
///   sequences) and the visible marks U+0600–0605, U+06DD, U+070F, U+0890, U+0891, U+08E2,
///   U+110BD, U+110CD;
/// - controls (Cc), line and paragraph separators (Zl, Zp), and these invisible characters of
///   other categories or not yet assigned: U+034F, U+115F, U+1160, U+17B4, U+17B5,
///   U+180B–180F, U+2065, U+2800, U+3164, U+FFA0, U+FFF0–FFF8, U+FFF9–FFFB, the variation
///   selectors U+FE00–FE0F and U+E0100–E01EF, U+E01F0–E0FFF, the tag block U+E0000–E007F and
///   U+1D173–1D17A.
/// General-category membership changes between Unicode versions (U+180E left Zs for Cf; U+0890
/// and U+0891 are recent Cf), so what the toolchain's tables say decides the rest. A quote is
/// replaced so the title cannot close its quotes, and the length is capped at 120 Unicode
/// scalars, so combining marks cannot stretch it. A visible title can still read like an
/// instruction.
func undoShownTitle(_ title: String) -> String {
    let dropped: (Unicode.Scalar) -> Bool = { scalar in
        switch scalar.value {
        case 0x200C, 0x200D, 0x0600...0x0605, 0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2, 0x110BD, 0x110CD:   // keep-list
            return false
        case 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F, 0x2065, 0x2800, 0x3164, 0xFFA0,
             0xFFF0...0xFFF8, 0xFFF9...0xFFFB, 0xFE00...0xFE0F, 0xE0100...0xE01EF, 0xE01F0...0xE0FFF,
             0xE0000...0xE007F, 0x1D173...0x1D17A:
            return true
        default:
            switch scalar.properties.generalCategory {
            case .format, .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
    let clean = EventKitErrorSanitizer.sanitizeForInterpolation(title).unicodeScalars
        .filter { !dropped($0) }
        .map { $0 == "'" ? "\u{2019}" : $0 }
    let capped = clean.prefix(120)
    var shown = String(String.UnicodeScalarView(capped))
    if clean.count > 120 { shown += "…" }
    return shown
}

/// #236: the item an undo or redo would write to no longer holds the state the recorded
/// operation (for a redo: the undo) left, and the write would change it again. Nothing is
/// written, and the record is kept (D2, the #206 posture for not-found): `UndoFailureDisposition.of`
/// maps this error to `.restore`. The message says what can be done for the kind of change.
///
/// The message is author-controlled text: the verb, the item kind and the field names come from
/// closed sets in this module, and the store-derived title passes `undoShownTitle`. That is the
/// condition under which this type conforms to `TrustedErrorMessage`.
struct UndoTargetChangedError: LocalizedError, Sendable {
    /// What the user can do about the change.
    enum Situation: Sendable {
        /// A field someone changed: changing it back makes the undo possible again.
        case revertable
        /// Occurrences of a series edited on their own: no tool or app puts them back.
        case editedOccurrences
        /// The series' occurrences could not be checked for individual edits.
        case uncheckedOccurrences
        /// A recurring reminder's completion, on a record that cannot confirm the occurrence.
        case unconfirmedOccurrence
        /// The rule of a created event was shortened (rounds 5–7): an update or delete of an
        /// occurrence and the following ones does this, and the part cut off cannot be put back.
        case changedRecurrence
    }

    let message: String
    var errorDescription: String? { message }

    init(verb: UndoHistoryVerb, kind: UndoPostState.Kind, title: String, changedFields: [String], situation: Situation? = nil) {
        let item = "\(kind.rawValue) '\(undoShownTitle(title))'"
        let fields = changedFields.joined(separator: ", ")
        let kept = verb == .undo ? "this history entry was kept" : "this redo entry was kept"
        let giveUp = verb == .undo
            ? "ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id"
            : "ask the user whether to give up this redo; any new change clears the redo history"
        let derived: Situation = changedFields.contains("modified_occurrences") ? .editedOccurrences
            : changedFields.contains("unchecked_occurrences") ? .uncheckedOccurrences : .revertable
        switch situation ?? derived {
        case .revertable where verb == .undo:
            message = "Cannot undo: the \(item) was changed after this operation, in another app or by the calendar server (\(fields)). Undoing now would overwrite or delete that change, so nothing was written and \(kept). Whoever made the change should decide: ask the user whether to change it back and run undo again, or to give up this undo; if they agree to give it up, read undo_history and call undo with discard_id set to its id."
        case .revertable:
            message = "Cannot redo: the \(item) was changed after the undo, in another app or by the calendar server (\(fields)). Redoing now would overwrite that change, so nothing was written and \(kept). Whoever made the change should decide: ask the user whether to change it back and run redo again; any new change clears the redo history."
        case .editedOccurrences:
            message = "Cannot \(verb.rawValue): occurrences of the \(item) were edited on their own after it was created (\(fields)). Undoing would delete those edits with the series, and an edited occurrence cannot be put back into its series, so nothing was written and \(kept). To go on, \(giveUp); the series can then be deleted by hand if it should still go."
        case .uncheckedOccurrences:
            message = "Cannot \(verb.rawValue): the occurrences of the \(item) could not be checked for individual edits (\(fields)), and undoing would delete every occurrence of the series, so nothing was written and \(kept). To go on, \(giveUp); the series can then be deleted by hand if it should still go."
        case .changedRecurrence:
            message = "Cannot \(verb.rawValue): the series of the \(item) was shortened after it was created (\(fields)); an update or delete of an occurrence and the following ones does this. Undoing would delete the series as it is now, and the part cut off cannot be put back, so nothing was written and \(kept). To go on, \(giveUp); the series can then be deleted by hand if it should still go."
        case .unconfirmedOccurrence:
            message = "Cannot \(verb.rawValue): the completion of the recurring \(item) differs from the state this operation expects (\(fields)), and the record cannot confirm which occurrence its identifier points at now: it may be a later occurrence of the series (EventKit advances a recurring reminder in place). Nothing was written and \(kept). To go on, \(giveUp), and act on the intended occurrence explicitly (list_reminders with completed=true, then complete_reminder)."
        }
    }
}

extension UndoTargetChangedError: TrustedErrorMessage {}

/// #236, PR #259 round 1 findings 10 / 17: the item an undo or redo writes to was not found
/// under its recorded identifier (deleted, moved to another account, or not visible to the store
/// yet), or the record has no identifier. Kept like every not-found (#191; `undo-history-discard`
/// spec); the message says how to drop the entry, and offers running it again only for an item
/// that may still be syncing (round 2, findings 18 and 20). `TrustedErrorMessage` on the same
/// terms as `UndoTargetChangedError`.
struct UndoTargetMissingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(verb: UndoHistoryVerb, kind: UndoPostState.Kind, title: String, hasIdentifier: Bool) {
        let item = "\(kind.rawValue) '\(undoShownTitle(title))'"
        let kept = verb == .undo ? "this history entry was kept" : "this redo entry was kept"
        let giveUp = verb == .undo
            ? "ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id"
            : "ask the user whether to give up this redo; any new change clears the redo history"
        if hasIdentifier {
            message = "Cannot \(verb.rawValue): the \(item) was not found under its recorded identifier. Nothing was written and \(kept). If it was deleted or moved to another account, no retry can find it: \(giveUp). Run \(verb.rawValue) again only if it may still be syncing."
        } else {
            message = "Cannot \(verb.rawValue): the \(item) was recorded without an identifier, so it cannot be found. Nothing was written and \(kept): \(giveUp)."
        }
    }
}

extension UndoTargetMissingError: TrustedErrorMessage {}

extension UndoOperation {
    /// The error for a post-state refusal of `item`. Kept (`.restore`), as the spec keeps refused
    /// records, with one exception: a completion record of a recurring reminder kept without the
    /// #204 occurrence snapshot whose identifier resolves to a reminder that still repeats and has
    /// the opposite completion of what the record expects. That is the shape a rollover leaves
    /// (EventKit advances the series in place), the record can never match it again, and keeping
    /// it would block every older entry until `discard_id`; it is discarded, as #204 does (PR #259
    /// round 3, finding 8). Which situation applies otherwise comes from the record, not from the
    /// item's current rules (round 2, findings 2, 9, 13, 21).
    func postStateRefusal(verb: UndoHistoryVerb, changedFields: [String], current item: EKCalendarItem?) -> Error {
        let expected = verb == .undo ? undoPostState : redoPostState
        var situation: UndoTargetChangedError.Situation?
        // Discard-only for a shortened rule (rounds 6–7); any other change of the rule can be
        // changed back.
        if case .createEvent(_, _, let created) = self, changedFields.contains("recurrence"),
           let event = item as? EKEvent,
           RecurrenceRuleSnapshot.wasShortened(recorded: created.recurrenceRules,
                                               current: event.recurrenceRules?.map(RecurrenceRuleSnapshot.init(from:))) {
            situation = .changedRecurrence
        }
        if case .completeReminder(_, _, _, _, let title, _, true) = self {
            if let reminder = item as? EKReminder, reminder.hasRecurrenceRules,
               case .reminderCompletion(_, _, let state, _)? = expected, reminder.isCompleted != state.isCompleted {
                return Self.successorShapeRefusal(title: title, verb: verb)
            }
            situation = .unconfirmedOccurrence
        }
        return UndoTargetChangedError(verb: verb, kind: expected?.kind ?? .reminder, title: expected?.title ?? "",
                                      changedFields: changedFields, situation: situation)
    }

    /// Round 3, finding 8: the unconfirmed recurring completion in the successor shape. Permanent,
    /// like #204's identity refusal.
    static func successorShapeRefusal(title: String, verb: UndoHistoryVerb) -> UnrecoverableUndoError {
        let entry = verb == .undo ? "This history entry was discarded" : "This redo entry was discarded"
        return UnrecoverableUndoError(message: "Cannot \(verb.rawValue) the completion of the recurring reminder '\(undoShownTitle(title))': its identifier now resolves to an occurrence with the opposite completion of what this operation expects, which is what EventKit leaves when it advances a recurring reminder in place, and this record kept no occurrence snapshot to tell which occurrence that is. Nothing was written. \(entry) so earlier operations remain undoable. Act on the intended occurrence explicitly (list_reminders with completed=true, then complete_reminder).")
    }

    /// #204: the identity-guarded record's identifier no longer resolves to the recorded
    /// occurrence. Permanent: the entry is discarded so earlier operations stay undoable.
    static func occurrenceIdentityRefusal(before: ReminderCompletionSnapshot, verb: String) -> UnrecoverableUndoError {
        UnrecoverableUndoError(message: "Cannot \(verb) recurring reminder completion of '\(undoShownTitle(before.title))': its identifier no longer resolves to the recorded occurrence — the series advanced (EventKit keeps the finished occurrence as a separate completed record) or the item's due, rules, list or source were edited since. Act on the intended occurrence explicitly (list_reminders with completed=true, then complete_reminder). This history entry was discarded so earlier operations remain undoable.")
    }
}
