import EventKit
import Foundation

/// #244 — what a delete removed, and so what its undo record holds. The record used to be a
/// snapshot of the series whatever the delete removed, and undo recreated it as a new event: a
/// delete of one occurrence came back as a second series beside the surviving one (on device: 3
/// occurrences, delete one, 2, undo, 5). The record now says what was removed:
///
/// - the whole event: recreated, rules included. For a series, its exceptions inside the delete window (#319)
///   are recorded too and restored (#285): an occurrence deleted on its own earlier stays deleted,
///   one edited on its own comes back as a one-off event. A series whose exceptions could not be
///   listed, or whose record did not match the recreated series, comes back from its rules alone;
/// - one occurrence: recreated as a one-off event at its slot (maintainer decision D1, the #208
///   copy-out precedent). EventKit has no public way to put an occurrence back into its series;
/// - an occurrence and the following ones, unless that removed the whole series: a marker whose
///   undo is refused and discarded (D2, the #236/#262 precedent). Recreating them would add a
///   second series, and putting back the rule end is the store-dependent restore #236 round 4
///   rejected.
enum EventRemovalKind: String, Sendable, Hashable, CaseIterable {
    case wholeEvent
    case occurrence
    case followingOccurrences

    /// `hadRules`, `isDetached` and `fromFirstOccurrence` are evidence from before the removal, about
    /// the event the identifier resolved to and the occurrence removed. A detached occurrence
    /// addressed by its own identifier has no rules of its own (`RecurringUpdateKind.of`), but span
    /// "future" on it removes the following occurrences of its series too (checked on iCloud,
    /// 2026-10-07), which its snapshot does not hold; it is refused.
    ///
    /// Span "future" on a series is whole only when it started at the series' first occurrence and,
    /// after the removal, the identifier no longer resolves (verify round 1, findings 1/2/12/22;
    /// `seriesResolves`, asked only then). Anything else is refused, so a store that keeps the
    /// series resolvable never turns into a second series. The start at the first occurrence is the
    /// only evidence: the lookup cannot tell a series that is gone from one it failed to find
    /// (verify round 4, finding 16; round 5, findings 3/14; round 6, finding 11), and only a delete
    /// from the first occurrence, which removes the whole series, reaches it. Span "future" from
    /// the last occurrence removes only that one, but nothing tells it apart from one with
    /// occurrences after it; it is refused too.
    static func of(hadRules: Bool, isDetached: Bool, span: EKSpan, fromFirstOccurrence: Bool,
                   seriesResolves: () -> Bool) -> EventRemovalKind {
        guard hadRules || isDetached else { return .wholeEvent }
        if span == .thisEvent { return .occurrence }
        guard hadRules, fromFirstOccurrence, !seriesResolves() else { return .followingOccurrences }
        return .wholeEvent
    }

    /// #288: a lookup that failed says nothing about the series, so it counts as still resolving:
    /// `of` then answers `.followingOccurrences`, and the undo cannot recreate a whole series that
    /// may still be there.
    static func seriesResolves(_ lookup: () throws -> Bool) -> Bool {
        (try? lookup()) ?? true
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
    /// (checked 2026-10-07), so the first remaining occurrence does not count as the first. Since
    /// #326 `freshEvent` hands such a series' first remaining occurrence in as `series`, so that
    /// occurrence now counts as the first and a span future delete from it is recorded whole (the
    /// remaining occurrences are all that is removed, and `seriesResolves` is false afterwards).
    /// That recorded undo was checked on device (#335, iCloud, 2026-11-01 and again 2026-11-05 in one
    /// stdio process): a weekly series of 5 with its first occurrence deleted, deleted through the
    /// stand-in with span future and with span all, came back on undo as a new series with the
    /// same 4 dates. Both objects report the slot as
    /// `occurrenceDate` equal to `startDate` for a timed, an all-day and a New York series
    /// (checked 2026-10-08), and the delete from the first occurrence was recorded whole for each.
    let fromFirstOccurrence: Bool

    /// `seriesExceptions` (#285) lists the series' exceptions; it runs, before anything is removed,
    /// only for a delete that can turn out to remove the whole series: span other than "this",
    /// started at the series' first occurrence, on a series with rules.
    init(series: EKEvent, removed: EKEvent, span: EKSpan = .thisEvent, seriesExceptions: (() -> SeriesExceptions?)? = nil) {
        hadRules = series.hasRecurrenceRules
        isDetached = series.isDetached
        fromFirstOccurrence = UndoPostState.sameInstant(removed.occurrenceDate ?? removed.startDate,
                                                        series.occurrenceDate ?? series.startDate)
        let exceptions = (hadRules && span != .thisEvent && fromFirstOccurrence) ? seriesExceptions?() : nil
        // #321: a series is recorded under its identifiers, so its undo can note what it recreated.
        self.series = EventSnapshot(from: series).withExceptions(exceptions)
            .withSeriesIdentity(hadRules ? OccurrenceOrigin.seriesIDs(of: series) : nil)
        // Verify round 1, finding 6: an occurrence of a series reads the series' absolute alarm
        // dates, which a later occurrence has passed; the #253 split rule puts them at its start.
        // That is the move path's rule since 2a40986 (#253 round 2, D2-b), not the series-start
        // shift it replaced (verify round 2, findings 7/15).
        // A one-off, or a detached occurrence by its own identifier, keeps its own (as a move does).
        let alarms = EventKitManager.copyOutAlarms(of: removed, isSplit: hadRules)
        // #321: the occurrence is tied to its series and rule slot, which its undo's guard compares.
        let removedSnapshot = EventSnapshot(from: removed, includeRecurrence: false, alarms: alarms.alarms)
        occurrence = hadRules || isDetached ? removedSnapshot.withOccurrenceOrigin(OccurrenceOrigin.of(removed)) : removedSnapshot
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

extension EventSnapshot {
    /// #322: the record of a whole-series delete by `deleteEventSeries` / `deleteEventSeriesBatch`
    /// (#185): the event's snapshot, rules included, carrying the series' exceptions (#285) when it
    /// has rules. `capture` runs only then, before the caller removes anything; a one-off is not
    /// listed. `delete_event` and `delete_events_batch` gate the same capture through
    /// `DeletedEventSnapshots` instead, because there the span and the occurrence decide.
    ///
    /// #321: a series carries its identifiers (`seriesIdentity`); an occurrence edited on its own,
    /// addressed by its own identifier (no rules of its own on iCloud), carries its origin, so its
    /// undo is guarded like an occurrence's (PR #318 round 3, finding 22).
    static func recordingSeriesDelete(of event: EKEvent, capture: () -> SeriesExceptions?) -> EventSnapshot {
        let snapshot = EventSnapshot(from: event).withExceptions(event.hasRecurrenceRules ? capture() : nil)
            .withSeriesIdentity(event.hasRecurrenceRules ? OccurrenceOrigin.seriesIDs(of: event) : nil)
        return !event.hasRecurrenceRules && event.isDetached ? snapshot.withOccurrenceOrigin(OccurrenceOrigin.of(event)) : snapshot
    }
}

extension OccurrenceOrigin {
    /// #321: the origin of `occurrence` as EventKit reads it (`of(eventIdentifier:...)`).
    static func of(_ occurrence: EKEvent) -> OccurrenceOrigin? {
        of(eventIdentifier: occurrence.eventIdentifier, externalIdentifier: occurrence.calendarItemExternalIdentifier,
           occurrenceDate: occurrence.occurrenceDate, isAllDay: occurrence.isAllDay, isDetached: occurrence.isDetached)
    }

    /// #321: the identifiers of the series `event` is, or belongs to (`seriesIDs(eventIdentifier:...)`).
    static func seriesIDs(of event: EKEvent) -> UndoPostState.OccurrenceIDs? {
        seriesIDs(eventIdentifier: event.eventIdentifier, externalIdentifier: event.calendarItemExternalIdentifier)
    }
}

extension UndoOperation {
    /// Undo of the marker: permanent (`UnrecoverableUndoError`, the record is discarded so earlier
    /// operations stay undoable). The issue asked to keep the entry; the maintainer chose the
    /// discard (D2), because a kept entry would refuse every time and block the stack until
    /// `discard_id`. Author-controlled text; the store-derived title passes `undoShownTitle`.
    static func followingOccurrencesDeleteRefusal(title: String) -> UnrecoverableUndoError {
        UnrecoverableUndoError(message: "Cannot undo the delete of the recurring event '\(undoShownTitle(title))': it deleted an occurrence and the following occurrences of the series (when it started at the first occurrence, every occurrence). Undo does not restore them, because EventKit cannot put occurrences back into a series, and recreating them would add a second series beside any part of it that is left. Nothing was written. This history entry was discarded so earlier operations remain undoable. If they should come back, restore them in Calendar (where part of the series is left, for example by moving the end of its repetition back).")
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
    /// other "Undone:" texts; `notCarriedOver` names fields in the move path's terms. When the
    /// series was deleted whole and recreated from its rules alone, the recreated series holds the
    /// slot and `seriesHoldsSlot` skips the write (#285, matched by series and rule slot since #321);
    /// where the series' exceptions were restored the slot is free and this writes the one-off,
    /// which is the right result.
    static func occurrenceRestoredMessage(title: String, newID: String, notCarriedOver: [String]) -> String {
        var message = "Undone: restored the deleted occurrence of '\(undoVisibleTitle(title))' as a one-off event (new ID: \(newID))"
        if notCarriedOver.contains("absolute_alarms") {
            message += ". Not carried over: absolute_alarms (an absolute-date alarm of the series is now an alarm at the occurrence's start)"
        }
        return message
    }

    /// #321: what the restored-occurrence text adds when its record does not say which series the
    /// occurrence belonged to (no identifier or slot was read when it was deleted), so it was not
    /// checked whether that series holds the slot again. The one-off is written then: a duplicate
    /// is visible and can be deleted, a success that wrote nothing is not.
    static let occurrenceSlotUncheckedNote = "The record does not say which series this occurrence belonged to, so it was not checked whether that series already holds its time again; if the series was restored, check Calendar for a second event at that time"

    /// #285: the undo of an occurrence delete found its slot already held by the recreated series
    /// and wrote nothing. Success: the occurrence is back, and a second copy would be wrong.
    /// PR #494 round 1: `edited`, the occurrence had been edited on its own before its delete. The
    /// series holds its slot as the rules give it, so its edit did not come back; the text says so
    /// rather than that the occurrence is restored.
    static func occurrenceAlreadyRestoredMessage(title: String, edited: Bool = false) -> String {
        if edited {
            return "Undone: nothing was written for the deleted occurrence of '\(undoVisibleTitle(title))': its restored series already holds that occurrence's slot (a one-off event beside it would have been a duplicate). The occurrence had been edited on its own before it was deleted, and the series holds it as its rules give it, so its own edit did not come back"
        }
        return "Undone: the deleted occurrence of '\(undoVisibleTitle(title))' is already restored by its series, so nothing was written (a one-off event beside it would have been a duplicate)"
    }

    /// Verify round 3, findings 3/7/9 (#285): a recurring event comes back from the rules in its
    /// snapshot (a whole-series delete: span "future" from the first occurrence, or span "all"),
    /// which hold no occurrence deleted or edited on its own before the delete. The undo text says
    /// so for every such restore, whether or not there were any, since nothing can tell (round 4,
    /// findings 8/9/12; the text no longer says that about itself, round 5, findings 4/6/11). It
    /// does not point at "this delete", which a batch text cannot, and says an edited occurrence
    /// loses its edit, in the words of the tool descriptions.
    static let seriesRulesRestoreNote = "Restored from the series rules alone, because its exceptions were not checked when it was deleted: an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit; undoing the earlier delete of that occurrence afterwards writes nothing when the restored series already holds its slot"

    /// What the `undo_history` line of a record that recreates a series from its rules adds
    /// (verify round 4, findings 11/15; round 5, findings 1/2/7): the line is read before the undo
    /// runs, and "from its rules alone" could be read as nothing coming back.
    static let seriesRulesListingNote = "occurrences deleted on their own earlier come back, edited ones without their edits"

    /// #285: the same for a series whose exceptions were recorded.
    static let seriesExceptionsListingNote = "occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events; not for a first occurrence edited or deleted on its own, one moved more than a year outside the window, or a record that does not match the recreated series"

    /// How many series this record's undo recreates from their rules, nested batches included, for
    /// the `undo_history` line of a batch (verify round 5, findings 1/2). Counted from the same
    /// exhaustive classification as the batch undo text, which treats a refused member as
    /// disclosing nothing; a batch holding one is listed by that refusal instead, since its undo
    /// writes nothing (round 6, findings 1/2/4).
    var seriesRecreatedFromRules: Int {
        undoDisclosures.filter { $0 == .seriesRules }.count
    }

    /// #285: how many series this record's undo recreates with their exceptions, nested batches included.
    var seriesRecreatedWithExceptions: Int {
        undoDisclosures.filter { $0 == .seriesExceptions }.count
    }

    /// The text of a recreated event. Store-derived title through `undoVisibleTitle`.
    static func eventRestoredMessage(snapshot: EventSnapshot, newID: String,
                                     exceptionsOutcome: SeriesExceptionsRestorer.Outcome? = nil) -> String {
        var message = "Undone: restored event '\(undoVisibleTitle(snapshot.title))' (new ID: \(newID))"
        guard snapshot.restoresFromRules else { return message }
        if let outcome = exceptionsOutcome {
            message += ". " + seriesExceptionsRestoredNote(outcome, exceptions: snapshot.exceptions)
        } else {
            message += ". " + seriesRulesRestoreNote
        }
        return message
    }

    /// #319: how the checked window is placed, in the words every text uses.
    static let seriesExceptionsWindowRule = "at most four years, from three years before the delete, or from one day before the first occurrence when that is later, moved earlier for a rule that ends sooner"

    /// #319: the window by its two instants, to the minute, in the host zone; the end is exclusive.
    /// PR #494 round 1: by instants, not days: the edges fall at the time of day of the delete or of
    /// the first occurrence, so a first or last day named alone was only partly checked.
    static func windowRange(_ window: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "from \(formatter.string(from: window.start)) up to \(formatter.string(from: window.end))"
    }

    /// #319: on which side(s) the series has, or may have, occurrences outside its window; nil when
    /// it has none.
    static func outsideWindowNote(_ exceptions: SeriesExceptions) -> String? {
        let before = exceptions.seriesStartsBeforeWindow
        switch (before, exceptions.seriesContinuesAfterWindow, exceptions.seriesMayContinueAfterWindow) {
        case (true, true, _): return "This series has occurrences outside that window, before and after it"
        case (false, true, _): return "This series has occurrences outside that window, after it"
        case (true, false, true): return "This series has occurrences before that window and may have occurrences after it"
        case (false, false, true): return "This series may have occurrences after that window"
        case (true, false, false): return "This series has occurrences outside that window, before it"
        case (false, false, false): return nil
        }
    }

    /// #285: what a restore that put the series' exceptions back says, with counts. The window
    /// limit is stated because an exception outside it was never listed. #319: by its days, with
    /// the side(s) on which the series has occurrences outside it, when the record holds them.
    static func seriesExceptionsRestoredNote(_ outcome: SeriesExceptionsRestorer.Outcome, exceptions: SeriesExceptions? = nil) -> String {
        if outcome.notApplied {
            return "Restored from the series rules alone: the recorded exceptions did not match the occurrences of the recreated series, so none was applied (an occurrence deleted on its own earlier comes back, one edited on its own comes back without its edit)"
        }
        let window = exceptions.map { "\(windowRange($0.window)); \(seriesExceptionsWindowRule)" } ?? seriesExceptionsWindowRule
        var note = "Restored from the series rules with its exceptions inside the checked window: \(outcome.stayedDeleted) occurrence(s) deleted on their own earlier stayed deleted, \(outcome.oneOffs) occurrence(s) edited on their own came back as separate one-off events that no longer belong to the series. Exceptions outside the checked window (\(window)) are not restored; those occurrences come back from the rules, and an occurrence edited on its own that was moved more than a year outside the window is neither restored nor listed, so its slot counts as deleted"
        if let outside = exceptions.flatMap(outsideWindowNote) { note += ". " + outside }
        if outcome.firstOccurrenceKeptFromRule {
            note += ". The series' first occurrence was edited or deleted on its own; it is kept from the rule and not restored as an exception, because removing it would remove the series' anchor"
        }
        return note
    }

    /// The text of an undone batch (verify round 2, finding 5; round 3, finding 3): the member texts
    /// are not shown, so what the members did is named here, once each, from the outcomes they
    /// returned (#323, `batchLossNote(events:)`), never from the records or the member text. A pure
    /// function of what it is given.
    static func batchUndoneMessage(count: Int, events: [UndoEventOutcome] = [], differing: [UndoRestoredDifference] = []) -> String {
        var message = "Undone batch (\(batchCount(count)))"
        if let note = batchLossNote(events: events) { message += ". " + note }
        // What the restored reminders' stores hold differently, from the names each member
        // returned, never from member text (#261; PR #282 round 5, finding 1).
        let named = UndoRestoredDifference.sentences(differing)
        return named.isEmpty ? message : message + "." + named
    }

    /// The text of a redone batch; no batch whose members write on redo is recorded today (#247).
    static func batchRedoneMessage(count: Int) -> String {
        "Redone batch (\(batchCount(count)))"
    }

    /// "1 operation", "N operations": a narrowed batch often holds one member (PR #282 round 5,
    /// findings 4, 12).
    private static func batchCount(_ count: Int) -> String {
        count == 1 ? "1 operation" : "\(count) operations"
    }

    /// No `absoluteAlarms` since #323: the `undo_history` lines never named it, and the batch
    /// texts that did now take it from the members' outcomes.
    private enum UndoDisclosure: Hashable { case seriesRules, seriesExceptions }

    /// What a record's undo will disclose, read before it runs: only the `undo_history` lines use
    /// it (`seriesRecreatedFromRules`, `seriesRecreatedWithExceptions`). The batch answer and a
    /// part-way error say what the members did, from their outcomes (#323, `batchLossNote(events:)`).
    /// Exhaustive, so a new record kind has to be classified here (verify round 3, finding 2).
    private var undoDisclosures: [UndoDisclosure] {
        switch self {
        case .deleteEvent(let snapshot):
            guard snapshot.restoresFromRules else { return [] }
            return snapshot.exceptions == nil ? [.seriesRules] : [.seriesExceptions]
        case .batch(let members):
            return members.flatMap(\.undoDisclosures)
        case .moveByCopy(let original, _, _, _, _):
            // #466: the source is restored as `.deleteEvent` or `.deleteOccurrence` restores it; its
            // snapshot holds no rules, so neither discloses anything.
            return UndoOperation.deleteEvent(snapshot: original).undoDisclosures
        case .createEvent, .deleteOccurrence, .deleteFollowingOccurrences, .updateEvent, .updateRecurringEvent, .moveEvent,
             .createReminder, .deleteReminder, .updateReminder, .completeReminder, .completeRecurringReminder,
             .calendarOperation:
            return []
        }
    }
}

extension EventSnapshot {
    /// A recreate writes these rules, so the event comes back as a series built from them.
    var restoresFromRules: Bool { !(recurrenceRules ?? []).isEmpty }
}

extension EventKitManager {
    /// The post-removal lookup of `EventRemovalKind.of`: marks the store stale first (verify round
    /// 1, finding 17), so the single and the batch delete read it the same way.
    func seriesResolves(identifier: String) -> Bool {
        markNeedsRefresh()
        return EventRemovalKind.seriesResolves { try freshEvent(id: identifier) != nil }
    }
}
