import XCTest
import MCP
@testable import CheICalMCP

/// #190 — all_day + timezone must be rejected, not silently degraded to a timed
/// event. The conflict cases fail at the handler guard before any store call (CI-safe).
final class AllDayTimezoneConflictTests: XCTestCase {

    private func errorText(_ result: CallTool.Result) -> String {
        guard case let .text(text, _, _)? = result.content.first else { return "" }
        return text
    }

    func testCreateEventRejectsAllDayWithTimezone() async throws {
        let server = try await TestServer.make()
        let result = await server.handleToolCallForTesting(
            name: "create_event",
            arguments: [
                "title": .string("t"),
                "start_time": .string("2026-09-21"),
                "end_time": .string("2026-09-22"),
                "all_day": .bool(true),
                "timezone": .string("America/Los_Angeles"),
                "calendar_name": .string("Work")
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(errorText(result).contains("all-day") || errorText(result).contains("all_day"),
                      "got: \(errorText(result))")
    }

    func testBatchItemRejectsAllDayWithTimezoneWithoutAbortingSiblings() async throws {
        let server = try await TestServer.make()
        // R2 hardening: one violating item + one legal sibling. The sibling's fate
        // differs by environment (CI: access-gate failure; local: calendar-not-found
        // or created) but in EVERY environment it must get its OWN result entry whose
        // error (if any) is NOT the all-day guard — proving the guard is per-item,
        // not a batch abort.
        let result = await server.handleToolCallForTesting(
            name: "create_events_batch",
            arguments: [
                "events": .array([
                    .object([
                        "title": .string("violating"),
                        "start_time": .string("2026-09-21"),
                        "end_time": .string("2026-09-22"),
                        "all_day": .bool(true),
                        "timezone": .string("America/Los_Angeles"),
                        "calendar_name": .string("IDD-190-no-such-calendar")
                    ]),
                    .object([
                        "title": .string("legal-sibling"),
                        "start_time": .string("2026-09-23T09:00:00"),
                        "end_time": .string("2026-09-23T10:00:00"),
                        "calendar_name": .string("IDD-190-no-such-calendar")
                    ])
                ])
            ]
        )
        let text = errorText(result)
        XCTAssertTrue(text.contains("\"total\" : 2") || text.contains("\"total\": 2"),
                      "both items must be processed, got: \(text)")
        XCTAssertTrue(text.contains("floating"),
                      "violating item's error must be the all-day guard, got: \(text)")
        // The sibling reached past the guard: its index-1 entry exists and its error,
        // whatever the environment produced, is not the guard message (only one
        // occurrence of the guard text in the whole envelope).
        XCTAssertEqual(text.components(separatedBy: "floating").count - 1, 1,
                       "guard must fire exactly once (violating item only), got: \(text)")
        XCTAssertTrue(text.contains("\"index\" : 1") || text.contains("\"index\": 1"),
                      "legal sibling must have its own result entry, got: \(text)")
    }

    func testUpdateEventRejectsAllDayWithTimezone() async throws {
        let server = try await TestServer.make()
        let result = await server.handleToolCallForTesting(
            name: "update_event",
            arguments: [
                "event_id": .string("x"),
                "all_day": .bool(true),
                "timezone": .string("Asia/Tokyo")
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(errorText(result).contains("all-day") || errorText(result).contains("all_day"))
    }

    /// all_day without timezone stays legal (the #186 control group) — must not
    /// hit the new guard (CI fails later at the EventKit access gate instead).
    func testAllDayWithoutTimezoneNotBlocked() async throws {
        let probe = DispatchProbe()
        let server = try await TestServer.make(filler: probe)
        let result = await server.handleToolCallForTesting(
            name: "create_event",
            arguments: [
                "title": .string("t"),
                "start_time": .string("2026-09-21"),
                "end_time": .string("2026-09-22"),
                "all_day": .bool(true),
                "calendar_name": .string("Work")
            ]
        )
        // R2 hardening: not-the-guard AND it reached the store layer, never the #190 conflict
        // guard. #600: the store layer is the event-write source, here a probe; before #600 it was
        // the live manager, which on a host with access looked the calendar up in the real store.
        let text = errorText(result)
        XCTAssertFalse(text.contains("floating"),
                       "pure all-day must not trip the conflict guard, got: \(text)")
        let calls = await probe.calls
        XCTAssertEqual(calls, ["createEventValue"],
                       "pure all-day must reach the event-write source, got: \(text)")
    }
}
