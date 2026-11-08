import CheMCPKit
import EventKit
import Foundation

/// #287: when the batch pre-check (#248 B) refuses a batch undo because some members' calendars or
/// lists are missing or read-only, `undo` with `restore_available` restores the members whose
/// destination is in place and keeps a record of only the others, under the same id, as a write
/// that fails part-way has been kept since #248 A (`CalendarUndoManager.restoreFailedUndo(_:remaining:)`).
/// Opt-in, so the agent asks the user before a batch is split; without the argument the refusal
/// stands. Members are restored independently, in recorded order: each recreates one item and reads
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
    /// The refusal stands when the caller did not ask, or when no member can be restored; when every
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
        guard !parts.restorable.isEmpty else { throw refusal }
        guard !parts.blocked.isEmpty else { return (try await runMembers(members), nil) }
        do {
            return (try await runMembers(parts.restorable), parts)
        } catch let partial as UndoBatchPartiallyUndoneError {
            throw UndoBatchPartialRestoreStoppedError(partial: partial, kept: parts)
        }
    }

    /// The answer of a partial restore: what the restored members' undo said, then what is kept and
    /// why, and that discard_id drops only those.
    static func keptMessage(restored: String, kept: Split) -> String {
        let count = kept.blocked.count
        let items = count == 1 ? "1 item of this batch was" : "\(count) items of this batch were"
        let those = count == 1 ? "that item" : "those \(count) items"
        return restored + ". \(items) not restored, because the calendar or list each would be recreated in is missing or read-only: "
            + describe(kept.findings) + "."
            + " This history entry was kept with only \(those), under the same id; run undo again once their calendar or list is back"
            + " (with restore_available set to true if only some of them can be restored then)."
            + " A calendar or list that was deleted, or whose account was removed, does not come back."
            + " Giving up this undo with discard_id drops only \(those) and cannot be reversed: ask the user first; if they agree, read undo_history and call undo with discard_id set to its id."
    }

    /// How many items are stopped, by kind and problem, with up to three titles each, in the order
    /// the batch meets them. No calendar, list or account name (#37): a shared calendar's title is set
    /// remotely and an account name is often an e-mail address.
    static func describe(_ findings: [UndoRestoreFinding]) -> String {
        var groups: [(key: String, item: String, words: String, titles: [String])] = []
        for finding in findings {
            let (item, container) = finding.destination.isReminder ? ("reminder", "list") : ("event", "calendar")
            let state = finding.problem == .missing ? "is not available" : "is read-only"
            let key = "\(item)|\(state)"
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
}

/// #287: a partial restore finished. Not shown as an error: `handleUndo` puts back a record of
/// `kept` under the same id and answers with `message`, a success that kept some items.
///
/// The message is author-controlled text plus what `UndoOperation.batchUndoneMessage` built for the
/// restored members and the recorded titles of the kept items through `undoShownTitle`; no calendar,
/// list or account name.
struct UndoBatchKeptUnavailable: Error, Sendable {
    let kept: [UndoOperation]
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
        let note = " \(items) not attempted (restore_available): " + UndoBatchPartialRestore.describe(kept.findings) + "."
        if partial.remaining.isEmpty {
            // #248 A would say the entry was discarded; it is kept for the blocked items.
            let restored = partial.restoredCount == 1 ? "1 item was" : "\(partial.restoredCount) items were"
            let those = count == 1 ? "the 1 item" : "the \(count) items"
            message = "Undo of this batch stopped part-way: \(restored) restored, then one item cannot be restored by any retry and was dropped from this history entry."
                + note
                + " The entry was kept with only \(those) whose calendar or list is missing or read-only, under the same id; run undo again once their calendar or list is back."
                + " Giving up this undo with discard_id drops only those, and cannot be reversed: ask the user first; if they agree, read undo_history and call undo with discard_id set to its id."
                + " The dropped item's own error follows: \(partial.memberError)"
        } else {
            message = partial.message + note
                + " They are kept in this history entry too, first, so they run after the items not yet restored; giving up with discard_id drops them as well."
        }
        self.remaining = kept.blocked + partial.remaining
    }
}

extension UndoBatchPartialRestoreStoppedError: TrustedErrorMessage {}

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
