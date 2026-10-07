import CheMCPKit
import Foundation

/// #248 — a batch undo restores all of its members or none of them when one cannot be restored.
/// The batch record is the unit of history while the writes are per member, so a member that
/// failed after earlier members were written used to put the whole record back, and the next undo
/// recreated those members again.

/// B: where the undo of a batch member recreates its item. Only the delete records recreate; every
/// other record writes to an existing item, which the post-state check covers, or writes nothing.
enum UndoRestoreDestination {
    /// The recorded calendar, resolved as `applySnapshot` resolves it (`EventSnapshot.resolveCalendar`).
    case eventCalendar(EventSnapshot)
    /// The list `applyReminderSnapshot` picks.
    case reminderList(ReminderSnapshot)

    /// The title of the item that would be recreated.
    var itemTitle: String {
        switch self {
        case .eventCalendar(let snapshot): return snapshot.title
        case .reminderList(let snapshot): return snapshot.title
        }
    }

    /// Every destination an undo of `members` recreates items in, nested batches included, in record
    /// order. The batch pre-check reads the calendars and lists once for all of them.
    static func of(_ members: [UndoOperation], verb: UndoHistoryVerb) -> [UndoRestoreDestination] {
        members.flatMap { member -> [UndoRestoreDestination] in
            if case .batch(let inner) = member { return of(inner, verb: verb) }
            return member.restoreDestination(verb: verb).map { [$0] } ?? []
        }
    }

    /// The first destination whose calendar or list is gone from `eventCalendars` / `reminderLists`,
    /// which the batch pre-check reads once. The lookups are the ones the restore makes, by recorded
    /// identifier: `EventSnapshot.resolveCalendar` (`applySnapshot`) and
    /// `ReminderSnapshot.resolveList(for: .recreateDeleted)` (`applyReminderSnapshot` for the
    /// `.deleteReminder` undo). A list that only shares the recorded title, such as another
    /// account's "Reminders", does not pass (PR #282 round 1, finding 1). Generic over the list type
    /// so it is unit-tested without EventKit, as the two resolvers are.
    static func firstMissing<C>(among destinations: [UndoRestoreDestination], eventCalendars: [C],
                                reminderLists: [C], identifier: (C) -> String) -> UndoRestoreDestination? {
        destinations.first { destination in
            switch destination {
            case .eventCalendar(let snapshot):
                return (try? snapshot.resolveCalendar(in: eventCalendars, identifier: identifier)) == nil
            case .reminderList(let snapshot):
                return (try? snapshot.resolveList(in: reminderLists, identifier: identifier, for: .recreateDeleted)) == nil
            }
        }
    }

    /// The refusal when the destination is gone.
    var missingError: UndoRestoreDestinationMissingError {
        switch self {
        case .eventCalendar(let snapshot):
            return UndoRestoreDestinationMissingError(item: "event", title: snapshot.title, container: "calendar",
                                                      containerTitle: snapshot.calendarTitle,
                                                      accountTitle: snapshot.calendarSource)
        case .reminderList(let snapshot):
            return UndoRestoreDestinationMissingError(item: "reminder", title: snapshot.title, container: "list",
                                                      containerTitle: snapshot.calendarTitle,
                                                      accountTitle: snapshot.calendarSource)
        }
    }
}

extension UndoOperation {
    /// Where an undo of this record recreates the item, or nil. A redo of a delete writes nothing
    /// (#247). A batch is walked by `UndoRestoreDestination.of`. Exhaustive, so a new record kind
    /// must be classified to compile (#196 convention).
    func restoreDestination(verb: UndoHistoryVerb) -> UndoRestoreDestination? {
        guard verb == .undo else { return nil }
        switch self {
        case .deleteEvent(let snapshot):
            return .eventCalendar(snapshot)
        case .deleteReminder(let snapshot):
            return .reminderList(snapshot)
        case .createEvent, .updateEvent, .updateRecurringEvent, .moveEvent, .createReminder, .updateReminder,
             .completeReminder, .completeRecurringReminder, .batch:
            return nil
        }
    }
}

/// B: a batch member cannot be restored because the calendar or list it would be recreated in is
/// not there. Raised by the batch pre-check, so nothing of the batch was written; kept like a
/// not-found (`UndoFailureDisposition.of` maps it to `.restore`), since the calendar may only be
/// syncing.
///
/// The message is author-controlled text: the item and container words come from this file, and
/// the store-derived titles (a shared calendar's title is set by someone else, #37 F1) pass
/// `undoShownTitle`. That is the condition under which this type conforms to `TrustedErrorMessage`.
struct UndoRestoreDestinationMissingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(item: String, title: String, container: String, containerTitle: String, accountTitle: String?) {
        let account = accountTitle.map { " in '\(undoShownTitle($0))'" } ?? ""
        message = "Cannot undo: the deleted \(item) '\(undoShownTitle(title))' cannot be restored because the \(container) it was in ('\(undoShownTitle(containerTitle))'\(account)) is not available. Nothing in this batch was written and this history entry was kept. If that \(container) was deleted or its account removed, no retry can restore it: ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id. Run undo again only if the \(container) may still be syncing."
    }
}

extension UndoRestoreDestinationMissingError: TrustedErrorMessage {}

/// A: a batch undo stopped before its end, after `restoredCount` members were written (possibly
/// none). `handleUndo` puts back a record of `remaining` only, under the same id and timestamp
/// (`CalendarUndoManager.restoreFailedUndo(_:remaining:)`), so the next undo does not recreate the
/// restored members a second time. The failing member comes first in `remaining`, which undo runs
/// last, so the members never attempted get their turn even when that one keeps failing.
///
/// The message is author-controlled text plus `memberError`, which is either a sanitized code or
/// the verbatim message of a `TrustedErrorMessage` (`EventKitErrorSanitizer.writeFailureLog`). That
/// is the condition under which this type conforms to `TrustedErrorMessage`.
struct UndoBatchPartiallyUndoneError: LocalizedError, Sendable {
    /// The members not yet restored, in record order: the failing one first, then the ones never
    /// attempted.
    let remaining: [UndoOperation]
    let restoredCount: Int
    let memberError: String
    let message: String
    var errorDescription: String? { message }

    init(remaining: [UndoOperation], restoredCount: Int, memberError: String) {
        self.remaining = remaining
        self.restoredCount = restoredCount
        self.memberError = memberError
        let others = remaining.count - 1
        let what: String
        if restoredCount == 0 {
            what = "Undo of this batch wrote nothing: restoring one item failed. This history entry was kept, under the same id, with that item moved to the end, so running undo again tries the other \(others == 1 ? "item" : "\(others) items") first."
        } else {
            let restored = restoredCount == 1 ? "1 item was" : "\(restoredCount) items were"
            let left = remaining.count == 1 ? "the 1 item not yet restored" : "the \(remaining.count) items not yet restored"
            what = "Undo of this batch stopped part-way: \(restored) restored, then restoring the next one failed. This history entry was kept with only \(left), under the same id, and the item that failed comes last, so running undo again does not restore the others a second time."
        }
        message = what + " If that item keeps failing (for example, its calendar or list was deleted), ask the user whether to give up the rest of this undo; if they agree, read undo_history and call undo with discard_id set to its id. The failed item's own error follows; what it says about this history entry is superseded by this message: \(memberError)"
    }
}

extension UndoBatchPartiallyUndoneError: TrustedErrorMessage {}

extension UndoOperation {
    /// A: the error a batch undo reports when a write failed. `members` are in record order; the
    /// undo ran them in reverse, so the `interrupted.completed` members written are the last ones.
    /// The record keeps the failing member, moved to the front (it runs last next time), and the
    /// members never attempted. A failing member that is itself a batch stopped part-way is replaced
    /// by its own remainder (no nested batch is recorded today). When nothing was written and no
    /// other member is waiting, or the member error is permanent (`UnrecoverableUndoError`, which
    /// discards the record), the member error stands, as for a single record. `describe` gives the
    /// member error for the message; it is called only when the record is narrowed or reordered.
    static func batchUndoFailure(members: [UndoOperation], interrupted: UndoBatchRunner.Interrupted,
                                 describe: (Error) -> String) -> Error {
        let failedIndex = members.count - 1 - interrupted.completed
        guard members.indices.contains(failedIndex) else { return interrupted.underlying }
        let inner = interrupted.underlying as? UndoBatchPartiallyUndoneError
        let unattempted = Array(members[..<failedIndex])
        if inner == nil, interrupted.completed == 0,
           unattempted.isEmpty || interrupted.underlying is UnrecoverableUndoError {
            return interrupted.underlying
        }
        let failing: UndoOperation = inner.map { .batch($0.remaining) } ?? members[failedIndex]
        return UndoBatchPartiallyUndoneError(remaining: [failing] + unattempted,
                                             restoredCount: interrupted.completed + (inner?.restoredCount ?? 0),
                                             memberError: inner?.memberError ?? describe(interrupted.underlying))
    }
}

/// #248 A: the one way a batch record runs, for undo and redo alike, so no caller of
/// `UndoBatchRunner.run` can let `Interrupted` reach `handleUndo`, which would put the whole record
/// back after some members were written. `UndoBatchWiringTests` checks it is the runner's only caller.
enum UndoBatchExecution {
    /// Undo runs the members in reverse record order and reports a failed write through
    /// `UndoOperation.batchUndoFailure`. Redo runs them in record order and reports the member error
    /// as it is: no batch whose members write on redo is recorded (#247).
    static func run(_ members: [UndoOperation], verb: UndoHistoryVerb,
                    check: (UndoOperation) async throws -> Void,
                    execute: (UndoOperation) async throws -> String,
                    describe: (Error) -> String) async throws -> [String] {
        do {
            return try await UndoBatchRunner.run(verb == .undo ? Array(members.reversed()) : members,
                                                 check: check, execute: execute)
        } catch let interrupted as UndoBatchRunner.Interrupted {
            switch verb {
            case .undo: throw UndoOperation.batchUndoFailure(members: members, interrupted: interrupted, describe: describe)
            case .redo: throw interrupted.underlying
            }
        }
    }
}
