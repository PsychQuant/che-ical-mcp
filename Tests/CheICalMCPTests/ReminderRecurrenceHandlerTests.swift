import MCP
import XCTest
@testable import CheICalMCP

/// #354: `recurrence` and `clear_recurrence` on `update_reminder`, through the handler with a fake.
private actor RecurrenceWriteFake: ReminderWriteSource {
    var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: nil), isDuplicate: false, storeDiffers: [])
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        var readBack: ReminderRecurrenceWrite.ReadBack?
        if request.recurrenceRule != nil || request.clearRecurrence {
            let reminder = EKReminderBox.make(days: request.recurrenceRule?.daysOfWeek)
            readBack = ReminderRecurrenceWrite.readBack(reminder)
        }
        return ReminderUpdateResult(reminder: ReminderWriteSnapshot(id: request.identifier, title: "Saved", notes: nil),
                                    dateSync: nil, recurrence: readBack)
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: nil)
    }
}

import EventKit
private enum EKReminderBox {
    /// A reminder due Thu 2026-12-10 09:00, weekly on `days` (none: one-off).
    static func make(days: [Int]?) -> EKReminder {
        let reminder = EKReminder(eventStore: SharedTestStore.store)
        reminder.dueDateComponents = DateComponents(year: 2026, month: 12, day: 10, hour: 9, minute: 0)
        if let days {
            reminder.recurrenceRules = [EventKitManager.makeRecurrenceRule(from: RecurrenceRuleInput(
                frequency: .weekly, interval: 1, endDate: nil, occurrenceCount: nil, daysOfWeek: days, daysOfMonth: nil,
                excludedOccurrenceDates: nil))]
        }
        return reminder
    }
}

final class ReminderRecurrenceHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private let fridays: Value = .object(["frequency": .string("weekly"), "interval": .int(1), "days_of_week": .array([.int(6)])])

    func testARuleChangeIsPassedAndReadBack() async throws {
        let fake = RecurrenceWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "recurrence": fridays]))
        XCTAssertEqual(result["has_recurrence"] as? Bool, true)
        let rules = try XCTUnwrap(result["reminder_recurrence_rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["days_of_week"] as? [Int], [6])
        XCTAssertEqual((result["due"] as? [String: Any])?["date"] as? String, "2026-12-10")
        XCTAssertNotNil(result["recurrence_note"], "the due (a Thursday) is not on the new rule's days")
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.recurrenceRule?.daysOfWeek, [6])
        XCTAssertFalse(requests.first?.clearRecurrence ?? true)
    }

    func testClearRecurrenceIsPassedAndReadBack() async throws {
        let fake = RecurrenceWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "clear_recurrence": .bool(true)]))
        XCTAssertEqual(result["has_recurrence"] as? Bool, false)
        XCTAssertNil(result["recurrence_note"])
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.clearRecurrence, true)
    }

    func testAnUpdateWithoutRecurrenceHasNoRecurrenceKeys() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: RecurrenceWriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "title": .string("t")]))
        XCTAssertNil(result["has_recurrence"])
        XCTAssertNil(result["reminder_recurrence_rules"])
    }

    /// Refused before the store is called: both parameters, a rule with clear_due_date, a
    /// non-boolean clear_recurrence, and excluded_occurrence_dates (create_event only).
    func testRefusalsBeforeTheStore() async throws {
        let fake = RecurrenceWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let bad: [[String: Value]] = [
            ["recurrence": fridays, "clear_recurrence": .bool(true)],
            ["recurrence": fridays, "clear_due_date": .bool(true)],
            ["clear_recurrence": .string("yes")],
            ["recurrence": .object(["frequency": .string("weekly"), "excluded_occurrence_dates": .array([.string("2026-12-17")])])],
        ]
        for extra in bad {
            var arguments: [String: Value] = ["reminder_id": .string("r")]
            arguments.merge(extra) { $1 }
            do {
                _ = try await server.executeToolCall(name: "update_reminder", arguments: arguments)
                XCTFail("accepted \(extra)")
            } catch {}
        }
        let updated = await fake.updated
        XCTAssertTrue(updated.isEmpty)
    }

    func testTheToolDescribesTheParameters() throws {
        let tool = try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == "update_reminder" })
        let properties = try XCTUnwrap(tool.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertNotNil(properties["recurrence"])
        let clear = properties["clear_recurrence"]?.objectValue?["description"]?.stringValue ?? ""
        XCTAssertTrue(clear.contains("clear_due_date"), clear)
        let rule = properties["recurrence"]?.objectValue?["description"]?.stringValue ?? ""
        XCTAssertTrue(rule.contains("does not move the due date"), rule)
        XCTAssertTrue(rule.contains("recurrence_note"), rule)
        XCTAssertTrue((tool.description ?? "").contains("clear_recurrence"), tool.description ?? "")
    }
}
