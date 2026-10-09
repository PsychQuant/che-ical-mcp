import EventKit
@testable import CheICalMCP

/// #236: undo records now carry the post-write state, so tests that only need *a* record build
/// one from an in-memory item here (never fetched or saved, so no TCC prompt). Every fixture is
/// built on one shared store: a store per call grew with the tests, and too many stores in one
/// process make EventKit refuse the real one other tests use (#283; PR #282 round 6, findings 7, 17).
enum UndoSnapshotFixtures {
    private static let store = EKEventStore()

    /// `calendarTitle` names the event's calendar; `weeklyOccurrences` makes it a weekly series of
    /// that many, whose delete-undo recreates it from its rules (#278).
    static func event(title: String = "Event", calendarTitle: String? = nil, weeklyOccurrences: Int? = nil) -> EventSnapshot {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        if let calendarTitle { event.calendar.title = calendarTitle }
        event.title = title
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        if let weeklyOccurrences {
            event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                                     end: EKRecurrenceEnd(occurrenceCount: weeklyOccurrences)))
        }
        return EventSnapshot(from: event)
    }

    static func reminder(title: String = "Reminder") -> ReminderSnapshot {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        reminder.title = title
        return ReminderSnapshot(from: reminder)
    }
}
