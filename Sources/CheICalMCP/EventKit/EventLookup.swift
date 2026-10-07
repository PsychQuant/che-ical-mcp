import EventKit
import Foundation

/// #260: the one place the server resolves an event by identifier. The caller's `event_id` can
/// be a reminder's id, and `EKEventStore.event(withIdentifier:)` given one raises
/// `NSUnknownKeyException` inside the call (it builds an event over the reminder's record; seen
/// on device), an Objective-C exception that Swift's `catch` does not see: the process aborts,
/// with its undo history and whatever a batch had not recorded yet. So the item's kind is checked
/// first with `calendarItem(withIdentifier:)`, the lookup every reminder tool already makes, and an
/// id that this lookup resolves to a reminder is not found without the event lookup running.
///
/// Known limit: the check holds only while `calendarItem(withIdentifier:)` returns the reminder.
/// That was checked on device with Calendar and Reminders access both granted, on iCloud, with
/// reminder ids as the reminder tools return them. Without Reminders access it may return nil for
/// a reminder's id, and `event(withIdentifier:)` would then still run; a reminder's id normally
/// comes from this server's reminder tools, which need that access. The store is not refreshed
/// here (`freshEvent` refreshes first; the freshness of the other callers is #271).
///
/// Not `calendarItem(withIdentifier:) as? EKEvent`: the ids this server hands out for events are
/// `eventIdentifier`s, which that lookup does not know (nil on device, for an event on iCloud and
/// one on Google), and `event(withIdentifier:)` is the one with the recurring-series semantics the
/// callers rely on. The other id lookups the server makes, `calendarItem(withIdentifier:)` (this
/// check and the reminder tools) and `calendar(withIdentifier:)`, are not known to raise; on device
/// `calendarItem(withIdentifier:)` was given event ids (iCloud and Google), a reminder id and ids
/// that no longer existed without raising.
enum EventLookup {
    /// The resolver behind closures (the closure-seam variant, #182), so the order is tested
    /// without a saved reminder.
    static func event(identifier: String, calendarItem: (String) -> EKCalendarItem?,
                      event: (String) -> EKEvent?) -> EKEvent? {
        guard !identifier.isEmpty, !(calendarItem(identifier) is EKReminder) else { return nil }
        return event(identifier)
    }

    /// The resolver asking `store` for both lookups; tested with a fake store.
    static func event(identifier: String, in store: some EventLookupSource) -> EKEvent? {
        event(identifier: identifier, calendarItem: { store.calendarItem(withIdentifier: $0) },
              event: { store.event(withIdentifier: $0) })
    }
}

/// The two `EKEventStore` lookups `EventLookup` uses (#260, narrow seam per CLAUDE.md).
protocol EventLookupSource {
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem?
    func event(withIdentifier identifier: String) -> EKEvent?
}

extension EKEventStore: EventLookupSource {}

extension EventKitManager {
    /// The event stored under `id` through `EventLookup`, as `event(withIdentifier:)` returns it
    /// (not refreshed). Every event lookup by identifier goes through here.
    func storedEvent(id: String) -> EKEvent? {
        EventLookup.event(identifier: id, in: eventStore)
    }
}
