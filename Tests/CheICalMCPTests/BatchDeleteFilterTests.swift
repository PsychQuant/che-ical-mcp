import XCTest
@testable import CheICalMCP

/// #33: pins the `onlyCompleted` destructive contract that
/// `EventKitManager.deleteRemindersBatch` enforces (#28 F1). The guard is
/// extracted into `BatchDeleteFilter.shouldSkipUncompleted` so it has a
/// unit-test-falsifiable surface — the previous inline form was reachable
/// only through a real `EKEventStore` (TCC required), leaving the destructive
/// rule untested.
///
/// The 4-row truth table below is the only authoritative spec of the rule:
///
/// | onlyCompleted | isCompleted | shouldSkip? |
/// | ------------- | ----------- | ----------- |
/// | true          | true        | false       |  ← legitimate delete
/// | true          | false       | true        |  ← #28 F1 protected case
/// | false         | true        | false       |  ← permissive mode
/// | false         | false       | false       |  ← permissive mode
final class BatchDeleteFilterTests: XCTestCase {

    func testSkipUncompletedReminderInOnlyCompletedMode() {
        XCTAssertTrue(
            BatchDeleteFilter.shouldSkipUncompleted(isCompleted: false, onlyCompleted: true),
            "#28 F1 protected case: caller asked for completed-only, reminder is un-completed → MUST skip"
        )
    }

    func testKeepCompletedReminderInOnlyCompletedMode() {
        XCTAssertFalse(
            BatchDeleteFilter.shouldSkipUncompleted(isCompleted: true, onlyCompleted: true),
            "Legitimate delete: caller asked for completed-only, reminder is completed → proceed"
        )
    }

    func testKeepUncompletedReminderInPermissiveMode() {
        XCTAssertFalse(
            BatchDeleteFilter.shouldSkipUncompleted(isCompleted: false, onlyCompleted: false),
            "Permissive mode (e.g. delete_reminders_batch direct): un-completed → still proceed"
        )
    }

    func testKeepCompletedReminderInPermissiveMode() {
        XCTAssertFalse(
            BatchDeleteFilter.shouldSkipUncompleted(isCompleted: true, onlyCompleted: false),
            "Permissive mode: completed → proceed"
        )
    }

    // Note: the wire-visible string `"Reminder is no longer completed"` is
    // emitted by `EventKitManager.deleteRemindersBatch` after this filter
    // returns true, NOT by BatchDeleteFilter itself. That contract is pinned
    // by `CleanupHandlerTests` integration tests via the response shape.
    // We deliberately don't add a self-comparing "message constant" test
    // here — those would be verify theater (compare a literal to itself).
}
