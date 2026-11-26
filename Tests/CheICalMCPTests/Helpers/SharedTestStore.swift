import EventKit
@testable import CheICalMCP

/// The one `EKEventStore` the test target builds (#283). Tests that only need an in-memory
/// `EKEvent`, `EKReminder` or `EKCalendar` (never fetched, saved or removed) build it on this store.
///
/// Why one: EventKit refuses to create stores past a per-process limit ("too many EKEventStore
/// instances in this process", surfacing as `error_ekcaderrordomain_1021`), and the limit is not
/// documented. A `let store = EKEventStore()` instance property builds one store per test case
/// when XCTest assembles the suite, before any test runs, so the count grows with every test
/// method. Past the limit, a test that reaches the real store (`EventKitManager.shared`) fails
/// with 1021 instead of the error it asserts, in a class unrelated to the cause (seen on PR #282's
/// branch, 2026-10-07). `SharedTestStoreTests` fails when any other test file builds a store.
///
/// It is the server's `CountingEventStore` (#328, PR #413 round 2), so a test of the commit count
/// uses it too instead of building a second store; it behaves as an `EKEventStore` otherwise.
enum SharedTestStore {
    static let store = CountingEventStore()
}
