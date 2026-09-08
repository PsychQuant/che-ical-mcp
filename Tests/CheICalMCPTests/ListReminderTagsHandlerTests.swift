import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #203 — `list_reminder_tags` must read through the `ReminderReadSource` seam
/// like `list_reminders` / `search_reminders`, so no raw `EKReminder` escapes the
/// manager actor. The fake records the `completed` filter the handler asks for.
private actor RecordingReminderReadFake: ReminderReadSource {
    let values: [ReminderReadSnapshot]
    struct Call: Equatable { let completed: Bool?; let calendarName: String?; let calendarSource: String? }
    private(set) var calls: [Call] = []
    init(_ values: [ReminderReadSnapshot]) { self.values = values }
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] {
        calls.append(Call(completed: completed, calendarName: calendarName, calendarSource: calendarSource)); return values
    }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] { values }
}

final class ListReminderTagsHandlerTests: XCTestCase {
    private func records() -> [ReminderReadSnapshot] {
        // Tags live on a trailing line made only of #hashtags (extractTags); an
        // inline "#" in prose is not a tag, so "d" contributes nothing.
        [ReminderReadSnapshot(id: "a", title: "A", notes: "Buy milk\n#home #errand"),
         ReminderReadSnapshot(id: "b", title: "B", notes: "Ship release\n#work"),
         ReminderReadSnapshot(id: "c", title: "C", notes: "Call mom\n#home"),   // the fake ignores filters; completion is inert here
         ReminderReadSnapshot(id: "d", title: "D", notes: "Ticket #42 is not a tag")]
    }

    func testTagsAreCountedFromSnapshotNotesAndSortedByCountThenName() async throws {
        let fake = RecordingReminderReadFake(records())
        let server = try await CheICalMCPServer(reminderReadSource: fake)
        let raw = try await server.executeToolCall(name: "list_reminder_tags", arguments: [:])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(json["total_reminders_scanned"] as? Int, 4)
        XCTAssertEqual(json["total_tags"] as? Int, 3)
        let tags = try XCTUnwrap(json["tags"] as? [[String: Any]])
        XCTAssertEqual(tags.map { $0["tag"] as? String }, ["home", "errand", "work"])
        XCTAssertEqual(tags.map { $0["count"] as? Int }, [2, 1, 1])
    }

    func testIncludeCompletedMapsToTheSeamFilterAndIsEchoed() async throws {
        let fake = RecordingReminderReadFake(records())
        let server = try await CheICalMCPServer(reminderReadSource: fake)
        let raw1 = try await server.executeToolCall(name: "list_reminder_tags", arguments: [:])
        let raw2 = try await server.executeToolCall(name: "list_reminder_tags", arguments: ["include_completed": .bool(true)])
        let raw3 = try await server.executeToolCall(name: "list_reminder_tags", arguments: ["include_completed": .bool(false)])
        let completed = await fake.calls.map(\.completed)
        // Whole-array equality: a wrong count fails the test instead of trapping on an index.
        XCTAssertEqual(completed, [false, nil, false], "default and explicit false exclude completed; true asks the seam for every reminder")
        for (raw, expected) in [(raw1, false), (raw2, true), (raw3, false)] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            XCTAssertEqual(json["include_completed"] as? Bool, expected)
        }
    }

    func testCalendarScopeIsForwardedToTheSeamVerbatim() async throws {
        let fake = RecordingReminderReadFake(records())
        let server = try await CheICalMCPServer(reminderReadSource: fake)
        _ = try await server.executeToolCall(name: "list_reminder_tags",
                                             arguments: ["calendar_name": .string("Work"), "calendar_source": .string("iCloud")])
        let calls = await fake.calls
        XCTAssertEqual(calls, [.init(completed: false, calendarName: "Work", calendarSource: "iCloud")])
    }

    func testScopeInvariantsAreEnforcedBeforeAnyRead() async throws {
        // #29 scope rules shared with list_reminders: a source without a name is
        // rejected, and a non-string name is rejected — both before the seam is asked.
        for args in [["calendar_source": Value.string("iCloud")], ["calendar_name": .int(1)]] {
            let fake = RecordingReminderReadFake(records())
            let server = try await CheICalMCPServer(reminderReadSource: fake)
            do {
                _ = try await server.executeToolCall(name: "list_reminder_tags", arguments: args)
                XCTFail("expected rejection for \(args)")
            } catch is ToolError {
                // expected
            }
            let calls = await fake.calls
            XCTAssertTrue(calls.isEmpty, "rejected before any read: \(args)")
        }
    }
}
