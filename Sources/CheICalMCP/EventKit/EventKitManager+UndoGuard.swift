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
        if let event = storedEvent(id: eventID), event.refresh() {
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
    /// gone, except for a series whose first occurrence was deleted (#326, below), which fails to
    /// refresh while its other occurrences remain. Used where undo state is captured (PR #259
    /// verify #5) and where undo reads. A reminder's id is not found (#260, `storedEvent(id:)`).
    ///
    /// A series whose first occurrence was deleted resolves, but its object does not refresh
    /// (#326, root cause #284); the earliest remaining occurrence stands in for it
    /// (`FirstRemainingOccurrence`), and a series with none left stays not found.
    func freshEvent(id: String) -> EKEvent? {
        freshEventWithOrigin(id: id)?.event
    }

    /// `freshEvent(id:)` and whether the event is the stand-in for the series (#326): a caller
    /// that writes to the whole series needs to know, because that write is a `.futureEvents`
    /// save on a middle occurrence.
    func freshEventWithOrigin(id: String, refuseWhenEditedBefore: Bool = true) -> (event: EKEvent, viaStandIn: Bool)? {
        refreshIfNeeded()
        return FirstRemainingOccurrence.resolve(
            stored: storedEvent(id: id), refresh: { $0.refresh() },
            standIn: { firstRemainingOccurrence(of: $0, id: id, refuseWhenEditedBefore: refuseWhenEditedBefore) })
    }

    /// The error for an id that did not resolve (#335): `eventNotFound`, or, when only the
    /// edited-before refusal hides a series that `list_events` lists, `standInRefused` with the
    /// hint. A scan on the failure path only.
    func notFoundError(id: String) -> Error {
        refreshIfNeeded()
        let stored = storedEvent(id: id)
        let hint = FirstRemainingOccurrence.hintsEditedBefore(
            stored: stored != nil,
            refreshes: stored.map { $0.refresh() } ?? false,
            recurring: stored?.hasRecurrenceRules ?? false,
            standInIgnoringTheRefusal: stored.map { firstRemainingOccurrence(of: $0, id: id, refuseWhenEditedBefore: false) != nil } ?? false)
        if hint { return EventKitError.standInRefused(reason: Self.standInEditedBeforeReason) }
        // One listing gives both facts. A stand-in candidate that exists but failed to refresh is
        // not "all edited": the hint is for a series with no unedited occurrence in the scan.
        let facts = stored.map { standInAndEditedFacts(of: $0, id: id) } ?? (hasStandInCandidate: false, hasEdited: false)
        let allEdited = FirstRemainingOccurrence.hintsAllEdited(
            stored: stored != nil,
            refreshes: stored.map { $0.refresh() } ?? false,
            recurring: stored?.hasRecurrenceRules ?? false,
            standInIgnoringTheRefusal: facts.hasStandInCandidate,
            editedOccurrences: facts.hasEdited)
        return allEdited ? EventKitError.standInRefused(reason: Self.standInAllEditedReason)
                         : EventKitError.eventNotFound(identifier: id)
    }

    /// `notFoundError(id:)` as the short reason a batch row reports, in the batch's own words
    /// (`batchRowReason`, #335 item 6).
    func notFoundReason(id: String) -> String {
        if case EventKitError.standInRefused(let reason) = notFoundError(id: id) { return Self.batchRowReason(reason) }
        return "Event not found"
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
            // #269 verify: as the reminder case checks Reminders access, so that a store without
            // access is reported as that, not as a missing event or calendar.
            try await ensureCalendarAccess()
            let deletesSeries: Bool
            if case .createEvent = operation, verb == .undo { deletesSeries = true } else { deletesSeries = false }
            return try UndoTargetCheck.check(
                expected, verb: verb,
                lookup: { () -> EKEvent? in
                    if operation.resolvesThroughStandIn {
                        return try seriesMoveUndoTarget(operation, expected, verb: verb)
                    }
                    refreshIfNeeded()
                    return storedEvent(id: expected.itemID)
                },
                refresh: { $0.refresh() },
                missing: { stored in createUndoMissingError(of: operation, verb: verb, id: expected.itemID, stored: stored) },
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

    /// #369: the target of a whole-series move's undo, resolved as `moveEvent` resolved it: the
    /// series object when it refreshes, else the earliest remaining occurrence, with no
    /// edited-before refusal (a move leaves no occurrence behind, device 2026-10-20). The decision
    /// (not found, the residual not-found, the cross-account refusal) is `SeriesMoveUndo.decide`.
    private func seriesMoveUndoTarget(_ operation: UndoOperation, _ expected: UndoPostState,
                                      verb: UndoHistoryVerb) throws -> EKEvent? {
        let id = expected.itemID
        let resolved = freshEventWithOrigin(id: id, refuseWhenEditedBefore: false)
        // A recorded calendar that no longer resolves gives nil here; `decide` refuses a stand-in
        // still in the destination with the record's refusal (#269), and the move arm refuses the
        // series object the same way.
        // A miss is read once more after the view is marked stale (#269 verify, the batch order).
        let original = SeriesMoveUndo.restoringCalendarID(of: expected).flatMap { restoring in
            EventRestoreCalendar.lookup(read: {
                refreshIfNeeded()
                return eventStore.calendar(withIdentifier: restoring)
            }, invalidate: { markNeedsRefresh() })
        }
        return try SeriesMoveUndo.decide(
            expected, verb: verb,
            stored: { storedEvent(id: id) != nil },
            resolved: resolved.map {
                SeriesMoveUndo.Resolved(event: $0.event, viaStandIn: $0.viaStandIn,
                                        calendarID: $0.event.calendar?.calendarIdentifier,
                                        sourceID: $0.event.calendar?.source?.sourceIdentifier)
            },
            original: original.map { SeriesMoveUndo.OriginalCalendar(sourceID: $0.source?.sourceIdentifier) },
            missingOriginal: { operation.moveBackCalendarMissing })
    }

    /// #377: the not-found message of an event undo, asked only after the lookup found nothing or
    /// an object that did not refresh. For the undo of a create on a series, the earliest remaining
    /// occurrence (edited-before or not) and whether it starts after the record's own start pick
    /// the wording; the occurrence is never the target. The decision is
    /// `SeriesCreateUndo.missingError`; nil keeps the plain not-found.
    private func createUndoMissingError(of operation: UndoOperation, verb: UndoHistoryVerb, id: String,
                                        stored: EKEvent?) -> Error? {
        SeriesCreateUndo.missingError(
            of: operation, verb: verb, stored: stored != nil, recurring: stored?.hasRecurrenceRules ?? false,
            standInStart: {
                guard let stored else { return nil }
                return firstRemainingOccurrence(of: stored, id: id, refuseWhenEditedBefore: false)?.startDate
            })
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
                    // The entry the single event undo reads its calendars through (#269).
                    eventCalendars = try await self.eventCalendarsForRestore()
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
