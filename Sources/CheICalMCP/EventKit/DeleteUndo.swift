import EventKit
import Foundation

/// #244 — what a delete removed, and so what its undo record holds. The record used to be a
/// snapshot of the series whatever the delete removed, and undo recreated it as a new event: a
/// delete of one occurrence came back as a second series beside the surviving one (on device: 3
/// occurrences, delete one, 2, undo, 5). The record now says what was removed:
///
/// - the whole event: recreated, rules included, as before;
/// - one occurrence: recreated as a one-off event at its slot (maintainer decision D1, the #208
///   copy-out precedent). EventKit has no public way to put an occurrence back into its series;
/// - an occurrence and the following ones of a series that is still there: a marker whose undo
///   is refused and discarded (D2, the #236/#262 precedent). Recreating them would add a second
///   series, and putting back the rule end is the store-dependent restore #236 round 4 rejected.
enum EventRemovalKind: String, Sendable, Hashable {
    case wholeEvent
    case occurrence
    case followingOccurrences

    /// Classified after the removal ran. `hadRules` and `isDetached` describe the event the
    /// identifier resolved to before the removal: a detached occurrence addressed by its own
    /// identifier has no rules of its own (`RecurringUpdateKind.of`), but span "future" on it
    /// removes the following occurrences of its series too, which its snapshot does not hold; it
    /// is refused whether the series remains or not. `seriesRemains` is whether the identifier
    /// still resolves after the removal; it matters only for span "future" on a series, where
    /// from the first occurrence nothing is left and the series is recreated whole.
    static func of(hadRules: Bool, isDetached: Bool, span: EKSpan, seriesRemains: Bool) -> EventRemovalKind {
        guard hadRules || isDetached else { return .wholeEvent }
        if span == .thisEvent { return .occurrence }
        if hadRules && !seriesRemains { return .wholeEvent }
        return .followingOccurrences
    }
}

/// The two snapshots a delete may record, both taken before the removal: the event the
/// identifier resolved to (for a series, its first occurrence, rules included) and the removed
/// occurrence without rules, as the #208 copy-out records it.
struct DeletedEventSnapshots {
    let series: EventSnapshot
    let occurrence: EventSnapshot

    init(series: EKEvent, removed: EKEvent) {
        self.series = EventSnapshot(from: series)
        self.occurrence = EventSnapshot(from: removed, includeRecurrence: false)
    }

    func record(for kind: EventRemovalKind) -> UndoOperation {
        switch kind {
        case .wholeEvent: return .deleteEvent(snapshot: series)
        case .occurrence: return .deleteOccurrence(snapshot: occurrence)
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

    /// D3: a batch undo is whole or nothing, so a member that cannot be restored refuses the whole
    /// batch before any member writes. Checked by the batch pre-check (`verifyHistoryTarget`).
    /// Permanent, like the single refusal: kept, the batch would refuse every time. Nil for a
    /// member that can be restored.
    var batchMemberUndoRefusal: UnrecoverableUndoError? {
        switch self {
        case .deleteFollowingOccurrences(let title):
            return UnrecoverableUndoError(message: "Cannot undo this batch: it deleted an occurrence and the following occurrences of the recurring event '\(undoShownTitle(title))', which undo does not restore (EventKit cannot put occurrences back into a series). A batch is undone whole or not at all, so none of the batch's events were restored and nothing was written. This history entry was discarded so earlier operations remain undoable. If the deleted events should come back, restore them in Calendar.")
        case .batch(let members):
            return members.lazy.compactMap(\.batchMemberUndoRefusal).first
        default:
            return nil
        }
    }
}

extension EventKitManager {
    /// The kind of the removal that just ran on the event under `identifier`. The identifier is
    /// looked up again (`freshEvent`, which refreshes the object) only for span "future" on a
    /// series. A stale read that still finds a removed series makes it a refused marker, never a
    /// duplicate.
    func removalKind(identifier: String, hadRules: Bool, isDetached: Bool, span: EKSpan) -> EventRemovalKind {
        let asksSeries = hadRules && span == .futureEvents
        return EventRemovalKind.of(hadRules: hadRules, isDetached: isDetached, span: span,
                                   seriesRemains: asksSeries && freshEvent(id: identifier) != nil)
    }
}
