import EventKit

/// #274: a save or a removal of a reminder or reminder list that is already in the store, when it
/// throws. The change cannot be dropped, so the error says it may still land.
///
/// Measured on iCloud (2026-11-06, one store, a commit made to fail with the #261 method,
/// EKCADErrorDomain 1010): the failed change stays pending in the store, and the next save of
/// anything commits it. That was the new title of a reminder, the rollover of a repeating reminder, a
/// removed reminder, a renamed list, and a removed list, which took its reminders with it, none of
/// which an undo record covers. `rollback()` on the object did not stop any of them, and `refresh()`
/// and `reset()` on a reminder did not either: `rollback()` only clears `hasChanges`, so it is here
/// to keep the object honest, not to undo the failure.
///
/// Refused at validation it is different: nothing was pending after EKErrorDomain 18, 23 and 26 on
/// an existing reminder, with or without `rollback()` (same probe, no failure induced), so those
/// answer as the error they are (`refusedAtValidation`). That list is closed: it is the codes that
/// were run, and any other failure of a save keeps the warning. A removal was not refused at
/// validation in any shape tried, so a removal always warns.
///
/// A failed write of an event left nothing pending, with or without `rollback()`: an edit, a series
/// edit, a move and a removal; so did a rename and a removal of an event calendar (no `rollback()`
/// for the removal). All of this is one failure shape: no ordinary use was found that makes these
/// fail at commit time.
///
/// `EKEventStore.reset()` does drop it, and PR #456 used it, but it stays out (verify of that PR).
/// The header says "All objects ever created/fetched, etc. using this store are no longer connected
/// to it and are considered invalid". The manager is a reentrant actor and swift-sdk runs each
/// request in its own task, so a reset would hit unrelated calls: `createReminder` holds a calendar
/// across `await findDuplicateReminder`, the undo paths hold objects across awaits, the handlers read
/// `EKEvent`s off the actor, and a `fetchReminders` in flight might never call back. That means false
/// successes, hangs or a crash in calls that did nothing wrong, against a rare failure whose change
/// is what the caller asked for. What a reset would need is on #459.
enum ExistingReminderSave {
    /// `EKError.Code` values measured to leave nothing pending. Closed: see above.
    static let refusedAtValidation: Set<Int> = [
        EKError.Code.recurringReminderRequiresDueDate.rawValue,   // 18
        EKError.Code.calendarDoesNotAllowReminders.rawValue,      // 23
        EKError.Code.priorityIsInvalid.rawValue                   // 26
    ]

    static func leftNothingPending(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == EKErrorDomain && refusedAtValidation.contains(error.code)
    }

    /// Closure seam (#182), so the order is tested without a store.
    static func run(write: () throws -> Void, rollback: () -> Void, report: (Error) -> Error) throws {
        do {
            try write()
        } catch {
            rollback()
            throw report(error)
        }
    }

    /// What a failed save of an existing reminder answers. `code` logs the failure and returns the
    /// sanitized code, so a refusal that left nothing pending goes on as itself, unlogged here.
    static func saveFailure(_ error: Error, code: (Error) -> String) -> Error {
        leftNothingPending(error) ? error : EventKitError.reminderSaveMayLand(code: code(error))
    }

    static func removalFailure(_ error: Error, code: (Error) -> String) -> Error {
        EventKitError.reminderRemovalMayLand(code: code(error))
    }

    static func listChangeFailure(_ error: Error, code: (Error) -> String) -> Error {
        EventKitError.listChangeMayLand(code: code(error))
    }

    static func listRemovalFailure(_ error: Error, code: (Error) -> String) -> Error {
        EventKitError.listRemovalMayLand(code: code(error))
    }
}

extension EventKitManager {
    /// `handler` names the failure on stderr; the response gets the code and the warning.
    func saveExistingReminder(_ reminder: EKReminder, handler: String) throws {
        try ExistingReminderSave.run(
            write: { try eventStore.save(reminder, commit: true) },
            rollback: { reminder.rollback() },
            report: { failure in
                ExistingReminderSave.saveFailure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: handler, identifier: reminder.calendarItemIdentifier, error: $0)
                }
            })
    }

    func removeExistingReminder(_ reminder: EKReminder, handler: String) throws {
        try ExistingReminderSave.run(
            write: { try eventStore.remove(reminder, commit: true) },
            rollback: { reminder.rollback() },
            report: { failure in
                ExistingReminderSave.removalFailure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: handler, identifier: reminder.calendarItemIdentifier, error: $0)
                }
            })
    }

    /// A rename or recolor of a reminder list. An event calendar goes straight through: its failed
    /// save left nothing pending (`ExistingReminderSave`).
    func saveExistingCalendar(_ calendar: EKCalendar) throws {
        guard calendar.allowedEntityTypes.contains(.reminder) else {
            return try eventStore.saveCalendar(calendar, commit: true)
        }
        try ExistingReminderSave.run(
            write: { try eventStore.saveCalendar(calendar, commit: true) },
            rollback: { calendar.rollback() },
            report: { failure in
                ExistingReminderSave.listChangeFailure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: "updateCalendar", identifier: calendar.calendarIdentifier, error: $0)
                }
            })
    }

    func removeExistingCalendar(_ calendar: EKCalendar) throws {
        guard calendar.allowedEntityTypes.contains(.reminder) else {
            return try eventStore.removeCalendar(calendar, commit: true)
        }
        try ExistingReminderSave.run(
            write: { try eventStore.removeCalendar(calendar, commit: true) },
            rollback: { calendar.rollback() },
            report: { failure in
                ExistingReminderSave.listRemovalFailure(failure) {
                    EventKitErrorSanitizer.writeFailureLog(handler: "deleteCalendar", identifier: calendar.calendarIdentifier, error: $0)
                }
            })
    }
}
