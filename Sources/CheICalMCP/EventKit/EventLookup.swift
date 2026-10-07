import EventKit
import Foundation

/// #260: the one place the server resolves an event by identifier. The caller's `event_id` can
/// be a reminder's id, and `EKEventStore.event(withIdentifier:)` given one raises
/// `NSUnknownKeyException` (an event built over the reminder's record), an Objective-C exception
/// that Swift's `catch` does not see: the process aborts, with its undo history and whatever a
/// batch had not recorded yet. So the item's kind is checked first with
/// `calendarItem(withIdentifier:)`, the lookup every reminder tool already makes, and a reminder
/// is not found without the event lookup ever running.
///
/// Not `calendarItem(withIdentifier:) as? EKEvent`: the ids this server hands out for events are
/// `eventIdentifier`s, which that lookup usually does not know, and `event(withIdentifier:)` is
/// the one with the recurring-series semantics the callers rely on. Behind closures (the
/// closure-seam variant, #182) so the order is tested without a saved reminder.
enum EventLookup {
    static func event(identifier: String, calendarItem: (String) -> EKCalendarItem?,
                      event: (String) -> EKEvent?) -> EKEvent? {
        guard !identifier.isEmpty, !(calendarItem(identifier) is EKReminder) else { return nil }
        return event(identifier)
    }
}

extension EventKitManager {
    /// The event stored under `id` through `EventLookup`, as `event(withIdentifier:)` returns it
    /// (not refreshed). Every event lookup by identifier goes through here.
    func storedEvent(id: String) -> EKEvent? {
        let store = eventStore
        return EventLookup.event(identifier: id, calendarItem: { store.calendarItem(withIdentifier: $0) },
                                 event: { store.event(withIdentifier: $0) })
    }
}
