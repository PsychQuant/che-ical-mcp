import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

private actor ReminderReadFake: ReminderReadSource {
    let values: [ReminderReadSnapshot]
    init(_ values: [ReminderReadSnapshot]) { self.values = values }
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] { values }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] { values }
}

final class ReminderRecurrenceHandlerTests: XCTestCase {
    /// "repeat" is `hasRecurrence: true` with `rules == nil` — a state
    /// `ReminderReadSnapshot(from:)` cannot produce (EventKit's `recurrenceRules`
    /// is nil only when `hasRecurrenceRules` is false). It pins the serializer's
    /// documented `null` contract defensively (#203); the production-reachable
    /// multi-rule shape is covered by `testMultiRuleReminderSerializesEveryRuleThroughListAndSearch`.
    private func records() -> [ReminderReadSnapshot] {
        [ReminderReadSnapshot(id: "one", title: "Once", hasRecurrence: false),
         ReminderReadSnapshot(id: "repeat", title: "Repeat", hasRecurrence: true)]
    }

    func testListPreservesPreLimitCountAndAddsMetadata() async throws {
        let server = try await CheICalMCPServer(reminderReadSource: ReminderReadFake(records()))
        let raw = try await server.executeToolCall(name: "list_reminders", arguments: ["limit": .int(1), "sort": .string("title")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(json["reminder_count"] as? Int, 2)
        let items = try XCTUnwrap(json["reminders"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["has_recurrence"] as? Bool, false)
        XCTAssertEqual((items[0]["recurrence_rules"] as? [Any])?.count, 0)
        XCTAssertTrue(items[0]["due"] is NSNull)
        XCTAssertNotNil(json["metadata"])
        XCTAssertEqual(items[0]["is_completed"] as? Bool, false)
    }

    func testSearchUsesSameMetadataWithoutAddingListOnlyFields() async throws {
        let server = try await CheICalMCPServer(reminderReadSource: ReminderReadFake(records()))
        let raw = try await server.executeToolCall(name: "search_reminders", arguments: ["keyword": .string("anything")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let items = try XCTUnwrap(json["reminders"] as? [[String: Any]])
        XCTAssertEqual(json["reminder_count"] as? Int, 2)
        XCTAssertEqual(items[1]["has_recurrence"] as? Bool, true)
        XCTAssertTrue(items[1]["recurrence_rules"] is NSNull)   // defensive contract, not a reachable state (see records())
        XCTAssertNil(items[1]["creation_date"])
        XCTAssertNil(items[1]["is_overdue"])
        XCTAssertEqual(json["match_mode"] as? String, "any")
    }

    // #203: no handler test drove more than one rule through list/search.
    func testMultiRuleReminderSerializesEveryRuleThroughListAndSearch() async throws {
        let weekly = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        let monthly = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .monthly, interval: 2, end: nil))
        let twoRules = ReminderReadSnapshot(id: "two", title: "Two rules", hasRecurrence: true, rules: [weekly, monthly])
        let server = try await CheICalMCPServer(reminderReadSource: ReminderReadFake([twoRules]))
        for (tool, args) in [("list_reminders", [String: Value]()), ("search_reminders", ["keyword": .string("Two")])] {
            let raw = try await server.executeToolCall(name: tool, arguments: args)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let item = try XCTUnwrap((json["reminders"] as? [[String: Any]])?.first, tool)
            let rules = try XCTUnwrap(item["recurrence_rules"] as? [[String: Any]], tool)
            XCTAssertEqual(rules.count, 2, tool)
            XCTAssertEqual(rules.map { $0["frequency"] as? String }, ["weekly", "monthly"], tool)
            XCTAssertEqual(rules.map { $0["interval"] as? Int }, [1, 2], tool)
        }
    }
}
