import XCTest
@testable import CheICalMCP

/// Unit tests for the pure argument guards used by
/// `handleCleanupCompletedReminders`.
final class ReminderCleanupTests: XCTestCase {

    // MARK: - rejectSourceWithoutName

    func testAllowsBothNil() throws {
        // "Clean across all lists on all accounts" — legitimate usage.
        try ReminderCleanup.rejectSourceWithoutName(name: nil, source: nil)
    }

    func testAllowsNameOnly() throws {
        try ReminderCleanup.rejectSourceWithoutName(name: "Shopping", source: nil)
    }

    func testAllowsNameAndSource() throws {
        try ReminderCleanup.rejectSourceWithoutName(name: "Shopping", source: "iCloud")
    }

    func testRejectsSourceWithoutName() {
        // The destructive silent-failure case: user intends "clean iCloud
        // only" but listReminders silently discards calendar_source when
        // calendar_name is nil, widening to every account.
        XCTAssertThrowsError(
            try ReminderCleanup.rejectSourceWithoutName(name: nil, source: "iCloud")
        ) { error in
            guard case ToolError.invalidParameter(let message) = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("calendar_source requires calendar_name"),
                "Error message should explain the requirement, got: \(message)"
            )
        }
    }

    func testRejectsEmptyStringSourceWithoutName() {
        // Empty string is not nil — same silent-drop path in listReminders.
        XCTAssertThrowsError(
            try ReminderCleanup.rejectSourceWithoutName(name: nil, source: "")
        ) { error in
            guard case ToolError.invalidParameter = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
        }
    }

    // MARK: - Dedupe semantics pin (F2)
    //
    // Not testing production code directly — pinning the stdlib behavior
    // the handler relies on, so a future Swift-version change that altered
    // Set's semantics would surface as a test failure before it silently
    // broke cleanup.

    func testArrayFromSetDeduplicatesExactMatches() {
        let raw = ["a", "a", "b", "c", "b", "a"]
        let deduped = Array(Set(raw))
        XCTAssertEqual(
            Set(deduped),
            Set(["a", "b", "c"]),
            "Array(Set(...)) must dedupe — F2 relies on this to avoid deleted_count/deleted_ids inconsistency"
        )
        XCTAssertEqual(deduped.count, 3)
    }
}
