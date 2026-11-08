import Foundation

/// #323: what the undo of one deleted event or occurrence did, as data. The two delete-undo arms
/// (`SeriesExceptionsUndo.undoDeleteEvent` / `undoDeleteOccurrence`) return it next to their text,
/// and a batch carries it up in `UndoMemberOutcome`, so the batch answer and a part-way error say
/// what the members did without reading member text back (the #261 rule). A one-off event that is
/// not part of a series has nothing to disclose and returns none.
enum UndoEventOutcome: Sendable, Equatable {
    /// A series recreated from its rules alone: its exceptions were not recorded (#278).
    case seriesFromRules
    /// A series recreated from its rules with its recorded exceptions (#285), and what that did.
    case seriesWithExceptions(SeriesExceptionsRestorer.Outcome)
    /// A deleted occurrence recreated as a one-off event, with the fields it did not carry over (#244).
    case occurrenceOneOff(notCarriedOver: [String])
    /// A deleted occurrence whose slot its series already held: nothing was written (#285).
    case occurrenceAlreadyHeld
    /// #321 r1: the same for an occurrence edited on its own before its delete: the series holds
    /// its slot as its rules give it, so the edit did not come back.
    case editedOccurrenceAlreadyHeld
}

extension UndoOperation {
    /// What the members of a batch undo did, from their outcomes (#323), or nil when there is
    /// nothing to say: sums, not a list per series, so the text stays short and needs no titles.
    /// Also used by a batch undo that stopped part-way, for the members it restored.
    static func batchLossNote(events: [UndoEventOutcome]) -> String? {
        var notes: [String] = []
        let alarmsMoved = events.contains {
            if case .occurrenceOneOff(let notCarriedOver) = $0 { return notCarriedOver.contains("absolute_alarms") }
            return false
        }
        if alarmsMoved {
            notes.append("Not carried over: absolute_alarms (an absolute-date alarm of a series is now an alarm at its restored occurrence's start)")
        }
        let editedHeld = events.filter { $0 == .editedOccurrenceAlreadyHeld }.count
        let held = events.filter { $0 == .occurrenceAlreadyHeld }.count + editedHeld
        if held > 0 {
            var note = held == 1
                ? "1 deleted occurrence was already restored by its series, so nothing was written for it"
                : "\(held) deleted occurrences were already restored by their series, so nothing was written for them"
            // PR #494 round 1: an edited one is held as the rules give it; its edit did not come back.
            if editedHeld > 0 {
                note += editedHeld == 1
                    ? "; 1 of them had been edited on its own, and its series holds it as its rules give it, so that edit did not come back"
                    : "; \(editedHeld) of them had been edited on their own, and their series hold them as their rules give them, so those edits did not come back"
            }
            notes.append(note)
        }
        let fromRules = events.filter { $0 == .seriesFromRules }.count
        if fromRules == 1 { notes.append(seriesRulesRestoreNote) }
        if fromRules > 1 {
            notes.append("\(fromRules) series were restored from their rules alone, because their exceptions were not checked when they were deleted: an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit; undoing the earlier delete of that occurrence afterwards writes nothing when the restored series already holds its slot")
        }
        let restores = events.compactMap { outcome -> SeriesExceptionsRestorer.Outcome? in
            if case .seriesWithExceptions(let restore) = outcome { return restore }
            return nil
        }
        let applied = restores.filter { !$0.notApplied }
        if !applied.isEmpty { notes.append(seriesExceptionsBatchNote(applied)) }
        let notApplied = restores.count - applied.count
        if notApplied > 0 {
            notes.append(notApplied == 1
                ? "1 series was restored from its rules alone: its recorded exceptions did not match the occurrences of the recreated series, so none was applied (an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit)"
                : "\(notApplied) series were restored from their rules alone: their recorded exceptions did not match the occurrences of the recreated series, so none was applied (an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit)")
        }
        return notes.isEmpty ? nil : notes.joined(separator: ". ")
    }

    /// #285, #323: the totals over the series whose exceptions were applied. The window limit is
    /// stated because an exception outside it was never listed.
    static func seriesExceptionsBatchNote(_ applied: [SeriesExceptionsRestorer.Outcome]) -> String {
        let series = applied.count == 1
            ? "1 series was restored from its rules with its exceptions"
            : "\(applied.count) series were restored from their rules with their exceptions"
        var note = "\(series) inside the checked window: \(applied.map(\.stayedDeleted).reduce(0, +)) occurrence(s) deleted on their own earlier stayed deleted, \(applied.map(\.oneOffs).reduce(0, +)) occurrence(s) edited on their own came back as separate one-off events that no longer belong to their series"
        let firstKept = applied.filter(\.firstOccurrenceKeptFromRule).count
        if firstKept > 0 {
            note += applied.count == 1
                ? ". The series' first occurrence was edited or deleted on its own; it is kept from the rule and not restored as an exception, because removing it would remove the series' anchor"
                : ". In \(firstKept) of them the first occurrence was edited or deleted on its own; it is kept from the rule and not restored as an exception, because removing it would remove the series' anchor"
        }
        note += ". Exceptions outside the checked window (\(seriesExceptionsWindowRule)) are not restored; those occurrences come back from the rules, and an occurrence edited on its own that was moved more than a year outside the window is neither restored nor listed, so its slot counts as deleted"
        return note
    }
}
