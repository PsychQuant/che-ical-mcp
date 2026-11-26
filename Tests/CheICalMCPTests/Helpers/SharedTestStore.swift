import EventKit
@testable import CheICalMCP

/// The one `EKEventStore` the test target builds for in-memory items (#283). Tests that only need an
/// in-memory `EKEvent`, `EKReminder` or `EKCalendar` (never fetched, saved or removed) build it on this
/// store.
///
/// Why one: EventKit refuses to create stores past a per-process limit ("too many EKEventStore
/// instances in this process", surfacing as `error_ekcaderrordomain_1021`), and the limit is not
/// documented. A `let store = EKEventStore()` instance property builds one store per test case
/// when XCTest assembles the suite, before any test runs, so the count grows with every test
/// method. Past the limit, a test that reaches the real store fails with 1021 instead of the error
/// it asserts, in a class unrelated to the cause (seen on PR #282's branch, 2026-10-07).
/// `SharedTestStoreTests` fails when any other test file builds a store.
///
/// #600 (PR #603 verify r2): it is a `GuardedTestStore`, whose every member that reads, writes,
/// commits or refreshes the store stops the test process (`LiveStoreGuard`) before calling
/// EventKit; building an item against it stays allowed. `counting` is the server's
/// `CountingEventStore` for the one test of its commit count, which must opt in to reach EventKit.
enum SharedTestStore {
    static let store = GuardedTestStore()

    /// #328: the commit-count test's store, made on first use. Using it stops the test process
    /// unless the test runs inside `LiveStoreGuard.allowingLiveStore`.
    static var counting: CountingEventStore {
        LiveStoreGuard.check("SharedTestStore.counting")
        return countingStore
    }
    private static let countingStore = CountingEventStore()
}

/// #600: an `EKEventStore` that stops the test process before any member that reads, writes,
/// commits or refreshes the store reaches EventKit (`LiveStoreGuardTests` pins the list). Items are
/// still built against it (`EKEvent(eventStore:)`, `EKCalendar(for:eventStore:)`).
final class GuardedTestStore: EKEventStore, @unchecked Sendable {
    override var sources: [EKSource] { LiveStoreGuard.check("GuardedTestStore.sources"); return super.sources }
    override func source(withIdentifier identifier: String) -> EKSource? {
        LiveStoreGuard.check("GuardedTestStore.source(withIdentifier:)"); return super.source(withIdentifier: identifier)
    }
    override func calendars(for entityType: EKEntityType) -> [EKCalendar] {
        LiveStoreGuard.check("GuardedTestStore.calendars(for:)"); return super.calendars(for: entityType)
    }
    override func calendar(withIdentifier identifier: String) -> EKCalendar? {
        LiveStoreGuard.check("GuardedTestStore.calendar(withIdentifier:)"); return super.calendar(withIdentifier: identifier)
    }
    override var defaultCalendarForNewEvents: EKCalendar? {
        LiveStoreGuard.check("GuardedTestStore.defaultCalendarForNewEvents"); return super.defaultCalendarForNewEvents
    }
    override func defaultCalendarForNewReminders() -> EKCalendar? {
        LiveStoreGuard.check("GuardedTestStore.defaultCalendarForNewReminders"); return super.defaultCalendarForNewReminders()
    }
    override func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        LiveStoreGuard.check("GuardedTestStore.saveCalendar"); try super.saveCalendar(calendar, commit: commit)
    }
    override func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        LiveStoreGuard.check("GuardedTestStore.removeCalendar"); try super.removeCalendar(calendar, commit: commit)
    }
    override func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
        LiveStoreGuard.check("GuardedTestStore.calendarItem(withIdentifier:)"); return super.calendarItem(withIdentifier: identifier)
    }
    override func calendarItems(withExternalIdentifier externalIdentifier: String) -> [EKCalendarItem] {
        LiveStoreGuard.check("GuardedTestStore.calendarItems(withExternalIdentifier:)")
        return super.calendarItems(withExternalIdentifier: externalIdentifier)
    }
    override func save(_ event: EKEvent, span: EKSpan) throws {
        LiveStoreGuard.check("GuardedTestStore.save(event)"); try super.save(event, span: span)
    }
    override func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        LiveStoreGuard.check("GuardedTestStore.save(event, commit)"); try super.save(event, span: span, commit: commit)
    }
    override func remove(_ event: EKEvent, span: EKSpan) throws {
        LiveStoreGuard.check("GuardedTestStore.remove(event)"); try super.remove(event, span: span)
    }
    override func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        LiveStoreGuard.check("GuardedTestStore.remove(event, commit)"); try super.remove(event, span: span, commit: commit)
    }
    override func event(withIdentifier identifier: String) -> EKEvent? {
        LiveStoreGuard.check("GuardedTestStore.event(withIdentifier:)"); return super.event(withIdentifier: identifier)
    }
    override func events(matching predicate: NSPredicate) -> [EKEvent] {
        LiveStoreGuard.check("GuardedTestStore.events(matching:)"); return super.events(matching: predicate)
    }
    override func enumerateEvents(matching predicate: NSPredicate, using block: @escaping EKEventSearchCallback) {
        LiveStoreGuard.check("GuardedTestStore.enumerateEvents(matching:using:)"); super.enumerateEvents(matching: predicate, using: block)
    }
    override func save(_ reminder: EKReminder, commit: Bool) throws {
        LiveStoreGuard.check("GuardedTestStore.save(reminder)"); try super.save(reminder, commit: commit)
    }
    override func remove(_ reminder: EKReminder, commit: Bool) throws {
        LiveStoreGuard.check("GuardedTestStore.remove(reminder)"); try super.remove(reminder, commit: commit)
    }
    override func fetchReminders(matching predicate: NSPredicate, completion: @escaping ([EKReminder]?) -> Void) -> Any {
        LiveStoreGuard.check("GuardedTestStore.fetchReminders(matching:)"); return super.fetchReminders(matching: predicate, completion: completion)
    }
    override func commit() throws { LiveStoreGuard.check("GuardedTestStore.commit"); try super.commit() }
    override func reset() { LiveStoreGuard.check("GuardedTestStore.reset"); super.reset() }
    override func refreshSourcesIfNecessary() {
        LiveStoreGuard.check("GuardedTestStore.refreshSourcesIfNecessary"); super.refreshSourcesIfNecessary()
    }
}
