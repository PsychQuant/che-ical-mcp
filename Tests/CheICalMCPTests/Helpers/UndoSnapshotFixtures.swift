import EventKit
@testable import CheICalMCP

/// #236: undo records now carry the post-write state, so tests that only need *a* record build
/// one from an in-memory item here (never fetched or saved, so no TCC prompt).
enum UndoSnapshotFixtures {
    static func event(title: String = "Event") -> EventSnapshot {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = title
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        return EventSnapshot(from: event)
    }

    static func reminder(title: String = "Reminder") -> ReminderSnapshot {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        reminder.title = title
        return ReminderSnapshot(from: reminder)
    }
}
