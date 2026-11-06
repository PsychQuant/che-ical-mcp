import CheICalMCPObjC
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
/// The check holds only while `calendarItem(withIdentifier:)` returns the reminder. That was
/// checked on device with Calendar and Reminders access both granted, on iCloud, with reminder ids
/// as the reminder tools return them. Without Reminders access it may return nil for a reminder's
/// id, so the lookup itself runs in `CheICalEventWithIdentifier` (#288), which catches the raise in
/// the Objective-C frame that made the call. Any raise is a failed lookup, thrown where it happened
/// as `EventKitError.eventLookupFailed`: the event may still exist, so it is never read as a missing
/// one. `calendarItem(withIdentifier:)` is not wrapped: if it raises, the process still ends (#293).
///
/// Measured with the check switched off in a local build, release, arm64, one stdio process, iCloud,
/// 2026-11-06: 1002 calls with a reminder's id raised once each and answered that the lookup failed;
/// the undo history survived and undo worked; later saves, and a read and a write of that reminder,
/// worked; nothing hung. Each raise leaks about 6 KB (flat with the same calls that do not raise):
/// objects in the EventKit frames the exception unwinds, which cannot be freed from here. Not run:
/// the x86_64 slice, and with Reminders access actually denied (release gate in
/// `.claude/rules/mcp-binary-version-testing.md`, and #382). The store is not refreshed here
/// (`freshEvent` refreshes first; the freshness of the other callers is #271).
///
/// Not `calendarItem(withIdentifier:) as? EKEvent`: the ids this server hands out for events are
/// `eventIdentifier`s, for which that lookup returned nil on device (one-off and recurring events
/// on iCloud, a one-off event on Google; it returns the event for its `calendarItemIdentifier`),
/// and `event(withIdentifier:)` is the one with the recurring-series semantics the callers rely
/// on. The other id lookups the server makes did not raise on device for the ids they were given:
/// `calendarItem(withIdentifier:)` (this check and the reminder tools) for event ids (iCloud and
/// Google), a reminder id and ids that no longer existed; `calendar(withIdentifier:)` (calendar
/// ids from the caller and from undo records) for a reminder id (nil) and ids that no longer
/// existed. Neither was tried with every kind of id, or on other account types. #293 (iCloud,
/// 2026-11-06, every call through a tool in its own process) added empty, blank and very long
/// strings, non-UUID text, NUL bytes and `/RID=` forms for all three kinds of id: none raised, and
/// neither did the other calls that take caller input (dates from year 1 to 9999 saved and read,
/// recurrence, locations, colors). That covers the inputs on #293, not every input.
enum EventLookup {
    /// The resolver behind closures (the closure-seam variant, #182), so the order is tested
    /// without a saved reminder.
    static func event(identifier: String, calendarItem: (String) -> EKCalendarItem?,
                      event: (String) throws -> EKEvent?) rethrows -> EKEvent? {
        guard !identifier.isEmpty, !(calendarItem(identifier) is EKReminder) else { return nil }
        return try event(identifier)
    }

    /// The resolver asking `store` for both lookups; tested with a fake store and with a store
    /// that raises from Objective-C. Throws `EventKitError.eventLookupFailed` when the lookup raised.
    static func event(identifier: String, in store: some EventLookupSource) throws -> EKEvent? {
        try event(identifier: identifier, calendarItem: { store.calendarItem(withIdentifier: $0) },
                  event: { try store.eventCatchingRaise(identifier: $0) })
    }
}

/// The two `EKEventStore` lookups `EventLookup` uses (#260, narrow seam per CLAUDE.md).
protocol EventLookupSource {
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem?
    /// Throws `EventKitError.eventLookupFailed` when the lookup raised.
    func eventCatchingRaise(identifier: String) throws -> EKEvent?
}

extension EKEventStore: EventLookupSource {
    /// #288: through the Objective-C function, so a raise stops in its frame and no Swift frame is
    /// unwound. Any raise is a failed lookup, whatever its name: the one seen, `NSUnknownKeyException`
    /// for a reminder's id, is a general KVC exception, and this runs when the kind check could not
    /// tell what the id is, so a raise says nothing about whether an event exists. It is thrown
    /// here, not passed on as nil, so no caller can read it as a missing event. Only the name goes
    /// to stderr (#37); the reason can quote the caller's input.
    func eventCatchingRaise(identifier: String) throws -> EKEvent? {
        var exceptionName: NSString?
        let event = CheICalEventWithIdentifier(self, identifier, &exceptionName)
        guard let exceptionName else { return event }
        let name = EventKitErrorSanitizer.escapeForStderr(exceptionName as String)
        FileHandle.standardError.write(Data("event lookup raised \(name)\n".utf8))
        throw EventKitError.eventLookupFailed(identifier: identifier)
    }
}

extension EventKitManager {
    /// The event stored under `id` through `EventLookup`, as `event(withIdentifier:)` returns it
    /// (not refreshed). Every event lookup by identifier goes through here.
    func storedEvent(id: String) throws -> EKEvent? {
        try EventLookup.event(identifier: id, in: eventStore)
    }
}
