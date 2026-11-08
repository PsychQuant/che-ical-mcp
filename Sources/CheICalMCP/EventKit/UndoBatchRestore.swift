import CheMCPKit
import Foundation

/// #248 — a batch undo restores each member once. The batch record is the unit of history while
/// the writes are per member, so a member that failed after earlier members were written used to
/// put the whole record back, and the next undo recreated those members again. Now a pre-check
/// refuses the whole batch before any write when a member's calendar or list is missing or
/// read-only (B), and a write that fails part-way keeps only the members not yet restored in the
/// record (A); a partial restore after the pre-check is #287.

/// B: where the undo of a batch member recreates its item. Only the delete records recreate (a
/// deleted occurrence as a one-off event, #244); every other record writes to an existing item,
/// which the post-state check covers, or writes nothing.
enum UndoRestoreDestination {
    /// The recorded calendar, resolved as the event undo resolves it (`restoreCalendar(for:kind:)`, which
    /// calls `EventSnapshot.resolveCalendar`).
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

    /// Every destination that cannot take its item back, in record order: its calendar or list is
    /// not in `eventCalendars` / `reminderLists` (`.missing`), or is there but does not allow changes
    /// (`.readOnly`: a read-only shared or subscribed one, where the save would fail part-way through
    /// the batch, PR #282 round 2, finding 5). The lookups are the ones the restore makes, by
    /// recorded identifier: `EventSnapshot.resolveCalendar` (`restoreCalendar(for:kind:)`) and
    /// `ReminderSnapshot.resolveList(for: .recreateDeleted)` (`applyReminderSnapshot` for the
    /// `.deleteReminder` undo). A list that only shares the recorded title, such as another
    /// account's "Reminders", does not pass (PR #282 round 1, finding 1). Generic over the list type
    /// so it is unit-tested without EventKit, as the two resolvers are.
    static func problems<C>(among destinations: [UndoRestoreDestination], eventCalendars: [C], reminderLists: [C],
                            identifier: (C) -> String, allowsModifications: (C) -> Bool) -> [UndoRestoreFinding] {
        destinations.compactMap { destination in
            let container: C?
            switch destination {
            case .eventCalendar(let snapshot):
                container = try? snapshot.resolveCalendar(in: eventCalendars, identifier: identifier, for: .recreateDeleted)
            case .reminderList(let snapshot):
                container = try? snapshot.resolveList(in: reminderLists, identifier: identifier, for: .recreateDeleted)
            }
            guard let container else { return UndoRestoreFinding(destination: destination, problem: .missing) }
            return allowsModifications(container) ? nil : UndoRestoreFinding(destination: destination, problem: .readOnly)
        }
    }

    /// The batch pre-check (#248 B): `read` gives the calendars and lists, read once for the whole
    /// batch. A refusal writes nothing, so it would not make the store refresh, and a list missing
    /// only from a stale view would be refused on every retry; so when a destination is missing or
    /// read-only, `invalidate` marks the view stale and `read` runs once more before the refusal
    /// (PR #282 round 2, finding 2). Read-only too, since a shared calendar's or list's write access
    /// can change elsewhere (round 3, finding 1). The refresh is requested, not awaited (EventKit
    /// syncs in the background), so the second read may still see the old view; every refused call
    /// requests one again, so a retry may see what this call did not (round 3, findings 10 and 20).
    /// Closure seam, so the order is unit-tested without EventKit.
    ///
    /// #476: runs on the caller's actor (`isolation`, SE-0420), so `identifier`,
    /// `allowsModifications` (which read its `EKCalendar`s) and `invalidate` (which writes its
    /// refresh state) run there after each read; as a nonisolated async function it resumed off
    /// the actor (Swift 5 mode, SE-0338).
    static func verify<C>(_ destinations: [UndoRestoreDestination], identifier: (C) -> String,
                          allowsModifications: (C) -> Bool,
                          read: () async throws -> (eventCalendars: [C], reminderLists: [C]),
                          invalidate: () -> Void,
                          isolation: isolated (any Actor)? = #isolation) async throws {
        guard !destinations.isEmpty else { return }
        func check(_ lists: (eventCalendars: [C], reminderLists: [C])) -> [UndoRestoreFinding] {
            problems(among: destinations, eventCalendars: lists.eventCalendars, reminderLists: lists.reminderLists,
                     identifier: identifier, allowsModifications: allowsModifications)
        }
        var findings = check(try await read())
        if !findings.isEmpty {
            invalidate()
            findings = check(try await read())
        }
        if !findings.isEmpty { throw UndoRestoreDestinationMissingError(findings: findings, total: destinations.count) }
    }

    /// The words and the recorded container of the item, for the refusal. No container title and
    /// no account: the refusal is a trusted message beside the discard_id directive, and a shared
    /// or subscribed calendar's title is set remotely, an account's name is often an e-mail
    /// address (#37; PR #282 round 5, finding 8). The identifier only groups the items.
    fileprivate var refusalTerms: (item: String, container: String, containerID: String) {
        switch self {
        case .eventCalendar(let snapshot):
            return ("event", "calendar", snapshot.calendarIdentifier)
        case .reminderList(let snapshot):
            return ("reminder", "list", snapshot.calendarIdentifier)
        }
    }
}

/// Why a destination cannot take its item back.
enum UndoRestoreProblem: Equatable, Sendable {
    case missing
    case readOnly
}

/// One destination the pre-check refuses, and why.
struct UndoRestoreFinding {
    let destination: UndoRestoreDestination
    let problem: UndoRestoreProblem
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
        case .deleteOccurrence(let snapshot, _):
            // #244: recreated as a one-off event in the occurrence's recorded calendar.
            return .eventCalendar(snapshot)
        case .deleteReminder(let snapshot):
            return .reminderList(snapshot)
        case .moveByCopy(let original, _, _, _, _):
            // #466: the source is recreated in its recorded calendar. No batch records this kind.
            return .eventCalendar(original)
        case .deleteFollowingOccurrences:
            // #244: never restored; its refusal (`batchMemberUndoRefusal`) runs before this check.
            return nil
        case .createEvent, .updateEvent, .updateRecurringEvent, .moveEvent, .createReminder, .updateReminder,
             .completeReminder, .completeRecurringReminder, .batch:
            return nil
        }
    }
}

/// B: some members of a batch cannot be restored, because the calendar or list each would be
/// recreated in is not there or does not allow changes. Raised by the batch pre-check, so nothing of
/// the batch was written; kept like a not-found (`UndoFailureDisposition.of` maps it to
/// `.restore`), since the calendar may only be syncing or its access may change. The message says
/// how many of the batch's items have their calendar or list in place and describes, without
/// naming them, the calendars or lists that stop the rest (round 5, finding 8), and that discard_id drops every item of the entry (PR #282 round 2, finding 1): this
/// check refuses the whole batch; a partial restore that keeps a narrowed record is #287. An item
/// whose calendar or list is in place can still fail at its own save, after the check (round 3,
/// finding 7).
///
/// The counts are of the members that recreate an item (`UndoRestoreDestination.of`, so `total` is
/// `destinations.count`). Every member of a recorded batch is one: batches hold delete records
/// only, and the #244 marker, which has no destination, is refused before this check (round 3,
/// finding 12).
///
/// The message is author-controlled text: the item and container words come from this file; the
/// only store-derived text is the titles of the batch's deleted items, which a shared calendar's
/// sharer may have set, shown through `undoShownTitle` and capped; no calendar or list title and
/// no account name is included (#37 F1, round 5, finding 8). That is the condition under which
/// this type conforms to `TrustedErrorMessage`.
struct UndoRestoreDestinationMissingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    /// How many containers and item titles the message names before it summarizes the rest.
    private static let containersShown = 5
    private static let itemsShown = 3

    init(findings: [UndoRestoreFinding], total: Int) {
        // One line per container and problem, in the order the batch first meets them. A container
        // is described, not named (finding 8): "2 events in a calendar that is not available".
        var groups: [(key: String, words: String, item: String, titles: [String])] = []
        for finding in findings {
            let d = finding.destination.refusalTerms
            let state = finding.problem == .missing ? "is not available" : "is read-only"
            let key = "\(d.container)|\(d.containerID)|\(state)"
            let words = "in a \(d.container) that \(state)"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].titles.append(finding.destination.itemTitle)
            } else {
                groups.append((key, words, d.item, [finding.destination.itemTitle]))
            }
        }
        let lines = groups.prefix(Self.containersShown).map { group -> String in
            let shown = group.titles.prefix(Self.itemsShown).map { "'\(undoShownTitle($0))'" }.joined(separator: ", ")
            let more = group.titles.count > Self.itemsShown ? ", …" : ""
            let noun = group.titles.count == 1 ? group.item : group.item + "s"
            return "\(group.titles.count) \(noun) \(group.words): \(shown)\(more)"
        }
        let moreGroups = groups.count > Self.containersShown
            ? "; and items in \(groups.count - Self.containersShown) more calendars or lists" : ""
        let blocked = findings.count
        let others = total - blocked
        let inPlace = others == 1 ? "The other item's calendar or list is in place" : "The other \(others) items' calendars or lists are in place"
        let restorable = others > 0
            ? " \(inPlace), but this check refuses the whole batch when any item's calendar or list is missing or read-only."
            : ""
        let count = total == 1 ? "its 1 deleted item cannot" : "\(blocked) of its \(total) deleted items cannot"
        message = "Cannot undo this batch: \(count) be restored: "
            + lines.joined(separator: "; ") + moreGroups + "."
            + restorable
            + " Nothing was written and this history entry was kept, whole, under the same id."
            + " Giving up this undo with discard_id drops " + (total == 1 ? "the 1 item" : "all \(total) items") + " of this entry"
            + (others == 1 ? ", including the 1 whose calendar or list is in place," : "")
            + (others > 1 ? ", including the \(others) whose calendars or lists are in place," : "")
            + " and cannot be reversed: ask the user first; if they agree, read undo_history and call undo with discard_id set to its id."
            + " A calendar or list that was deleted, or whose account was removed, does not come back, so retrying cannot restore its items; run undo again only if it may still be syncing or its access may change."
    }
}

extension UndoRestoreDestinationMissingError: TrustedErrorMessage {}

/// A: a batch undo stopped before its end, after `restoredCount` members were written (possibly
/// none). `handleUndo` puts back a record of `remaining` only, under the same id and timestamp
/// (`CalendarUndoManager.restoreFailedUndo(_:remaining:)`), so the next undo does not recreate the
/// restored members a second time. Where the failing member goes is `failing`.
///
/// The message is author-controlled text plus `memberError`, which is either a sanitized code or
/// the verbatim message of a `TrustedErrorMessage` (`EventKitErrorSanitizer.writeFailureLog`), and
/// the recorded titles of items (the failed one, the restored ones whose store differs), shown
/// through `undoShownTitle`, and the failed one's recorded start or due date formatted by this
/// server (digits, separators and an offset; #407). That is the condition under which this type
/// conforms to `TrustedErrorMessage`.
struct UndoBatchPartiallyUndoneError: LocalizedError, Sendable {
    /// Where the member whose write failed is in `remaining`.
    enum FailingMember: Sendable {
        /// First in record order, so it runs last next time and the members never attempted get
        /// their turn (every member may run last, `UndoOperation.mayRunLastAfterAFailure`).
        case runsLast
        /// In its recorded place, so it runs first again: a member left may not run last. No batch
        /// recorded today holds one (PR #282 round 4, finding 2).
        case inRecordedOrder
        /// Not kept: its error is permanent (`UnrecoverableUndoError`), so no retry restores it.
        case dropped
    }

    /// The members not yet restored, in record order (undo runs them in reverse). Empty when the
    /// last member was dropped: `handleUndo` then discards the record.
    let remaining: [UndoOperation]
    let restoredCount: Int
    /// The members restored before the failure, nested ones included, passed up by a nested batch.
    /// No text is built from them: since #323 what they did is named from `restoredEvents`, and what
    /// their stores hold differently from `restoredDiffering`.
    let restored: [UndoOperation]
    /// What the stores of those members hold differently (a recreated reminder whose save threw
    /// but which a new store finds with compared fields differing, #261), named here once: the
    /// batch text of the retry covers only `remaining` (PR #278 round 3; PR #282 round 5, finding 1).
    let restoredDiffering: [UndoRestoredDifference]
    /// What those members' undos did (#323), named here once, from the outcomes, not the records.
    let restoredEvents: [UndoEventOutcome]
    let memberError: String
    let failing: FailingMember
    let message: String
    var errorDescription: String? { message }

    /// `failingTitle`: the recorded title of the member that failed (nil for a nested batch's
    /// remainder), shown through `undoShownTitle`. `failedBeforeWrite`: its error is one the restore
    /// raises before it writes anything (`UndoOperation.failsBeforeAnyWrite`), so no second copy can
    /// come of it (PR #390 round 1). `failingWhen`: what tells it apart from another member of the
    /// same title (`UndoOperation.restoredItemWhen`, #407), or nil.
    init(remaining: [UndoOperation], restoredCount: Int, memberError: String, failing: FailingMember = .runsLast,
         restored: [UndoOperation] = [], restoredDiffering: [UndoRestoredDifference] = [],
         restoredEvents: [UndoEventOutcome] = [],
         failingTitle: String? = nil, failingWhen: String? = nil, failedBeforeWrite: Bool = false) {
        self.remaining = remaining
        self.restoredCount = restoredCount
        self.restored = restored
        self.restoredDiffering = restoredDiffering
        self.restoredEvents = restoredEvents
        self.memberError = memberError
        self.failing = failing
        let restoredText = restoredCount == 1 ? "1 item was" : "\(restoredCount) items were"
        let what: String
        switch failing {
        case .dropped where remaining.isEmpty:
            what = "Undo of this batch stopped part-way: \(restoredText) restored, then one item cannot be restored by any retry; its own error, which names it, follows. Nothing else was left to restore, so this history entry was discarded and earlier operations remain undoable."
        case .dropped:
            let kept = remaining.count == 1 ? "the 1 item never attempted" : "the \(remaining.count) items never attempted"
            let start = restoredCount == 0 ? "Undo of this batch stopped with no item confirmed restored:" : "Undo of this batch stopped part-way: \(restoredText) restored, then"
            what = "\(start) one item cannot be restored by any retry and was dropped from this history entry; its own error, which names it, follows. The entry was kept with only \(kept), under the same id, so running undo again restores those and not the others a second time."
        case .runsLast where restoredCount == 0 && remaining.count == 1:
            // #292 items 2b, 3: the only member left (a nested batch's remainder counts as one), so
            // there is no other item to try first.
            what = "Undo of this batch stopped with no item confirmed restored: restoring what is left of it failed. This history entry was kept, under the same id, so running undo again tries it again, unless its calendar or list is now missing or read-only: then the next undo refuses it before it writes anything."
        case .runsLast where restoredCount == 0:
            let others = remaining.count - 1
            what = "Undo of this batch stopped with no item confirmed restored: restoring one item failed. This history entry was kept, under the same id, with that item moved to the end, so running undo again tries the other \(others == 1 ? "item" : "\(others) items") first, unless its calendar or list is now missing or read-only: then the next undo refuses the whole batch before it writes anything."
        case .runsLast where remaining.count == 1:
            what = "Undo of this batch stopped part-way: \(restoredText) restored, then restoring the last one failed. This history entry was kept with only the item that failed, under the same id, so running undo again tries that item and does not restore the restored ones a second time, unless its calendar or list is now missing or read-only: then the next undo refuses it before it writes anything."
        case .runsLast:
            what = "Undo of this batch stopped part-way: \(restoredText) restored, then restoring the next one failed. This history entry was kept with only the \(remaining.count) items not yet restored, under the same id, and the item that failed comes last, so running undo again does not restore the restored ones a second time and tries the item that failed after the others, unless its calendar or list is now missing or read-only: then the next undo refuses the whole batch before it writes anything."
        case .inRecordedOrder where restoredCount == 0:
            // #292 item 2a: nothing restored, so nothing to leave out of the entry.
            what = "Undo of this batch stopped with no item confirmed restored: restoring one item failed. This history entry was kept, under the same id, in its recorded order, so running undo again tries the item that failed first."
        case .inRecordedOrder:
            let left = remaining.count == 1 ? "the item that failed" : "the \(remaining.count) items not yet restored"
            what = "Undo of this batch stopped part-way: \(restoredText) restored, then restoring the next one failed. This history entry was kept with only \(left), under the same id, in their recorded order, so running undo again tries the item that failed first and does not restore the restored ones a second time."
        }
        let loss = (UndoOperation.batchLossNote(events: restoredEvents).map { " For the items restored: \($0)." } ?? "")
            + UndoRestoredDifference.sentences(restoredDiffering)
        let giveUp: String
        switch failing {
        case .dropped where remaining.isEmpty:
            giveUp = ""
        case .dropped:
            giveUp = " To give up the rest of this undo, ask the user; if they agree, read undo_history and call undo with discard_id set to its id."
        case .runsLast, .inRecordedOrder:
            let item = failingTitle.map { "'\(undoShownTitle($0))'" + (failingWhen.map { " (\($0))" } ?? "") }
            let written: String
            if failedBeforeWrite {
                written = " \(item ?? "The item that failed") failed before anything of it was written (its calendar or list was not found), so running undo again does not add a copy of it."
            } else {
                // PR #390 round 2: no cause named, so the sentence holds for every failure after the
                // restore began (a save the store took, a reminder left pending, a series restore
                // rolled back, #285).
                written = " \(item.map { "The restore of \($0)" } ?? "Its restore") may have left something written, so running undo again can add a second copy: check first."
            }
            giveUp = written + " If that item keeps failing, or the next undo is refused for its calendar or list, ask the user whether to give up the rest of this undo; if they agree, read undo_history and call undo with discard_id set to its id."
                + (remaining.count > 1 ? " That drops every item not yet restored, not only the one that failed." : "")
        }
        message = what + loss + giveUp + " The failed item's own error follows; what it says about this history entry is superseded by this message: \(memberError)"
    }
}

extension UndoBatchPartiallyUndoneError: TrustedErrorMessage {}

extension UndoOperation {
    /// A: the error a batch undo reports when a write failed. `members` are in record order; the
    /// undo ran them in reverse, so the `interrupted.completed` members written are the last ones,
    /// and the members never attempted are the ones before the failing member.
    ///
    /// - A permanent member error (`UnrecoverableUndoError`): that member is dropped and the members
    ///   never attempted are kept, whether or not something was written first (PR #282 round 2,
    ///   findings 8, 9, 12, 17). With none waiting and nothing written, the member error stands and
    ///   discards the record; with none waiting after writes, the partial error has nothing left and
    ///   `handleUndo` discards the record, the error still saying what was restored.
    /// - Otherwise, when every member left may run last (`mayRunLastAfterAFailure`: every kind a
    ///   batch records, PR #282 round 3, finding 5, and round 4, finding 2), the failing member is
    ///   kept first, so it runs last next time and the members never attempted get their turn even
    ///   when it keeps failing. When one may not (no batch records such a kind today), the recorded
    ///   order is kept and the failing member runs first again.
    /// - When no member was restored and the record would not change (no other member waits, or the
    ///   order is kept), the record is put back whole too, through the same partial error: the
    ///   failing member may still have been written, so its text asks to check first, and the
    ///   member's own error follows it (#292 item 3; the member error used to stand alone, and it
    ///   does not say this).
    ///
    /// Every partial error carries the members this call restored, so what they did not carry over
    /// is named once (PR #278 round 3).
    ///
    /// A failing member that is itself a batch stopped part-way is replaced by its own remainder (no
    /// nested batch is recorded today). `describe` gives the member error for the message; it is
    /// called for every partial error, and not when the member error stands alone (a permanent one
    /// with nothing restored and nothing waiting).
    static func batchUndoFailure(members: [UndoOperation], interrupted: UndoBatchRunner.Interrupted,
                                 differing: [UndoRestoredDifference] = [], events: [UndoEventOutcome] = [],
                                 describe: (Error) -> String) -> Error {
        let failedIndex = members.count - 1 - interrupted.completed
        guard members.indices.contains(failedIndex) else { return interrupted.underlying }
        let inner = interrupted.underlying as? UndoBatchPartiallyUndoneError
        let unattempted = Array(members[..<failedIndex])
        let restored = interrupted.completed + (inner?.restoredCount ?? 0)
        // The members this call restored (the last `completed` in record order), nested ones too.
        let restoredMembers = Array(members[(failedIndex + 1)...]) + (inner?.restored ?? [])
        // What those members' stores hold differently, nested ones too.
        let restoredDiffering = differing + (inner?.restoredDiffering ?? [])
        // What those members' undos did (#323), nested ones too.
        let restoredEvents = events + (inner?.restoredEvents ?? [])
        // Every branch reports the restored members and their differences the same way (PR #282
        // round 6, finding 18: two branches used to pass them on separately, and dropping them
        // there went unnoticed).
        // The failed member's title, and whether its error came before any write (PR #390 round 1);
        // a nested batch's remainder has neither.
        let failingTitle = inner == nil ? members[failedIndex].restoredItemTitle : nil
        // #407: its start or due date, when another member of this record shares its title.
        let failingWhen = failingTitle.flatMap { title in
            restoredItemTitles(of: members).filter { $0 == title }.count > 1 ? members[failedIndex].restoredItemWhen : nil
        }
        let failedBeforeWrite = inner == nil && failsBeforeAnyWrite(interrupted.underlying)
        func partial(_ remaining: [UndoOperation], _ failing: UndoBatchPartiallyUndoneError.FailingMember,
                     _ memberError: String) -> UndoBatchPartiallyUndoneError {
            UndoBatchPartiallyUndoneError(remaining: remaining, restoredCount: restored, memberError: memberError,
                                          failing: failing, restored: restoredMembers, restoredDiffering: restoredDiffering,
                                          restoredEvents: restoredEvents,
                                          failingTitle: failingTitle, failingWhen: failingWhen, failedBeforeWrite: failedBeforeWrite)
        }
        if inner == nil, interrupted.underlying is UnrecoverableUndoError {
            guard !unattempted.isEmpty || restored > 0 else { return interrupted.underlying }
            return partial(unattempted, .dropped, describe(interrupted.underlying))
        }
        let failing: UndoOperation = inner.map { .batch($0.remaining) } ?? members[failedIndex]
        let runsLast = ([failing] + unattempted).allSatisfy(\.mayRunLastAfterAFailure)
        let memberError = inner?.memberError ?? describe(interrupted.underlying)
        return runsLast
            ? partial([failing] + unattempted, .runsLast, memberError)
            : partial(unattempted + [failing], .inRecordedOrder, memberError)
    }

    /// PR #390 round 1: the "calendar or list not found" errors a member's restore raises before it
    /// writes anything, so its failure cannot have left a copy: its calendar (`calendarNotFound`,
    /// `calendarNotFoundWithSource`, #269's `undoCalendarMissing`) or its reminder list
    /// (`undoListMissing`). A closed list, and only these: the text says the calendar or list was not
    /// found. Other errors that also write nothing (an access-gate refusal, `ListDeletedDuringSave`)
    /// are deliberately not listed, since that sentence would misname their cause; they get the
    /// check-first text, which is cautious, not wrong.
    static func failsBeforeAnyWrite(_ error: Error) -> Bool {
        guard let error = error as? EventKitError else { return false }
        switch error {
        case .calendarNotFound, .calendarNotFoundWithSource, .undoCalendarMissing, .undoListMissing: return true
        default: return false
        }
    }

    /// The recorded title of the item a batch member restores (nil for a nested batch and for the
    /// kinds no batch records), for the partial error. Exhaustive (#196 convention).
    var restoredItemTitle: String? {
        switch self {
        case .deleteEvent(let snapshot): return snapshot.title
        case .moveByCopy(let original, _, _, _, _): return original.title
        case .deleteOccurrence(let snapshot, _): return snapshot.title
        case .deleteReminder(let snapshot): return snapshot.title
        case .deleteFollowingOccurrences, .batch, .createEvent, .updateEvent, .updateRecurringEvent, .moveEvent,
             .createReminder, .updateReminder, .completeReminder, .completeRecurringReminder:
            return nil
        }
    }

    /// #407: what tells this member apart from another of the same title in a batch: the recorded
    /// start of an event or occurrence (an all-day one by its day, in this Mac's zone as all-day
    /// dates are, #364; a timed one with its offset, in the event's own zone), or a reminder's
    /// recorded due date (a date, or a date and time, as recorded). Nil for a reminder without a
    /// due date and for every other kind. Only digits, separators and an offset: no calendar,
    /// list or account name (#37).
    var restoredItemWhen: String? {
        switch self {
        case .deleteEvent(let snapshot), .deleteOccurrence(let snapshot, _), .moveByCopy(let snapshot, _, _, _, _):
            let format = snapshot.isAllDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            let zone = snapshot.isAllDay ? TimeZone.current : (snapshot.timeZone ?? TimeZone.current)
            return "starting " + DateFormatter.machineReadable(format, zone: zone).string(from: snapshot.startDate)
        case .deleteReminder(let snapshot):
            guard let due = snapshot.dueDateComponents, let year = due.year, let month = due.month, let day = due.day else { return nil }
            var text = String(format: "%04d-%02d-%02d", year, month, day)
            if let hour = due.hour { text += String(format: "T%02d:%02d", hour, due.minute ?? 0) }
            return "due " + text
        case .deleteFollowingOccurrences, .batch, .createEvent, .updateEvent, .updateRecurringEvent, .moveEvent,
             .createReminder, .updateReminder, .completeReminder, .completeRecurringReminder:
            return nil
        }
    }

    /// The recorded titles of `members`' restorable items, nested batches included (#407).
    static func restoredItemTitles(of members: [UndoOperation]) -> [String] {
        members.flatMap { member -> [String] in
            if case .batch(let inner) = member { return restoredItemTitles(of: inner) }
            return member.restoredItemTitle.map { [$0] } ?? []
        }
    }

    /// Whether a batch undo may move this member to run last when its write fails (#248 A). True for
    /// every kind a batch record holds (PR #282 round 4, finding 2; the builders are pinned by
    /// `UndoBatchWiringTests.testBatchRecordsAreBuiltOnlyFromDeletes`): a whole event, an occurrence
    /// or a reminder restore writes one new item and reads no other member's result, and the #244
    /// marker never runs (its refusal comes first). The duplicate guard (#285) only covers an occurrence
    /// record (`.deleteOccurrence`); a series delete addressed by an edited occurrence's own id
    /// can sit beside its series in one batch, which restores the occurrence twice from the rules
    /// alone (tracked in #321). False for the kinds no batch records: two
    /// of them can write to one item, where the order matters. Exhaustive, so a new record kind
    /// has to be classified to compile (#196 convention).
    var mayRunLastAfterAFailure: Bool {
        switch self {
        case .deleteEvent, .deleteOccurrence, .deleteReminder, .deleteFollowingOccurrences:
            return true
        case .batch(let members):
            return members.allSatisfy(\.mayRunLastAfterAFailure)
        case .createEvent, .updateEvent, .updateRecurringEvent, .moveEvent, .createReminder, .updateReminder,
             .completeReminder, .completeRecurringReminder:
            return false
        case .moveByCopy:
            // #466: it removes an existing item (the copy) as well as recreating one. No batch records it.
            return false
        }
    }
}

/// #248 A: the one way a batch record runs, for undo and redo alike, so no caller of
/// `UndoBatchRunner.run` can let `Interrupted` reach `handleUndo`, which would put the whole record
/// back after some members were written. `UndoBatchWiringTests` checks it is the runner's only caller.
enum UndoBatchExecution {
    /// Undo runs the members in reverse record order and reports a failed write through
    /// `UndoOperation.batchUndoFailure`. Redo runs them in record order and reports the member error
    /// as it is: no batch whose members write on redo is recorded (#247).
    ///
    /// #482: runs on the caller's actor (`isolation`, SE-0420), as #476's restore seams do. In
    /// Swift 5 mode (SE-0338) a nonisolated async function resumes on the generic executor after
    /// an await, so `describe`, a synchronous closure the caller forms on its actor, ran off it
    /// (nothing raced: both production closures call only the static `EventKitErrorSanitizer`).
    /// The callers in `EventKitManager` pass nothing, so `#isolation` gives them the actor; `nil`
    /// passed by hand brings the old behavior back. `UndoBatchRunner.run` calls no synchronous
    /// closure, so it takes none.
    static func run(_ members: [UndoOperation], verb: UndoHistoryVerb,
                    check: (UndoOperation) async throws -> Void,
                    execute: (UndoOperation) async throws -> String,
                    describe: (Error) -> String,
                    isolation: isolated (any Actor)? = #isolation) async throws -> [String] {
        try await run(members, verb: verb, check: check,
                      restore: { UndoMemberOutcome(text: try await execute($0), differing: []) },
                      describe: describe, isolation: isolation).texts
    }

    /// The same, for members whose restore returns what its store holds differently (a recreated
    /// reminder found with differing fields, #261; PR #282 round 5, finding 1), as data. Those of
    /// the members written are returned, in the order they ran; when a write fails, they go into
    /// the partial error instead, named once. What the event members did (`UndoEventOutcome`,
    /// #323) travels the same way. No member text is read back. Runs on the caller's actor, as
    /// the overload above does (#482).
    static func run(_ members: [UndoOperation], verb: UndoHistoryVerb,
                    check: (UndoOperation) async throws -> Void,
                    restore: (UndoOperation) async throws -> UndoMemberOutcome,
                    describe: (Error) -> String,
                    isolation: isolated (any Actor)? = #isolation) async throws
        -> (texts: [String], differing: [UndoRestoredDifference], events: [UndoEventOutcome]) {
        var differing: [UndoRestoredDifference] = []
        var events: [UndoEventOutcome] = []
        do {
            let texts = try await UndoBatchRunner.run(verb == .undo ? Array(members.reversed()) : members, check: check,
                                                      execute: { member in
                                                          let outcome = try await restore(member)
                                                          differing.append(contentsOf: outcome.differing)
                                                          events.append(contentsOf: outcome.events)
                                                          return outcome.text
                                                      })
            return (texts, differing, events)
        } catch let interrupted as UndoBatchRunner.Interrupted {
            switch verb {
            case .undo: throw UndoOperation.batchUndoFailure(members: members, interrupted: interrupted, differing: differing,
                                                             events: events, describe: describe)
            case .redo: throw interrupted.underlying
            }
        }
    }
}

/// What one member's restore returned: its text, and what the stores of the reminders it recreated
/// hold differently (one for a reminder, any number for a nested batch, none otherwise), which the
/// batch answer has to carry because the member texts are not shown (#261), and what the deleted
/// events and occurrences it restored did (#323).
struct UndoMemberOutcome: Sendable {
    let text: String
    let differing: [UndoRestoredDifference]
    let events: [UndoEventOutcome]

    init(text: String, differing: [UndoRestoredDifference], events: [UndoEventOutcome] = []) {
        self.text = text
        self.differing = differing
        self.events = events
    }
}

/// A recreated reminder whose store holds compared fields differently (#261): its title, shown
/// (`undoShownTitle`), and the names (`NewObjectSave.differingFieldsNote` words them).
struct UndoRestoredDifference: Sendable, Equatable {
    let shownTitle: String
    let storeDiffers: [String]

    /// Takes the recorded title and shows it here, so no caller can hand `sentences` a raw one
    /// whose ASCII quote or line break could close or split an entry (PR #282 round 7, findings 9,
    /// 10).
    init(title: String, storeDiffers: [String]) {
        shownTitle = undoShownTitle(title)
        self.storeDiffers = storeDiffers
    }

    /// " Restored reminder '<title>' — <note>." for each difference that names fields, in the order
    /// the members ran, or "" when none does: the words are `NewObjectSave.differingFieldsNote`'s,
    /// the joining is this server's, so the batch text and a part-way error read alike (PR #282).
    /// Each entry pairs one member's title with its own names; the title is already shown, its
    /// ASCII quotes turned curly, so it cannot close the entry or open another.
    ///
    /// Capped like the refusal's titles (PR #282 round 6, findings 13, 16): the first
    /// `entriesShown`, then how many more, so a cleanup of many reminders cannot grow the text
    /// without bound beside the discard_id directive.
    static func sentences(_ differences: [UndoRestoredDifference]) -> String {
        let entries = differences.compactMap { difference in
            NewObjectSave.differingFieldsNote(difference.storeDiffers).map { " Restored reminder '\(difference.shownTitle)' — \($0)." }
        }
        let more = entries.count - entriesShown
        let rest = more == 1 ? " And 1 more restored reminder whose store holds some fields differently, not named here; check the reminders this batch restored."
            : more > 1 ? " And \(more) more restored reminders whose store holds some fields differently, not named here; check the reminders this batch restored." : ""
        return entries.prefix(entriesShown).joined() + rest
    }

    /// How many entries `sentences` names before it counts the rest.
    static let entriesShown = 5
}
