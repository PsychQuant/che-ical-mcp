import EventKit
import Foundation

/// #236 — the manager side of the post-state guard (the comparison is in
/// `UndoPostStateGuard.swift`). A record captures the state its write left by reading the item
/// back the way undo will read it; undo resolves the item, refreshes it, compares, and refuses
/// with `UndoTargetChangedError` before writing anything.
extension EventKitManager {
    /// The state an undo of this event write compares with, read the way the undo reads it
    /// (by identifier, refreshed): for a recurring event that is the series' first occurrence,
    /// not necessarily the object the write saved. Falls back to the saved object when the
    /// identifier does not resolve yet; the undo then fails as not found, which keeps the record.
    func postWriteSnapshot(eventID: String, saved: EKEvent) -> EventSnapshot {
        if !eventID.isEmpty, let event = eventStore.event(withIdentifier: eventID), event.refresh() {
            return EventSnapshot(from: event)
        }
        return EventSnapshot(from: saved)
    }

    /// Reminder counterpart of `postWriteSnapshot(eventID:saved:)`.
    func postWriteSnapshot(reminderID: String, saved: EKReminder) -> ReminderSnapshot {
        if !reminderID.isEmpty, let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder,
           reminder.refresh() {
            return ReminderSnapshot(from: reminder)
        }
        return ReminderSnapshot(from: saved)
    }

    /// The event under `id`, refreshed, or nil when it is not there. `refresh()` because a
    /// long-lived store can return stale fields after an edit made elsewhere until the object is
    /// refreshed (diagnosis evidence 2, confirmed on device); `false` from it means the event is
    /// gone. Used where undo state is captured (PR #259 verify #5) and where undo reads.
    func freshEvent(id: String) -> EKEvent? {
        refreshIfNeeded()
        guard !id.isEmpty, let event = eventStore.event(withIdentifier: id), event.refresh() else { return nil }
        return event
    }

    /// Reminder counterpart of `freshEvent(id:)`.
    func freshReminder(id: String) -> EKReminder? {
        refreshIfNeeded()
        guard !id.isEmpty, let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder,
              reminder.refresh() else { return nil }
        return reminder
    }

    /// The item an undo (or redo) of `operation` writes to: resolved, refreshed, and checked
    /// against the state the operation (for a redo: its undo) left, through `UndoTargetCheck`.
    /// Throws instead of returning an item the write would change again; `nil` for records that
    /// write to no existing item. Per record:
    /// - create_event on a series: the delete removes every occurrence, so occurrences edited on
    ///   their own also block it (`modified_occurrences`, verify #1).
    /// - a recurring completion: the #204 identity guard first (a different occurrence is
    ///   permanent), then the completion check (transient).
    /// - a completion record of a recurring reminder without the #204 snapshot: no "already in
    ///   the state the write gives" exemption (PR #259 round 2 finding 2). A mismatch is
    ///   discarded when the reminder still repeats and has the opposite completion (the shape a
    ///   rollover leaves, round 3 finding 8), and refused and kept otherwise; the refusal gets
    ///   the refreshed item to tell the two apart (`postStateRefusal`).
    func verifiedHistoryTarget(of operation: UndoOperation, verb: UndoHistoryVerb) async throws -> EKCalendarItem? {
        guard let expected = verb == .undo ? operation.undoPostState : operation.redoPostState else { return nil }
        let refusal: (EKCalendarItem, [String]) -> Error = { item, fields in
            operation.postStateRefusal(verb: verb, changedFields: fields, current: item)
        }
        switch expected.kind {
        case .event:
            let deletesSeries: Bool
            if case .createEvent = operation, verb == .undo { deletesSeries = true } else { deletesSeries = false }
            return try UndoTargetCheck.check(
                expected, verb: verb,
                lookup: { () -> EKEvent? in
                    refreshIfNeeded()
                    return expected.itemID.isEmpty ? nil : eventStore.event(withIdentifier: expected.itemID)
                },
                refresh: { $0.refresh() },
                conflicts: { event in
                    // Rounds 5–6: update-undo and the undo of a one-off move never write to an
                    // event that repeats or is an edited occurrence now; refused and discarded
                    // before the comparison.
                    if let refusal = operation.recurringTargetRefusal(hasRecurrenceRules: event.hasRecurrenceRules,
                                                                      isDetached: event.isDetached) {
                        throw refusal
                    }
                    let fields = expected.changedFields(in: event)
                    guard deletesSeries, event.hasRecurrenceRules else { return fields }
                    return fields + UndoPostState.seriesConflicts(
                        modifiedOccurrences: UndoPostState.modifiedOccurrenceCount(of: event, in: eventStore))
                },
                refusal: refusal)
        case .reminder:
            try await ensureReminderAccess()
            var identity: ReminderCompletionSnapshot?
            if case .completeRecurringReminder(let before, _, _) = operation { identity = before }
            return try UndoTargetCheck.check(
                expected, verb: verb,
                lookup: { () -> EKReminder? in
                    refreshIfNeeded()
                    return expected.itemID.isEmpty ? nil : eventStore.calendarItem(withIdentifier: expected.itemID) as? EKReminder
                },
                refresh: { $0.refresh() },
                conflicts: { reminder in
                    if let identity { try ensureSameOccurrence(identity, reminder, verb: verb.rawValue) }
                    return expected.changedFields(in: reminder)
                },
                refusal: refusal)
        }
    }

    /// D4 pre-flight for one member of a batch (nested batches are walked).
    func verifyHistoryTarget(of operation: UndoOperation, verb: UndoHistoryVerb) async throws {
        if case .batch(let operations) = operation {
            for member in operations { try await verifyHistoryTarget(of: member, verb: verb) }
            return
        }
        try verifyBatchMemberRestorable(operation, verb: verb)
        _ = try await verifiedHistoryTarget(of: operation, verb: verb)
    }

    /// #244 D3: a member whose undo can never restore it (a span "future" delete recorded as the
    /// marker) refuses the whole batch here, before any member writes.
    func verifyBatchMemberRestorable(_ operation: UndoOperation, verb: UndoHistoryVerb) throws {
        if verb == .undo, let refusal = operation.batchMemberUndoRefusal { throw refusal }
    }

    /// #248 B: a batch whose undo recreates items (deleted events and reminders) needs the calendar
    /// or list each is recreated in, so a batch with a member whose calendar is gone or read-only is
    /// refused before its first write instead of failing part-way. Run once per batch, before the
    /// per-member checks: the calendars and lists are read once however many members the batch holds
    /// (a cleanup holds up to its `limit`), and once more after a missing or read-only destination
    /// (`UndoRestoreDestination.verify`).
    /// Not a transaction: a calendar deleted after this check still stops the batch part-way
    /// (`UndoBatchPartiallyUndoneError`).
    func verifyRestoreDestinations(of members: [UndoOperation], verb: UndoHistoryVerb) async throws {
        let destinations = UndoRestoreDestination.of(members, verb: verb)
        let needsCalendars = destinations.contains { if case .eventCalendar = $0 { return true }; return false }
        let needsLists = destinations.contains { if case .reminderList = $0 { return true }; return false }
        try await UndoRestoreDestination.verify(
            destinations, identifier: { $0.calendarIdentifier }, allowsModifications: { $0.allowsContentModifications },
            read: {
                var eventCalendars: [EKCalendar] = []
                var reminderLists: [EKCalendar] = []
                if needsCalendars {
                    try await self.ensureCalendarAccess()
                    self.refreshIfNeeded()
                    eventCalendars = self.eventStore.calendars(for: .event)
                }
                if needsLists {
                    // The entry the reminder restore reads its lists through (#242).
                    reminderLists = try await self.reminderListsForRestore()
                }
                return (eventCalendars, reminderLists)
            },
            invalidate: { self.markNeedsRefresh() })
    }

    /// Each undo arm knows its record kind, so a mismatch is unreachable by construction; it
    /// throws rather than force-unwrapping, like `apply(_:to:)`.
    func verifiedEvent(of operation: UndoOperation, verb: UndoHistoryVerb) async throws -> EKEvent {
        guard let event = try await verifiedHistoryTarget(of: operation, verb: verb) as? EKEvent else {
            throw UnrecoverableUndoError(message: "Undo record has no event post-state.")
        }
        return event
    }

    func verifiedReminder(of operation: UndoOperation, verb: UndoHistoryVerb) async throws -> EKReminder {
        guard let reminder = try await verifiedHistoryTarget(of: operation, verb: verb) as? EKReminder else {
            throw UnrecoverableUndoError(message: "Undo record has no reminder post-state.")
        }
        return reminder
    }
}
