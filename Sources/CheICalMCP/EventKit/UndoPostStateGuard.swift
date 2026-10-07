import EventKit
import Foundation

/// #236 — the post-state guard. An undo record used to keep only the state *before* the write
/// (or just an identifier), so undo wrote over whatever was there, including a change made
/// elsewhere after the write. Each record now also keeps the state the write *left*, and before
/// an undo or redo writes, the item is compared with it (diagnosis D1). A field projection rather
/// than `lastModifiedDate`, because undoing a later write restores exactly the state an earlier
/// one left, which a modification stamp never matches again.
///
/// A field blocks the undo only when it changed since the write **and** the undo would change it
/// again: a field already back at the value the undo writes is not overwritten (PR #259 verify
/// #9). A delete (create-undo) has no value to write, so every compared field that changed counts.
///
/// Pure apart from reading EventKit objects, and free of `CheMCPKit`, so a standalone probe can
/// compile this file as is. The field comparisons are in `UndoPostStateFields.swift`; the
/// resolve-and-check step and the errors in `UndoGuardErrors.swift`; the EventKit side in
/// `EventKitManager+UndoGuard.swift`.
enum UndoHistoryVerb: String, Sendable {
    case undo, redo
}

/// What an undo or redo must find before it writes.
enum UndoPostState {
    enum Kind: String, Sendable { case event, reminder }

    /// A reminder's completion as one value: the flag, and the instant when it was observed.
    struct CompletionState: Equatable, Sendable {
        let isCompleted: Bool
        let completionDate: Date?

        /// Equal flags, and for a completed item equal instants (to the second) when both are
        /// known: an instant the record never observed (a write that stamped "now") cannot be
        /// compared.
        func matches(_ other: CompletionState) -> Bool {
            guard isCompleted == other.isCompleted else { return false }
            guard isCompleted, let completionDate, let other = other.completionDate else { return true }
            return UndoPostState.sameInstant(completionDate, other)
        }
    }

    /// The event as the write left it. `restoring` is the snapshot an update-undo writes back;
    /// `nil` when the undo deletes the event.
    case event(id: String, title: String, state: EventSnapshot, restoring: EventSnapshot?)
    /// The calendar an in-place move left the event in, and the one the undo moves it back to;
    /// a move-undo writes only the calendar.
    case eventCalendar(id: String, title: String, calendarIdentifier: String, restoringCalendarIdentifier: String)
    /// The reminder as the write left it; `restoring` as for events.
    case reminder(id: String, title: String, state: ReminderSnapshot, restoring: ReminderSnapshot?)
    /// A completion write: the state it left, and the state the undo (or redo) writes. `restoring`
    /// is nil when reaching that state must not count as "already done": a record of a recurring
    /// reminder without the #204 occurrence snapshot, where after a rollover the identifier points
    /// at the next occurrence, which may look exactly like what the write would produce.
    case reminderCompletion(id: String, title: String, state: CompletionState, restoring: CompletionState?)

    var kind: Kind {
        switch self {
        case .event, .eventCalendar: return .event
        case .reminder, .reminderCompletion: return .reminder
        }
    }

    var itemID: String {
        switch self {
        case .event(let id, _, _, _), .eventCalendar(let id, _, _, _),
             .reminder(let id, _, _, _), .reminderCompletion(let id, _, _, _):
            return id
        }
    }

    var title: String {
        switch self {
        case .event(_, let title, _, _), .eventCalendar(_, let title, _, _),
             .reminder(_, let title, _, _), .reminderCompletion(_, let title, _, _):
            return title
        }
    }

    /// Names of the fields that block the undo: changed since the write and not already at the
    /// value the undo writes. Empty when the undo may write. Field names are the tool parameter
    /// names, author-controlled.
    func changedFields(in item: EKCalendarItem) -> [String] {
        switch self {
        case .event(_, _, let state, let restoring):
            guard let event = item as? EKEvent else { return ["item_type"] }
            return state.changedFields(in: EventSnapshot(from: event), restoring: restoring)
        case .eventCalendar(_, _, let calendarIdentifier, let restoringCalendarIdentifier):
            let current = item.calendar?.calendarIdentifier
            return current == calendarIdentifier || current == restoringCalendarIdentifier ? [] : ["calendar"]
        case .reminder(_, _, let state, let restoring):
            guard let reminder = item as? EKReminder else { return ["item_type"] }
            return state.changedFields(in: ReminderSnapshot(from: reminder), restoring: restoring)
        case .reminderCompletion(_, _, let state, let restoring):
            guard let reminder = item as? EKReminder else { return ["item_type"] }
            let current = CompletionState(isCompleted: reminder.isCompleted, completionDate: reminder.completionDate)
            if state.matches(current) { return [] }
            if let restoring, restoring.matches(current) { return [] }
            return [state.isCompleted == current.isCompleted ? "completion_date" : "completed"]
        }
    }

    /// Instants are compared to the second: a completion instant comes from `now` and carries
    /// sub-second digits a synced store need not keep, and the tools write whole seconds.
    static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1
        default: return false
        }
    }

    // MARK: - Series (PR #259, round 1 finding 1, round 2 findings 3, 4, 15, 27)

    /// Undo of `create_event` on a series deletes every occurrence (`.futureEvents` on the first),
    /// occurrences edited on their own included (checked on device), but `event(withIdentifier:)`
    /// returns only the first occurrence, so the field check alone would miss them. The scan looks
    /// for detached occurrences from a day before the first occurrence to a day after the rule's
    /// end, at most 1460 days in all (EventKit matches at most four years per query).
    ///
    /// Not seen, so not protected: an edited occurrence that was moved outside that window (before
    /// the first occurrence, after the rule's end, or beyond the four years); and anything more
    /// than four years in, which includes the later part of a long count-based rule, scanned as
    /// open-ended because its end has no date.
    static func seriesScanWindow(firstStart: Date, ruleEnd: Date?) -> DateInterval {
        let day: TimeInterval = 86_400
        let from = firstStart.addingTimeInterval(-day)
        let cap = from.addingTimeInterval(1460 * day)
        let to = ruleEnd.map { min($0.addingTimeInterval(day), cap) } ?? cap
        return DateInterval(start: from, end: max(to, from))
    }

    /// The identifiers that tie an occurrence to its series.
    struct OccurrenceIDs: Equatable {
        let eventIdentifier: String?
        let externalIdentifier: String?
    }

    /// On device (iCloud, 2026-10-05) an occurrence edited on its own reads back with its own
    /// identifier, the series identifier plus `/RID=<seconds>`, and its external identifier is
    /// the series UID plus the same suffix. Other stores may give it an unrelated identifier but
    /// keep the iCalendar UID, so either identifier, equal or with a `/` suffix, ties it to the
    /// series. Unedited occurrences share the series identifier.
    static func isOccurrence(_ occurrence: OccurrenceIDs, of series: OccurrenceIDs) -> Bool {
        func sameOrSuffixed(_ value: String?, _ base: String?) -> Bool {
            guard let value, let base, !base.isEmpty else { return false }
            return value == base || value.hasPrefix(base + "/")
        }
        return sameOrSuffixed(occurrence.eventIdentifier, series.eventIdentifier)
            || sameOrSuffixed(occurrence.externalIdentifier, series.externalIdentifier)
    }

    /// What the scan compares a detached occurrence by (PR #259 round 3 finding 7, round 4
    /// decision): its slot, and the occurrence as an `EventSnapshot` without rules.
    struct OccurrenceFace {
        /// `occurrenceDate`: the start the rule gives this occurrence.
        let slot: Date?
        let event: EventSnapshot
    }

    /// A detached occurrence is an edit when it differs from the series' first occurrence in any
    /// field the guard compares: moved off the start its rule gives it (its slot), or a different
    /// title, notes, location, URL, all-day flag, duration, alarms, time zone or place. The
    /// guard's tolerances apply: an alarm sound, and coordinates added to a place the series has
    /// without them, are not edits; nil and empty text are the same; instants compare to the
    /// second; time zones by their offset at the occurrence's start and at the next daylight-saving
    /// transition (`sameTimeZone`). Place coordinates compare
    /// exactly (`samePlace`): a store that rounded them would make a place look moved, which can
    /// only refuse more. An occurrence back at the series' values stays detached (EventKit cannot
    /// re-attach it) and is not an edit. No slot to compare with counts as moved, the side that
    /// refuses.
    static func differsFromSeries(_ occurrence: OccurrenceFace, series: OccurrenceFace) -> Bool {
        let (one, all) = (occurrence.event, series.event)
        guard let slot = occurrence.slot, sameInstant(one.startDate, slot) else { return true }
        func text(_ value: String?) -> String { value ?? "" }
        func duration(_ event: EventSnapshot) -> TimeInterval { event.endDate.timeIntervalSince(event.startDate) }

        return text(one.title) != text(all.title)
            || text(one.notes) != text(all.notes)
            || text(one.location) != text(all.location)
            || text(one.url?.absoluteString) != text(all.url?.absoluteString)
            || one.isAllDay != all.isAllDay
            || abs(duration(one) - duration(all)) >= 1
            || !sameAlarms(all.alarms, one.alarms)
            || !sameTimeZone(one.timeZone, all.timeZone, at: one.startDate)
            || !EventSnapshot.samePlace(recorded: all, current: one)
    }

    /// What the scan result adds to a create-undo check of a series: nil means the scan could not
    /// run (no identifier or calendar), which refuses rather than passing as "no edits".
    static func seriesConflicts(modifiedOccurrences: Int?) -> [String] {
        guard let modifiedOccurrences else { return ["unchecked_occurrences"] }
        return modifiedOccurrences > 0 ? ["modified_occurrences"] : []
    }

    /// The number of detached occurrences of `event`'s series in the scan window that differ from
    /// the series (`differsFromSeries`), or nil when the scan cannot run. Reads only the series'
    /// own calendar.
    static func modifiedOccurrenceCount(of event: EKEvent, in store: EKEventStore) -> Int? {
        guard let id = event.eventIdentifier, !id.isEmpty, let calendar = event.calendar else { return nil }
        let series = OccurrenceIDs(eventIdentifier: id, externalIdentifier: event.calendarItemExternalIdentifier)
        let seriesFace = OccurrenceFace(event)
        let ruleEnds = (event.recurrenceRules ?? []).map { $0.recurrenceEnd?.endDate }
        // Any open-ended (or count-based) rule leaves the series open.
        let ruleEnd = ruleEnds.contains(where: { $0 == nil }) ? nil : ruleEnds.compactMap { $0 }.max()
        let window = seriesScanWindow(firstStart: event.startDate, ruleEnd: ruleEnd)
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
        var count = 0
        store.enumerateEvents(matching: predicate) { occurrence, _ in
            let ids = OccurrenceIDs(eventIdentifier: occurrence.eventIdentifier,
                                    externalIdentifier: occurrence.calendarItemExternalIdentifier)
            if occurrence.isDetached, isOccurrence(ids, of: series),
               differsFromSeries(OccurrenceFace(occurrence), series: seriesFace) { count += 1 }
        }
        return count
    }
}

extension UndoPostState.OccurrenceFace {
    init(_ event: EKEvent) {
        self.init(slot: event.occurrenceDate, event: EventSnapshot(from: event, includeRecurrence: false))
    }
}

extension UndoOperation {
    /// What an undo of this record must find before it writes: the state the recorded write
    /// left, and what the undo writes back. `nil` for the delete records (undo recreates; there
    /// is no item to overwrite, #247) and for a batch, whose sub-operations are checked one by
    /// one before any of them runs.
    var undoPostState: UndoPostState? {
        switch self {
        case .createEvent(let id, let title, let created):
            return .event(id: id, title: title, state: created, restoring: nil)
        case .updateEvent(let id, let oldSnapshot, let saved):
            return .event(id: id, title: saved.title, state: saved, restoring: oldSnapshot)
        case .moveEvent(let id, let fromCalendarIdentifier, let toCalendarIdentifier, let title, _):
            return .eventCalendar(id: id, title: title, calendarIdentifier: toCalendarIdentifier,
                                  restoringCalendarIdentifier: fromCalendarIdentifier)
        case .createReminder(let id, let title, let created):
            return .reminder(id: id, title: title, state: created, restoring: nil)
        case .updateReminder(let id, let oldSnapshot, let saved):
            return .reminder(id: id, title: saved.title, state: saved, restoring: oldSnapshot)
        case .completeReminder, .completeRecurringReminder:
            guard let completion = completionStates else { return nil }
            return .reminderCompletion(id: completion.id, title: completion.title, state: completion.written,
                                       restoring: completion.identityConfirmed ? completion.undoWrites : nil)
        case .deleteEvent, .deleteReminder, .batch, .updateRecurringEvent:
            return nil
        }
    }

    /// What a redo must find: the state the undo left, and the request it writes again. Only the
    /// completion records write on redo; the others return an instruction (#247).
    var redoPostState: UndoPostState? {
        guard let completion = completionStates else { return nil }
        return .reminderCompletion(id: completion.id, title: completion.title, state: completion.undoWrites,
                                   restoring: completion.identityConfirmed ? completion.written : nil)
    }

    /// A completion record's two states: what the completion wrote, and what undo writes back.
    /// `identityConfirmed` is false for a record of a recurring reminder kept without the #204
    /// occurrence snapshot (PR #259 round 2, finding 2).
    private var completionStates: (id: String, title: String, written: UndoPostState.CompletionState,
                                   undoWrites: UndoPostState.CompletionState, identityConfirmed: Bool)? {
        switch self {
        case .completeReminder(let id, let wasCompleted, let requestedCompleted, let completionDate, let title, let redoCompletionDate, let wasRecurring):
            return (id, title,
                    .init(isCompleted: requestedCompleted, completionDate: requestedCompleted ? redoCompletionDate : nil),
                    .init(isCompleted: wasCompleted, completionDate: wasCompleted ? completionDate : nil),
                    !wasRecurring)
        case .completeRecurringReminder(let before, let requestedCompleted, let redoCompletionDate):
            return (before.id, before.title,
                    .init(isCompleted: requestedCompleted, completionDate: requestedCompleted ? redoCompletionDate : nil),
                    .init(isCompleted: before.isCompleted, completionDate: before.isCompleted ? before.completionDate : nil),
                    true)
        default:
            return nil
        }
    }
}

/// D4: a batch is checked whole before its first write, so a refusal never leaves it half undone
/// (a failure *during* the writes is #248). Generic over the operation so the ordering is
/// unit-tested without EventKit (the closure-seam variant, like `ExclusionExecutor`).
///
/// Only batch records reach this: lists of `.deleteEvent` (multi-event and series deletes) and of
/// `.deleteReminder` (reminder batch deletes, #243). Their undo writes to no existing item, so the
/// post-state part has nothing to compare (PR #259 verify #12 / #25 / #28); what the pre-flight
/// checks for them is that the calendar or list each is recreated in exists (#248 B,
/// `verifyRestoreDestination`). It assumes the members touch different
/// items: two members on one item would both be checked against the state before either is
/// undone. It is not atomic: each member re-checks when it runs, and a store change in between
/// can still stop the batch half way (#248).
enum UndoBatchRunner {
    static func run<Operation>(_ operations: [Operation],
                               check: (Operation) async throws -> Void,
                               execute: (Operation) async throws -> String) async rethrows -> [String] {
        for operation in operations {
            try await check(operation)
        }
        var results: [String] = []
        for operation in operations {
            results.append(try await execute(operation))
        }
        return results
    }
}
