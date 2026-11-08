import CheMCPKit
import EventKit
import Foundation

/// #287: when the batch pre-check (#248 B) refuses a batch undo because some members' calendars or
/// lists are missing or read-only, `undo` with `restore_available` restores the members whose
/// destination is in place and keeps a record of only the others, under the same id, as a write
/// that fails part-way has been kept since #248 A (`CalendarUndoManager.restoreFailedUndo(_:remaining:)`).
/// Opt-in, so the agent asks the user before a batch is split; without the argument the refusal
/// stands. Members are restored independently, in the order a whole batch undo runs them (the
/// reverse of the recorded order, `UndoBatchExecution`): each recreates one item and reads
/// no other member's result (a deleted occurrence too, #244), so none needs another one with it.
/// A destination that is only unavailable for now (an account still syncing) leaves the kept
/// members for a later undo, which the text says.
enum UndoBatchPartialRestore {
    /// The members split by whether every item they would recreate has its calendar or list in
    /// place, in record order, with the findings that stop the blocked ones.
    struct Split {
        let restorable: [UndoOperation]
        let blocked: [UndoOperation]
        let findings: [UndoRestoreFinding]
    }

    /// A member is blocked when any destination it recreates an item in has a problem; a nested
    /// batch is one member, kept whole (no tool records one today).
    static func split(_ members: [UndoOperation],
                      problem: (UndoRestoreDestination) -> UndoRestoreProblem?) -> Split {
        var restorable: [UndoOperation] = []
        var blocked: [UndoOperation] = []
        var findings: [UndoRestoreFinding] = []
        for member in members {
            let found = UndoRestoreDestination.of([member], verb: .undo).compactMap { destination in
                problem(destination).map { UndoRestoreFinding(destination: destination, problem: $0) }
            }
            if found.isEmpty {
                restorable.append(member)
            } else {
                blocked.append(member)
                findings += found
            }
        }
        return Split(restorable: restorable, blocked: blocked, findings: findings)
    }

    /// The steps of a batch undo. `verify` is #248 B's pre-check; when it refuses and the caller
    /// asked, `split` reads the calendars and lists once more, and only the restorable members run.
    /// The refusal stands when the caller did not ask, or when no member can be restored (then as
    /// `UndoBatchRestoreAvailableRefusal`, which says the second read found nothing restorable); when every
    /// destination is back by the time of the split, the whole batch runs. A part-way failure on the
    /// restorable members keeps #248 A's remainder and the blocked members too
    /// (`UndoBatchPartialRestoreStoppedError`). `kept` is the split when members were kept.
    static func run<Outcome>(_ members: [UndoOperation], restoreAvailable: Bool,
                             verify: () async throws -> Void,
                             split: () async throws -> Split,
                             runMembers: ([UndoOperation]) async throws -> Outcome,
                             isolation: isolated (any Actor)? = #isolation) async throws -> (outcome: Outcome, kept: Split?) {
        // The pre-check alone: a member's own run (a nested batch) may raise the same error, which
        // is not this batch's refusal.
        var refused: UndoRestoreDestinationMissingError?
        do {
            try await verify()
        } catch let error as UndoRestoreDestinationMissingError {
            refused = error
        }
        guard let refusal = refused else { return (try await runMembers(members), nil) }
        guard restoreAvailable else { throw refusal }
        let parts = try await split()
        guard !parts.restorable.isEmpty else { throw UndoBatchRestoreAvailableRefusal(refusal, reason: .nothingRestorable) }
        guard !parts.blocked.isEmpty else { return (try await runMembers(members), nil) }
        do {
            return (try await runMembers(parts.restorable), parts)
        } catch let partial as UndoBatchPartiallyUndoneError {
            throw UndoBatchPartialRestoreStoppedError(partial: partial, kept: parts)
        } catch is UndoRestoreDestinationMissingError {
            // PR #496 round 1: a calendar or list gone between the split and the subset's own check;
            // nothing was written, and the answer is the whole entry's refusal.
            throw UndoBatchRestoreAvailableRefusal(refusal, reason: .goneBeforeTheWrites)
        } catch let permanent as UnrecoverableUndoError {
            // PR #496 round 1: #248 A passes a permanent error on alone when nothing was restored and
            // no other member waits (one restorable member); `handleUndo` would discard the whole
            // record, blocked members included, which the plain path keeps as never attempted.
            // Every other error discards nothing (`UndoFailureDisposition`) and is passed on: the
            // record is kept whole, and nothing of it was written.
            throw UndoBatchPartialRestoreStoppedError(permanent: permanent, kept: parts)
        }
    }

    /// The answer of a partial restore: what the restored members' undo said, then what is kept and
    /// why, and that discard_id drops only those.
    static func keptMessage(restored: String, kept: Split) -> String {
        let count = kept.blocked.count
        let items = count == 1 ? "1 item of this batch was" : "\(count) items of this batch were"
        let those = count == 1 ? "that item" : "those \(count) items"
        // The batch text may already end with a sentence of its own (#261's differences).
        return restored + (restored.hasSuffix(".") ? " " : ". ") + "\(items) not restored, because the calendar or list each would be recreated in is missing or read-only: "
            + describe(kept.findings) + "."
            + " This history entry was kept with only \(those), under the same id; run undo again once their calendar or list is back"
            + " (with restore_available set to true if only some of them can be restored then)."
            + " A calendar or list that was deleted, or whose account was removed, does not come back."
            + " Giving up this undo with discard_id drops only \(those) and cannot be reversed: ask the user first; if they agree, read undo_history and call undo with discard_id set to its id."
    }

    /// How many items are stopped, per calendar or list and problem, with up to three titles each, in
    /// the order the batch meets them. A calendar or list is described, not named (#37): a shared
    /// calendar's title is set remotely and an account name is often an e-mail address; its recorded
    /// identifier only keeps two of them apart.
    static func describe(_ findings: [UndoRestoreFinding]) -> String {
        var groups: [(key: String, item: String, words: String, titles: [String])] = []
        for finding in findings {
            let (item, container) = finding.destination.isReminder ? ("reminder", "list") : ("event", "calendar")
            let state = finding.problem == .missing ? "is not available" : "is read-only"
            let key = "\(item)|\(finding.destination.containerID)|\(state)"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].titles.append(finding.destination.itemTitle)
            } else {
                groups.append((key, item, "in a \(container) that \(state)", [finding.destination.itemTitle]))
            }
        }
        return groups.map { group in
            let shown = group.titles.prefix(3).map { "'\(undoShownTitle($0))'" }.joined(separator: ", ")
            let more = group.titles.count > 3 ? ", …" : ""
            let noun = group.titles.count == 1 ? group.item : group.item + "s"
            return "\(group.titles.count) \(noun) \(group.words): \(shown)\(more)"
        }.joined(separator: "; ")
    }
}

private extension UndoRestoreDestination {
    var isReminder: Bool {
        if case .reminderList = self { return true }
        return false
    }

    /// The recorded calendar or list identifier, which keeps two of them apart in the text.
    var containerID: String {
        switch self {
        case .eventCalendar(let snapshot): return snapshot.calendarIdentifier
        case .reminderList(let snapshot): return snapshot.calendarIdentifier
        }
    }
}

/// #287: a partial restore finished. Not shown as an error: `handleUndo` puts back a record of
/// `kept` under the same id and answers with `message`, a success that kept some items.
///
/// The message is author-controlled text plus what `UndoOperation.batchUndoneMessage` built for the
/// restored members and the recorded titles of the kept items through `undoShownTitle`; no calendar,
/// list or account name.
struct UndoBatchKeptUnavailable: Error, Sendable {
    let kept: [UndoOperation]
    /// The members restored, for the redo record (PR #496 round 1).
    let restored: [UndoOperation]
    let message: String
}

/// #287: a partial restore stopped part-way on the restorable members (#248 A). `remaining` is
/// the blocked members first (they run last next time), then #248 A's remainder in its order.
/// `handleUndo` puts back a record of `remaining` under the same id; it is never empty, since a
/// partial restore runs only with members kept.
///
/// The message is #248 A's (`UndoBatchPartiallyUndoneError`, itself a trusted message), or, when
/// that one would say the entry was discarded, a replacement built here, plus author-controlled text
/// and the recorded titles of the kept items through `undoShownTitle`.
struct UndoBatchPartialRestoreStoppedError: LocalizedError, Sendable {
    let remaining: [UndoOperation]
    let message: String
    var errorDescription: String? { message }

    init(remaining: [UndoOperation], message: String) {
        self.remaining = remaining
        self.message = message
    }
    init(partial: UndoBatchPartiallyUndoneError, kept: UndoBatchPartialRestore.Split) {
        let count = kept.blocked.count
        let items = count == 1 ? "1 item whose calendar or list is missing or read-only was" : "\(count) items whose calendar or list is missing or read-only were"
        let notAttempted = " \(items) not attempted (restore_available): " + UndoBatchPartialRestore.describe(kept.findings) + "."
        let those = count == 1 ? "the 1 item" : "the \(count) items"
        if partial.remaining.isEmpty {
            // #248 A would say the entry was discarded; it is kept for the blocked items. What the
            // restored items did not carry over is still named (PR #496 round 1).
            let restored = partial.restoredCount == 1 ? "1 item was" : "\(partial.restoredCount) items were"
            let loss = (UndoOperation.batchLossNote(events: partial.restoredEvents).map { " For the items restored: \($0)." } ?? "")
                + UndoRestoredDifference.sentences(partial.restoredDiffering)
            message = "Undo of this batch stopped part-way: \(restored) restored, then one item cannot be restored by any retry and was dropped from this history entry."
                + loss + notAttempted
                + " The entry was kept with only \(those) whose calendar or list is missing or read-only, under the same id; run undo again once their calendar or list is back."
                + Self.giveUp(those)
                + " The dropped item's own error follows; what it says about this history entry is superseded by this message: \(partial.memberError)"
        } else {
            // #248 A's text counts only its own remainder; the blocked items are kept too, before the
            // member's own error (PR #496 round 1).
            let total = partial.remaining.count + count
            // PR #496 round 2: with those kept, a plain undo refuses the entry whole, so the retry
            // that #248 A's text describes needs the argument again.
            let note = notAttempted + " Besides the items not yet restored counted above, \(those) are kept in this history entry too, first, so they run after the others, so the entry holds \(total) items; giving up with discard_id drops them as well."
                + " While their calendar or list is missing or read-only a plain undo refuses this entry whole: to retry the items not yet restored, run undo again with restore_available set to true."
            let marker = " The failed item's own error follows;"
            if let range = partial.message.range(of: marker) {
                message = partial.message[..<range.lowerBound] + note + partial.message[range.lowerBound...]
            } else {
                message = partial.message + note
            }
        }
        self.remaining = kept.blocked + partial.remaining
    }

    /// PR #496 round 1: the restorable items' undo failed for good before any item was restored (#248
    /// A passes such an error on alone). Those items are dropped, as the plain path drops them, and
    /// the blocked ones, never attempted, are kept.
    init(permanent: UnrecoverableUndoError, kept: UndoBatchPartialRestore.Split) {
        let count = kept.blocked.count
        let those = count == 1 ? "the 1 item" : "the \(count) items"
        let restorable = kept.restorable.count == 1 ? "the 1 item whose calendar or list is in place" : "the \(kept.restorable.count) items whose calendar or list is in place"
        // PR #496 round 2: "confirmed", since a failed series restore may leave the series written.
        message = "Undo of this batch stopped with no item confirmed restored: restoring \(restorable) failed in a way no retry can restore, so \(kept.restorable.count == 1 ? "it was" : "they were") dropped from this history entry."
            + " Not attempted, because their calendar or list is missing or read-only: " + UndoBatchPartialRestore.describe(kept.findings) + "."
            + " The entry was kept with only \(those) whose calendar or list is missing or read-only, under the same id; run undo again once their calendar or list is back."
            + Self.giveUp(those)
            + " The failed item's own error follows; what it says about this history entry is superseded by this message: \(permanent.message)"
        remaining = kept.blocked
    }

    private static func giveUp(_ those: String) -> String {
        " Giving up this undo with discard_id drops only \(those), and cannot be reversed: ask the user first; if they agree, read undo_history and call undo with discard_id set to its id."
    }
}

extension UndoBatchPartialRestoreStoppedError: TrustedErrorMessage {}

/// PR #496 round 2: #248 B's whole-entry refusal, answered to a caller who passed
/// `restore_available`, so it does not tell them to pass it and says why it did not help. Nothing
/// was written; `handleUndo` keeps the record whole (not an `UnrecoverableUndoError`).
///
/// The message is the refusal's (a trusted message), with its last sentence, which names the
/// argument, left out, plus author-controlled text.
struct UndoBatchRestoreAvailableRefusal: LocalizedError, Sendable {
    enum Reason: Sendable {
        /// The second read, for the split, found no item with its calendar or list in place.
        case nothingRestorable
        /// The restorable items' own pre-check, just before their writes, found a calendar or list
        /// missing or read-only.
        case goneBeforeTheWrites
    }

    let message: String
    var errorDescription: String? { message }

    init(_ refusal: UndoRestoreDestinationMissingError, reason: Reason) {
        // The refusal's sentence that names the argument is its last (`init(findings:total:)`).
        let base = refusal.message.range(of: " To restore the ").map { String(refusal.message[..<$0.lowerBound]) } ?? refusal.message
        switch reason {
        case .nothingRestorable:
            message = base + " restore_available was passed, but when the calendars and lists were read again for it, no item had its calendar or list in place, so nothing was restored."
        case .goneBeforeTheWrites:
            message = base + " restore_available was passed, but by the time of their writes a calendar or list of the items to restore was missing or read-only, so nothing was written; run undo with restore_available again to restore the items whose calendar or list is in place then."
        }
    }
}

extension UndoBatchRestoreAvailableRefusal: TrustedErrorMessage {}

extension EventKitManager {
    /// #287: the split of a refused batch, from the calendars and lists the restore reads (#269's
    /// `eventCalendarsForRestore`, #242's `reminderListsForRestore`), read once more after the
    /// pre-check's refusal requested a refresh, and judged by `UndoRestoreDestination.problems`.
    func splitByRestoreDestination(_ members: [UndoOperation]) async throws -> UndoBatchPartialRestore.Split {
        let destinations = UndoRestoreDestination.of(members, verb: .undo)
        let needsCalendars = destinations.contains { if case .eventCalendar = $0 { return true }; return false }
        let needsLists = destinations.contains { if case .reminderList = $0 { return true }; return false }
        let eventCalendars = needsCalendars ? try await eventCalendarsForRestore() : []
        let reminderLists = needsLists ? try await reminderListsForRestore() : []
        return UndoBatchPartialRestore.split(members) { destination in
            UndoRestoreDestination.problems(among: [destination], eventCalendars: eventCalendars, reminderLists: reminderLists,
                                            identifier: { $0.calendarIdentifier },
                                            allowsModifications: { $0.allowsContentModifications }).first?.problem
        }
    }
}
