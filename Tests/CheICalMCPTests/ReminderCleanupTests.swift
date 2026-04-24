import XCTest
import MCP
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
                message.contains("calendar_source requires"),
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

    // R2-F3: the Round 1 guard accepted empty-string `calendar_name`, which
    // only avoided disaster because `findCalendars` threw "not found"
    // downstream — coincidental, not load-bearing. These tests pin the
    // stricter invariant added in Round 2.

    func testRejectsEmptyNameWithSource() {
        XCTAssertThrowsError(
            try ReminderCleanup.rejectSourceWithoutName(name: "", source: "iCloud")
        ) { error in
            guard case ToolError.invalidParameter(let message) = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("non-empty calendar_name"),
                "Message should state the non-empty requirement, got: \(message)"
            )
        }
    }

    func testRejectsWhitespaceNameWithSource() {
        // Trimmed whitespace is equivalent to empty — must not slip through.
        XCTAssertThrowsError(
            try ReminderCleanup.rejectSourceWithoutName(name: "   ", source: "iCloud")
        )
    }

    // MARK: - requireStringIfPresent (R2-F1 Codex finding)

    func testRequireStringIfPresentReturnsNilWhenAbsent() throws {
        let args: [String: Value] = [:]
        let result = try ReminderCleanup.requireStringIfPresent(args, key: "calendar_source")
        XCTAssertNil(result)
    }

    func testRequireStringIfPresentReturnsString() throws {
        let args: [String: Value] = ["calendar_source": .string("iCloud")]
        let result = try ReminderCleanup.requireStringIfPresent(args, key: "calendar_source")
        XCTAssertEqual(result, "iCloud")
    }

    func testRequireStringIfPresentRejectsInt() {
        // R2-F1 attack vector: {"calendar_source": 123} previously collapsed
        // to nil via .stringValue and bypassed the F1 guard downstream,
        // widening the destructive tool to all accounts. Must now throw.
        let args: [String: Value] = ["calendar_source": .int(123)]
        XCTAssertThrowsError(
            try ReminderCleanup.requireStringIfPresent(args, key: "calendar_source")
        ) { error in
            guard case ToolError.invalidParameter(let message) = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("calendar_source"))
        }
    }

    func testRequireStringIfPresentRejectsBool() {
        let args: [String: Value] = ["calendar_name": .bool(true)]
        XCTAssertThrowsError(
            try ReminderCleanup.requireStringIfPresent(args, key: "calendar_name")
        )
    }

    func testRequireStringIfPresentRejectsArray() {
        let args: [String: Value] = ["calendar_name": .array([.string("x")])]
        XCTAssertThrowsError(
            try ReminderCleanup.requireStringIfPresent(args, key: "calendar_name")
        )
    }

    // R2-F2 invariant: the response's `total` field equals the deduped count.
    // Pinned via the stdlib semantic the handler relies on.

    func testDedupedCountIsAuthoritativeForTotal() {
        let rawIdentifiers = ["a", "a", "b", "c", "c", "c"]
        let unique = Array(Set(rawIdentifiers))
        // total should reflect distinct reminders, not the raw list — the
        // response's arithmetic must balance.
        XCTAssertEqual(unique.count, 3,
            "total must use Array(Set(...)).count so total + failures equals the real blast radius"
        )
        XCTAssertNotEqual(unique.count, rawIdentifiers.count,
            "sanity check: dedupe actually changed the count in this test case"
        )
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

    // MARK: - #28 binding-mode reminder_ids parsing invariants
    //
    // The handler parses reminder_ids inline. These tests pin the stdlib
    // invariants the handler composes: order-preserving dedupe, trimmed
    // emptiness semantics. Full handler integration tests belong in #31.

    func testOrderedDedupePreservesFirstOccurrence() {
        // Handler uses `Set.insert(_:).inserted` to build a dedupe'd array
        // that preserves first-occurrence order — so the dry-run preview is
        // read in the same order execute will operate on.
        var seen = Set<String>()
        var out: [String] = []
        for id in ["c", "a", "b", "a", "c", "d"] {
            if seen.insert(id).inserted { out.append(id) }
        }
        XCTAssertEqual(out, ["c", "a", "b", "d"],
            "dedupe must preserve first-occurrence order — callers read dry-run preview in order")
    }

    func testEmptyStringTrimmedIsEmpty() {
        XCTAssertTrue("".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue("   ".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue("\t\n".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse("x".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
