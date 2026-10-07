import EventKit
import Foundation

/// #244 — what a delete removed, and so what its undo record holds. The record used to be a
/// snapshot of the series whatever the delete removed, and undo recreated it as a new event: a
/// delete of one occurrence came back as a second series beside the surviving one (on device: 3
/// occurrences, delete one, 2, undo, 5). The record now says what was removed:
///
/// - the whole event: recreated, rules included, as before. For a series that is its rules only:
///   occurrences deleted or edited on their own earlier are not recorded, so an earlier-deleted one
///   comes back and an edited one comes back unedited (on device 2026-10-08; #285);
/// - one occurrence: recreated as a one-off event at its slot (maintainer decision D1, the #208
///   copy-out precedent). EventKit has no public way to put an occurrence back into its series;
/// - an occurrence and the following ones, unless that removed the whole series: a marker whose
///   undo is refused and discarded (D2, the #236/#262 precedent). Recreating them would add a
///   second series, and putting back the rule end is the store-dependent restore #236 round 4
///   rejected.
enum EventRemovalKind: String, Sendable, Hashable {
    case wholeEvent
    case occurrence
    case followingOccurrences

    /// `hadRules`, `isDetached` and `fromFirstOccurrence` are evidence from before the removal, about
    /// the event the identifier resolved to and the occurrence removed. A detached occurrence
    /// addressed by its own identifier has no rules of its own (`RecurringUpdateKind.of`), but span
    /// "future" on it removes the following occurrences of its series too (checked on iCloud,
    /// 2026-10-07), which its snapshot does not hold; it is refused.
    ///
    /// Span "future" on a series is whole only when both sides agree (verify round 1, findings
    /// 1/2/12/22): it started at the series' first occurrence, and after the removal the identifier
    /// no longer resolves (`seriesResolves`, asked only then). Anything else is refused, so a
    /// lookup that finds nothing for another reason, or a store that keeps the series resolvable,
    /// never turns into a second series. Span "future" from the last occurrence removes only that
    /// one, but nothing tells it apart from one with occurrences after it; it is refused too.
    static func of(hadRules: Bool, isDetached: Bool, span: EKSpan, fromFirstOccurrence: Bool,
                   seriesResolves: () -> Bool) -> EventRemovalKind {
        guard hadRules || isDetached else { return .wholeEvent }
        if span == .thisEvent { return .occurrence }
        guard hadRules, fromFirstOccurrence, !seriesResolves() else { return .followingOccurrences }
        return .wholeEvent
    }
}

/// What a delete may record, all taken before the removal: the event the identifier resolved to
/// (for a series, the series object, rules included), the removed occurrence without rules, and
/// the facts `EventRemovalKind.of` classifies by.
struct DeletedEventSnapshots {
    let series: EventSnapshot
    let occurrence: EventSnapshot
    /// What the occurrence restore does not carry over, in the move path's terms (#253):
    /// `absolute_alarms` when an absolute alarm moved to the occurrence's start.
    let occurrenceNotCarriedOver: [String]
    let hadRules: Bool
    let isDetached: Bool
    /// The removed occurrence is the series' first: its slot is the series object's. On iCloud the
    /// series object keeps its original first slot after that occurrence was deleted on its own
    /// (checked 2026-10-07), so the first remaining occurrence does not count as the first. Today
    /// that delete fails earlier, as "Event not found" (#284); a fix of #284 makes this path live
    /// and its premise has to be checked on device again. Both objects report the slot as
    /// `occurrenceDate` equal to `startDate` for a timed, an all-day and a New York series
    /// (checked 2026-10-08), and the delete from the first occurrence was recorded whole for each.
    let fromFirstOccurrence: Bool

    init(series: EKEvent, removed: EKEvent) {
        hadRules = series.hasRecurrenceRules
        isDetached = series.isDetached
        fromFirstOccurrence = UndoPostState.sameInstant(removed.occurrenceDate ?? removed.startDate,
                                                        series.occurrenceDate ?? series.startDate)
        self.series = EventSnapshot(from: series)
        // Verify round 1, finding 6: an occurrence of a series reads the series' absolute alarm
        // dates, which a later occurrence has passed; the #253 split rule puts them at its start.
        // That is the move path's rule since 2a40986 (#253 round 2, D2-b), not the series-start
        // shift it replaced (verify round 2, findings 7/15).
        // A one-off, or a detached occurrence by its own identifier, keeps its own (as a move does).
        let alarms = EventKitManager.copyOutAlarms(of: removed, isSplit: hadRules)
        occurrence = EventSnapshot(from: removed, includeRecurrence: false, alarms: alarms.alarms)
        occurrenceNotCarriedOver = alarms.notCarriedOver
    }

    /// Called after the removal; `seriesResolves` looks the identifier up again.
    func kind(span: EKSpan, seriesResolves: () -> Bool) -> EventRemovalKind {
        EventRemovalKind.of(hadRules: hadRules, isDetached: isDetached, span: span,
                            fromFirstOccurrence: fromFirstOccurrence, seriesResolves: seriesResolves)
    }

    func record(for kind: EventRemovalKind) -> UndoOperation {
        switch kind {
        case .wholeEvent: return .deleteEvent(snapshot: series)
        case .occurrence: return .deleteOccurrence(snapshot: occurrence, notCarriedOver: occurrenceNotCarriedOver)
        case .followingOccurrences: return .deleteFollowingOccurrences(title: series.title)
        }
    }
}

extension UndoOperation {
    /// Undo of the marker: permanent (`UnrecoverableUndoError`, the record is discarded so earlier
    /// operations stay undoable). The issue asked to keep the entry; the maintainer chose the
    /// discard (D2), because a kept entry would refuse every time and block the stack until
    /// `discard_id`. Author-controlled text; the store-derived title passes `undoShownTitle`.
    static func followingOccurrencesDeleteRefusal(title: String) -> UnrecoverableUndoError {
        UnrecoverableUndoError(message: "Cannot undo the delete of the recurring event '\(undoShownTitle(title))': it deleted an occurrence and the following occurrences of the series. Undo does not restore them, because EventKit cannot put occurrences back into a series, and recreating them would add a second series beside the one that is left. Nothing was written. This history entry was discarded so earlier operations remain undoable. If they should come back, restore them in Calendar (for example by moving the end of the series' repetition back).")
    }

    /// D3: a member that can never be restored refuses the whole batch before any member writes,
    /// in the batch pre-check (`verifyBatchMemberRestorable`). That is all it guarantees: a write
    /// that fails part way through is #248. Permanent, like the single refusal: kept, the batch
    /// would refuse every time. Nil for a member that can be restored.
    var batchMemberUndoRefusal: UnrecoverableUndoError? {
        switch self {
        case .deleteFollowingOccurrences(let title):
            return UnrecoverableUndoError(message: "Cannot undo this batch: it deleted an occurrence and the following occurrences of the recurring event '\(undoShownTitle(title))', which undo does not restore (EventKit cannot put occurrences back into a series). The undo was refused before any of the batch's events ran, so none of the batch's events were restored and nothing was written. This history entry was discarded so earlier operations remain undoable. If the deleted events should come back, restore them in Calendar.")
        case .batch(let members):
            return members.lazy.compactMap(\.batchMemberUndoRefusal).first
        default:
            return nil
        }
    }

    /// The text of a restored occurrence. Store-derived title through `undoVisibleTitle`, as the
    /// other "Undone:" texts; `notCarriedOver` names fields in the move path's terms.
    static func occurrenceRestoredMessage(title: String, newID: String, notCarriedOver: [String]) -> String {
        var message = "Undone: restored the deleted occurrence of '\(undoVisibleTitle(title))' as a one-off event (new ID: \(newID))"
        if notCarriedOver.contains("absolute_alarms") {
            message += ". Not carried over: absolute_alarms (an absolute-date alarm of the series is now an alarm at the occurrence's start)"
        }
        return message
    }

    /// The text of an undone batch (verify round 2, finding 5): the member texts are not shown, so
    /// what a restored occurrence did not carry over is named here, once.
    static func batchUndoneMessage(members: [UndoOperation], count: Int) -> String {
        var message = "Undone batch (\(count) operations)"
        if let note = batchLossNote(members: members) { message += ". " + note }
        return message
    }

    /// What the restored `members` did not carry over, or nil. Also named by a batch undo that
    /// stopped part-way, for the members it restored before the failure (#248 A,
    /// `UndoBatchPartiallyUndoneError`), so each restored member's loss is reported once.
    static func batchLossNote(members: [UndoOperation]) -> String? {
        members.contains(where: \.restoresWithoutAbsoluteAlarms)
            ? "Not carried over: absolute_alarms (an absolute-date alarm of a series is now an alarm at its restored occurrence's start)"
            : nil
    }

    private var restoresWithoutAbsoluteAlarms: Bool {
        switch self {
        case .deleteOccurrence(_, let notCarriedOver): return notCarriedOver.contains("absolute_alarms")
        case .batch(let members): return members.contains(where: \.restoresWithoutAbsoluteAlarms)
        default: return false
        }
    }
}

extension EventKitManager {
    /// The post-removal lookup of `EventRemovalKind.of`: marks the store stale first (verify round
    /// 1, finding 17), so the single and the batch delete read it the same way.
    func seriesResolves(identifier: String) -> Bool {
        markNeedsRefresh()
        return freshEvent(id: identifier) != nil
    }
}
