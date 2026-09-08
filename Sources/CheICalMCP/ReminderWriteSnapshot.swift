import EventKit

/// Handler-facing write results contain values only, never a mutable EKReminder.
struct ReminderWriteSnapshot: Sendable {
    let calendarItemIdentifier: String
    let title: String?
    let notes: String?

    init(id: String, title: String?, notes: String?) {
        calendarItemIdentifier = id
        self.title = title
        self.notes = notes
    }

    init(from reminder: EKReminder) {
        calendarItemIdentifier = reminder.calendarItemIdentifier
        title = reminder.title
        notes = reminder.notes
    }
}
