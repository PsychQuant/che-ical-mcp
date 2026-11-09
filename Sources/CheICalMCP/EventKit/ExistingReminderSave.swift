import EventKit

/// #274 / #459: a save or a removal of a reminder or reminder list that is already in the store.
///
/// A failed commit stays pending in the store it was made on, and that store's next commit of
/// anything writes it (#274, measured on iCloud 2026-11-06: the new title of a reminder, the
/// rollover of a repeating reminder, a removed reminder, a renamed list, a removed list with its
/// reminders). Nothing on the object drops it (`rollback()`, `refresh()`, `reset()` on a reminder),
/// and `EKEventStore.reset()` reaches every other call in flight. So since #459 these writes commit
/// on a separate write store (`WriteStorePool`): the item is looked up there by identifier, the
/// caller's fields are copied onto it (`ReminderFieldCopy`, `ListFieldCopy`), and it is committed
/// there. A failure is dropped with that store, and the long-lived store never holds it; measured
/// 2026-11-09 (iCloud, one process) with the #261 method (EKCADErrorDomain 1010). So a failure
/// answers as itself.
///
/// Only the fields the call changed are written (PR #507 round 1): the caller's object is
/// snapshotted, rolled back to what it held before the call, and the difference is what the copy
/// gets (`ReminderFieldCopy`, `ListFieldCopy`). On success the caller's object is refreshed, so it
/// reads what was committed: measured the same day, an unsaved change on a long-lived object does
/// not ride along with that store's later commits, and `rollback()` then `refresh()` reads the
/// write store's commit at once (a removed item: `refresh()` is false; a rolled-over repeating
/// reminder reads rolled over). When the save gave the reminder another identifier (a move to a
/// list in another account), the reminder is resolved again by that identifier; a refresh that
/// fails after a save is a failed read-back (`writeStoreReadBackFailed`), not something to ignore.
///
/// Event writes stay on the long-lived store: their failed writes left nothing pending (#274). So
/// do creates, including the #237 second save of a create (`uncheckedKept`, #289).
enum ExistingReminderSave {
    /// Closure seam (#182), so the order is tested without a store.
    static func run(write: () throws -> Void, rollback: () -> Void, report: (Error) -> Error) throws {
        do {
            try write()
        } catch {
            rollback()
            throw report(error)
        }
    }

    /// What a failed write answers: the failure itself (it did not land), after `code` logs it.
    static func failure(_ error: Error, code: (Error) -> String) -> Error {
        _ = code(error)
        return error
    }
}

/// #459 (PR #507 round 2): what the write store's copy held right after its commit, taken before the
/// copy is dropped, so a save that landed but cannot be read back still has the state its undo needs.
struct CommittedReminder {
    let identifier: String
    let snapshot: ReminderSnapshot
    let completion: ReminderCompletionSnapshot
}

/// The result of a save that committed: the reminder as this server's store reads it (another object
/// after a move to a list in another account), or, when it cannot be read back, what was committed.
enum ReminderSaveOutcome {
    case readBack(EKReminder)
    case unread(CommittedReminder)
}

/// Thrown by `savedOrUnread` and caught by its caller, never answered.
struct UnreadSaveError: Error {
    let committed: CommittedReminder
}

extension EventKitManager {
    /// `handler` names the failure on stderr; the response gets the sanitized error. A commit that
    /// fails throws. A commit that lands answers `.readBack`, or `.unread` when the reminder cannot be
    /// read back: the caller then records its undo from `CommittedReminder` before it reports
    /// `writeStoreReadBackFailed`, so the undo history stays in step with the store (round 2 HIGH).
    /// `requested` are the fields the request names, written also when the cache already held them.
    func saveExistingReminder(_ reminder: EKReminder, handler: String, requested: Set<ReminderFieldCopy.Field> = []) throws -> ReminderSaveOutcome {
        var outcome: ReminderSaveOutcome?
        try ExistingReminderSave.run(
            write: { outcome = try commitReminderSave(reminder, requested: requested) },
            rollback: { reminder.rollback() },
            report: { failure in
                ExistingReminderSave.failure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: handler, identifier: reminder.calendarItemIdentifier, error: $0)
                }
            })
        guard let outcome else { throw EventKitError.writeStoreLookupFailed(kind: "reminder") }
        if case .unread(let committed) = outcome {
            FileHandle.standardError.write(Data("\(handler): saved \(committed.identifier) on the write store but could not read it back\n".utf8))
        }
        return outcome
    }

    /// The reminder after its save, or `UnreadSaveError` when it landed but cannot be read back, for a
    /// caller that records its undo in a catch at its end (`completeReminder`).
    func savedOrUnread(_ reminder: EKReminder, handler: String, requested: Set<ReminderFieldCopy.Field> = []) throws -> EKReminder {
        switch try saveExistingReminder(reminder, handler: handler, requested: requested) {
        case .readBack(let read): return read
        case .unread(let committed): throw UnreadSaveError(committed: committed)
        }
    }

    /// An undo or redo whose save landed: the record has done its work, so the stacks move as for a
    /// success; when the reminder cannot be read back the message says so (round 2 HIGH).
    func saveForHistory(_ reminder: EKReminder, handler: String, requested: Set<ReminderFieldCopy.Field> = []) throws -> String {
        switch try saveExistingReminder(reminder, handler: handler, requested: requested) {
        case .readBack: return ""
        case .unread: return " The change was saved, but this server could not read the reminder back right after it; read it again before relying on it."
        }
    }

    func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {
        try ExistingReminderSave.run(
            write: { try commitReminderRemoval(reminder) },
            rollback: { reminder.rollback() },
            report: { failure in
                ExistingReminderSave.failure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: handler, identifier: reminder.calendarItemIdentifier, error: $0)
                }
            })
    }

    /// A rename or recolor of a reminder list goes through the write store; an event calendar goes
    /// straight through the long-lived store, as every event write does. Returns whether the list was
    /// read back after the save; when not, the caller records its #273 marker and reports it (round 2).
    func saveExistingCalendar(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {
        guard calendar.allowedEntityTypes != .event else {
            try eventStore.saveCalendar(calendar, commit: true)
            return true
        }
        var readBack = true
        try ExistingReminderSave.run(
            write: { readBack = try commitListSave(calendar, requested: requested) },
            rollback: { calendar.rollback() },
            report: { failure in
                ExistingReminderSave.failure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: "updateCalendar", identifier: calendar.calendarIdentifier, error: $0)
                }
            })
        if !readBack {
            FileHandle.standardError.write(Data("updateCalendar: saved \(calendar.calendarIdentifier) on the write store but could not read it back\n".utf8))
        }
        return readBack
    }

    func removeExistingCalendar(_ calendar: EKCalendar) throws {
        guard calendar.allowedEntityTypes != .event else {
            return try eventStore.removeCalendar(calendar, commit: true)
        }
        try ExistingReminderSave.run(
            write: { try commitListRemoval(calendar) },
            rollback: { calendar.rollback() },
            report: { failure in
                ExistingReminderSave.failure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: "deleteCalendar", identifier: calendar.calendarIdentifier, error: $0)
                }
            })
    }

    // MARK: - #459: commits on the write store

    /// Commits the caller's changes to `reminder` on the write store: the fields the call changed and
    /// the fields the request names (`requested`, round 2: a named value equal to a stale cache is
    /// still written). Returns the reminder as this server's store reads it after the save, or what
    /// the copy held after its commit when it cannot be read back.
    func commitReminderSave(_ reminder: EKReminder, requested: Set<ReminderFieldCopy.Field> = []) throws -> ReminderSaveOutcome {
        let wanted = ReminderFieldCopy.Values(reminder)
        reminder.rollback()
        let fields = ReminderFieldCopy.changed(from: ReminderFieldCopy.Values(reminder), to: wanted).union(requested)
        let committed: CommittedReminder = try onWriteStore { store in
            guard let copy = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: "reminder") }
            try ReminderFieldCopy.apply(wanted, fields: fields, to: copy, calendar: { store.calendar(withIdentifier: $0) })
            try store.save(copy, commit: true)
            return CommittedReminder(identifier: copy.calendarItemIdentifier, snapshot: ReminderSnapshot(from: copy),
                                     completion: ReminderCompletionSnapshot(from: copy))
        }
        guard let saved = resolvedAfterSave(reminder, savedID: committed.identifier) else { return .unread(committed) }
        return .readBack(saved)
    }

    /// The reminder after its save on the write store: the caller's object, refreshed, when the
    /// identifier did not change; otherwise the reminder the new identifier resolves to on this
    /// server's store. Nil when it cannot be read back.
    func resolvedAfterSave(_ reminder: EKReminder, savedID: String) -> EKReminder? {
        if savedID == reminder.calendarItemIdentifier { return reminder.refresh() ? reminder : nil }
        guard let moved = eventStore.calendarItem(withIdentifier: savedID) as? EKReminder, moved.refresh() else { return nil }
        return moved
    }

    /// Removes `reminder` on the write store. Also the batch removal's row (`deleteRemindersBatch`),
    /// whose failure keeps its own sanitized code (spec R3).
    func commitReminderRemoval(_ reminder: EKReminder) throws {
        try onWriteStore { store in
            guard let copy = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: "reminder") }
            try store.remove(copy, commit: true)
        }
        reminder.rollback()
        _ = reminder.refresh()
    }

    /// Commits the caller's rename or recolor on the write store: only the field the call changed.
    /// Returns whether this server's store reads the list back after the save.
    func commitListSave(_ calendar: EKCalendar, requested: Set<ListFieldCopy.Field> = []) throws -> Bool {
        let wanted = ListFieldCopy.Values(calendar)
        calendar.rollback()
        let fields = ListFieldCopy.changed(from: ListFieldCopy.Values(calendar), to: wanted).union(requested)
        try onWriteStore { store in
            guard let copy = store.calendar(withIdentifier: calendar.calendarIdentifier) else { throw EventKitError.writeStoreLookupFailed(kind: "reminder list") }
            ListFieldCopy.apply(wanted, fields: fields, to: copy)
            try store.saveCalendar(copy, commit: true)
        }
        return calendar.refresh()
    }

    func commitListRemoval(_ calendar: EKCalendar) throws {
        try onWriteStore { store in
            guard let copy = store.calendar(withIdentifier: calendar.calendarIdentifier) else { throw EventKitError.writeStoreLookupFailed(kind: "reminder list") }
            try store.removeCalendar(copy, commit: true)
        }
        calendar.rollback()
        _ = calendar.refresh()
    }

    /// Runs `body` on the write store of this call: the lease a batch call holds, or one opened for
    /// this write alone and released after it.
    func onWriteStore<T>(_ body: (EKEventStore) throws -> T) throws -> T {
        defer { writeStoreCommits &+= 1 }   // #328: counted like a commit on the long-lived store
        if let lease = WriteStoreContext.current as? WriteStoreLease<EKEventStore> { return try lease.use(body) }
        let lease = WriteStoreLease(pool: writeStores)
        defer { lease.close() }
        return try lease.use(body)
    }

    /// Runs a call with one write store for all its writes (a batch shares it). A call already in a
    /// lease keeps it.
    func withWriteLease<T>(_ operation: () async throws -> T) async rethrows -> T {
        if WriteStoreContext.current is WriteStoreLease<EKEventStore> { return try await operation() }
        let lease = WriteStoreLease(pool: writeStores)
        defer { lease.close() }
        return try await WriteStoreContext.$current.withValue(lease) { try await operation() }
    }
}
