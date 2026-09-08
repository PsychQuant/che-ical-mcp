import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #207 — every boolean tool argument follows the #205 contract: a string or number
/// is rejected with a key-named error before any read or write; omitted or JSON
/// null keeps the default. Table-driven over the twelve sites #205 left out.
private actor CountingReadFake: ReminderReadSource {
    private(set) var completedFilters: [Bool?] = []
    var calls: Int { completedFilters.count }
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] {
        completedFilters.append(completed); return []
    }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] {
        completedFilters.append(completed); return []
    }
}

final class BooleanArgumentContractTests: XCTestCase {
    /// (tool, boolean key, the other arguments needed so the boolean check is the first thing that can fail)
    private let sites: [(tool: String, key: String, extra: [String: Value])] = [
        ("create_event", "all_day", ["title": .string("T"), "start_time": .string("2026-09-10T10:00:00+08:00"), "end_time": .string("2026-09-10T11:00:00+08:00")]),
        ("update_event", "all_day", ["event_id": .string("e")]),
        ("update_event", "clear_recurrence", ["event_id": .string("e")]),
        ("update_event", "clear_timezone", ["event_id": .string("e")]),
        ("update_reminder", "clear_tags", ["reminder_id": .string("r")]),
        ("update_reminder", "clear_due_date", ["reminder_id": .string("r")]),
        ("update_reminder", "clear_location_trigger", ["reminder_id": .string("r")]),
        ("list_reminder_tags", "include_completed", [:]),
        ("cleanup_completed_reminders", "dry_run", [:]),
        ("copy_event", "delete_original", ["event_id": .string("e"), "target_calendar": .string("Work")]),
        ("delete_events_batch", "dry_run", [:]),
    ]
    private let badValues: [Value] = [.string("true"), .string("false"), .int(1), .double(0)]

    private func server(_ read: CountingReadFake) async throws -> CheICalMCPServer {
        try await CheICalMCPServer(reminderCleanupSource: FakeEventKitManager(), reminderReadSource: read)
    }

    func testNonBooleanValuesAreRejectedByKeyBeforeAnyReadOrWrite() async throws {
        continueAfterFailure = false
        for site in sites {
            for bad in badValues {
                let read = CountingReadFake()
                let server = try await server(read)
                var args = site.extra; args[site.key] = bad
                do {
                    _ = try await server.executeToolCall(name: site.tool, arguments: args)
                    XCTFail("\(site.tool).\(site.key) must reject \(bad)")
                } catch let error as ToolError {
                    XCTAssertTrue("\(error)".contains("\(site.key) must be a boolean (true or false)"), "\(site.tool).\(site.key): \(error)")
                }
                let calls = await read.calls
                XCTAssertEqual(calls, 0, "\(site.tool).\(site.key): rejected before any read")
            }
        }
    }

    func testOmittedAndNullKeepTheDefaultOnTheSeamBackedTool() async throws {
        let read = CountingReadFake()
        let server = try await server(read)
        _ = try await server.executeToolCall(name: "list_reminder_tags", arguments: [:])
        _ = try await server.executeToolCall(name: "list_reminder_tags", arguments: ["include_completed": .null])
        _ = try await server.executeToolCall(name: "list_reminder_tags", arguments: ["include_completed": .bool(true)])
        let filters = await read.completedFilters
        XCTAssertEqual(filters, [false, false, nil], "omitted and null keep the default (exclude completed); true asks for every reminder")
    }

    func testBatchItemAllDayIsRejectedPerItemWithItsIndex() async throws {
        let read = CountingReadFake()
        let server = try await server(read)
        let item: Value = .object(["title": .string("T"), "start_time": .string("2026-09-10T10:00:00+08:00"),
                                   "end_time": .string("2026-09-10T11:00:00+08:00"), "all_day": .string("yes")])
        let raw = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array([item])])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let results = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["index"] as? Int, 0)
        XCTAssertEqual(results[0]["success"] as? Bool, false)
        XCTAssertTrue(((results[0]["error"] as? String) ?? "").contains("all_day must be a boolean"), "\(results[0])")
    }
}
