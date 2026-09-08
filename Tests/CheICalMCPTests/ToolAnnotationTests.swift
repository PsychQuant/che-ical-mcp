import MCP
import XCTest
@testable import CheICalMCP

/// #202 — tools that consume state irreversibly must advertise it.
///
/// `destructiveHint: false` is a positive claim ("only additive, non-destructive
/// updates"). Completing a recurring reminder advances the series in place and
/// files the finished occurrence as a separate completed record; once the
/// identifier has rolled over, undo refuses and discards the entry (#204). A
/// client that auto-approves non-destructive tools must therefore be told the
/// truth here, exactly as it is for `delete_reminder`.
final class ToolAnnotationTests: XCTestCase {
    private func tool(named name: String) throws -> Tool {
        try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == name },
                      "tool \(name) is not declared by defineTools()")
    }

    func testCompleteReminderIsAnnotatedDestructive() throws {
        XCTAssertEqual(try tool(named: "complete_reminder").annotations.destructiveHint, true,
                       "complete_reminder consumes an occurrence irreversibly on recurring reminders")
    }

    func testCompleteReminderDescriptionExplainsTheDestructiveHint() throws {
        // The description is the only place a client sees *why* the hint is set;
        // pin the two together so one cannot drift without the other.
        let description = try tool(named: "complete_reminder").description ?? ""
        XCTAssertTrue(description.contains("Annotated destructive"), description)
        XCTAssertTrue(description.contains("tool-wide"), description)
    }

    func testDeleteReminderStaysAnnotatedDestructive() throws {
        XCTAssertEqual(try tool(named: "delete_reminder").annotations.destructiveHint, true)
    }
}
