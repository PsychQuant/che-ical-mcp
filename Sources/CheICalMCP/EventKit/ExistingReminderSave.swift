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
/// On success the caller's object is rolled back and refreshed, so it reads what was committed:
/// measured the same day, an unsaved change on a long-lived object does not ride along with that
/// store's later commits, and `rollback()` then `refresh()` reads the write store's commit at once
/// (a removed item: `refresh()` is false; a rolled-over repeating reminder reads rolled over).
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

extension EventKitManager {
    /// `handler` names the failure on stderr; the response gets the sanitized error.
    func saveExistingReminder(_ reminder: EKReminder, handler: String) throws {
        try ExistingReminderSave.run(
            write: { try commitReminderSave(reminder) },
            rollback: { reminder.rollback() },
            report: { failure in
                ExistingReminderSave.failure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: handler, identifier: reminder.calendarItemIdentifier, error: $0)
                }
            })
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
    /// straight through the long-lived store, as every event write does.
    func saveExistingCalendar(_ calendar: EKCalendar) throws {
        guard calendar.allowedEntityTypes != .event else {
            return try eventStore.saveCalendar(calendar, commit: true)
        }
        try ExistingReminderSave.run(
            write: { try commitListSave(calendar) },
            rollback: { calendar.rollback() },
            report: { failure in
                ExistingReminderSave.failure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: "updateCalendar", identifier: calendar.calendarIdentifier, error: $0)
                }
            })
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

    /// Commits the caller's changes to `reminder` on the write store.
    func commitReminderSave(_ reminder: EKReminder) throws {
        try onWriteStore { store in
            guard let copy = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { throw EventKitError.writeStoreLookupFailed(kind: "reminder") }
            try ReminderFieldCopy.apply(from: reminder, to: copy, calendar: { store.calendar(withIdentifier: $0) })
            try store.save(copy, commit: true)
        }
        reminder.rollback()
        _ = reminder.refresh()
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

    func commitListSave(_ calendar: EKCalendar) throws {
        try onWriteStore { store in
            guard let copy = store.calendar(withIdentifier: calendar.calendarIdentifier) else { throw EventKitError.writeStoreLookupFailed(kind: "reminder list") }
            ListFieldCopy.apply(from: calendar, to: copy)
            try store.saveCalendar(copy, commit: true)
        }
        calendar.rollback()
        _ = calendar.refresh()
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
