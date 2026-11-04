import EventKit

/// #328 (PR #413 security review): the manager's store, which counts its own commits. Every save
/// and removal made through it moves `commitCount` in the same synchronous step as the write
/// (`defer`, so a save that throws after the store took the object counts too), whichever writer
/// made it and whatever that writer does next (marks the store stale in a `defer`, records undo
/// after an `await`). `EventKitManager.deleteCalendar(requireEmpty:)` compares the count across its
/// one suspension, so a write committed during it is always seen. The overrides only count; they
/// change nothing about the write (pinned by `CalendarEmptinessTests`). A method EventKit calls
/// from another one is counted twice, which only makes the check refuse more often.
final class CountingEventStore: EKEventStore, @unchecked Sendable {
    /// Read and moved on the manager's actor (the only place this store is written through).
    private(set) var commitCount = 0

    override func save(_ event: EKEvent, span: EKSpan) throws {
        defer { commitCount &+= 1 }
        try super.save(event, span: span)
    }

    override func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        defer { commitCount &+= 1 }
        try super.save(event, span: span, commit: commit)
    }

    override func remove(_ event: EKEvent, span: EKSpan) throws {
        defer { commitCount &+= 1 }
        try super.remove(event, span: span)
    }

    override func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        defer { commitCount &+= 1 }
        try super.remove(event, span: span, commit: commit)
    }

    override func save(_ reminder: EKReminder, commit: Bool) throws {
        defer { commitCount &+= 1 }
        try super.save(reminder, commit: commit)
    }

    override func remove(_ reminder: EKReminder, commit: Bool) throws {
        defer { commitCount &+= 1 }
        try super.remove(reminder, commit: commit)
    }

    override func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        defer { commitCount &+= 1 }
        try super.saveCalendar(calendar, commit: commit)
    }

    override func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        defer { commitCount &+= 1 }
        try super.removeCalendar(calendar, commit: commit)
    }

    override func commit() throws {
        defer { commitCount &+= 1 }
        try super.commit()
    }
}
