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
    func testEveryToolHasAnExplicitAnnotationPolicy() {
        let reads: Set<String> = ["list_calendars", "list_events", "undo_history", "list_reminders", "search_reminders", "search_events", "list_events_quick", "check_conflicts", "find_duplicate_events", "list_reminder_tags"]
        let additive: Set<String> = ["create_calendar", "create_event", "create_reminder", "create_events_batch", "create_reminders_batch"]
        let destructive: Set<String> = ["delete_calendar", "update_calendar", "update_event", "delete_event", "undo", "redo", "update_reminder", "complete_reminder", "delete_reminder", "copy_event", "move_events_batch", "delete_events_batch", "delete_reminders_batch", "cleanup_completed_reminders"]
        let tools = CheICalMCPServer.defineTools()
        XCTAssertEqual(Set(tools.map(\.name)), reads.union(additive).union(destructive), "New tools need an explicit policy")
        for tool in tools {
            XCTAssertEqual(tool.annotations.readOnlyHint, reads.contains(tool.name), tool.name)
            XCTAssertEqual(tool.annotations.destructiveHint, destructive.contains(tool.name), tool.name)
        }
    }

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
