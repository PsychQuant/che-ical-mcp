import MCP
import XCTest
@testable import CheICalMCP

/// #354: `recurrence` and `clear_recurrence` on `update_reminder`, through the handler with a fake.
private actor RecurrenceUpdateWriteFake: ReminderWriteSource {
    var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: nil), isDuplicate: false, storeDiffers: [])
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        var readBack: ReminderRecurrenceWrite.ReadBack?
        if request.recurrenceRule != nil || request.clearRecurrence {
            let reminder = EKReminderBox.make(days: request.recurrenceRule?.daysOfWeek)
            readBack = request.identifier == "unreadable"
                ? ReminderRecurrenceWrite.readBackAfterSave(reminder, request: request, reload: { false })
                : ReminderRecurrenceWrite.readBack(reminder, request: request)
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

final class ReminderRecurrenceUpdateHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private let fridays: Value = .object(["frequency": .string("weekly"), "interval": .int(1), "days_of_week": .array([.int(6)])])

    func testARuleChangeIsPassedAndReadBack() async throws {
        let fake = RecurrenceUpdateWriteFake()
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
        let fake = RecurrenceUpdateWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "clear_recurrence": .bool(true)]))
        XCTAssertEqual(result["has_recurrence"] as? Bool, false)
        XCTAssertNil(result["recurrence_note"])
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.clearRecurrence, true)
    }

    func testAnUpdateWithoutRecurrenceHasNoRecurrenceKeys() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: RecurrenceUpdateWriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "title": .string("t")]))
        XCTAssertNil(result["has_recurrence"])
        XCTAssertNil(result["reminder_recurrence_rules"])
    }

    /// Refused before the store is called: both parameters, a rule with clear_due_date, a
    /// non-boolean clear_recurrence, and excluded_occurrence_dates (create_event only).
    func testRefusalsBeforeTheStore() async throws {
        let fake = RecurrenceUpdateWriteFake()
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

    // MARK: - PR #420 verify round 1

    func testAReminderThatCannotBeReReadReportsNoRule() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: RecurrenceUpdateWriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("unreadable"), "recurrence": fridays]))
        XCTAssertEqual(result["recurrence_read_back"] as? Bool, false)
        XCTAssertEqual(result["recurrence_note"] as? String, ReminderRecurrenceWrite.unconfirmedNote)
        XCTAssertNil(result["reminder_recurrence_rules"])
    }

    func testARuleWithClearDueDateGetsItsOwnMessage() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: RecurrenceUpdateWriteFake())
        do {
            _ = try await server.executeToolCall(name: "update_reminder", arguments: [
                "reminder_id": .string("r"), "recurrence": fridays, "clear_due_date": .bool(true)])
            XCTFail("accepted")
        } catch {
            XCTAssertTrue("\(error)".contains(ReminderRecurrenceWrite.clearDueWithRuleMessage), "\(error)")
        }
    }

    /// `interval` and `occurrence_count` out of range made EventKit raise an Objective-C exception
    /// that crashed the server (measured: interval 0, -1 and 2^31…2^32; occurrence_count 0). The
    /// shared parser refuses them on every tool that takes `recurrence`, and a day list that is
    /// not an array is refused instead of dropped.
    func testOutOfRangeRulesAreRefusedOnEveryTool() async throws {
        let fake = RecurrenceUpdateWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let bad: [(Value, String)] = [
            (.object(["frequency": .string("weekly"), "interval": .int(0)]), "interval"),
            (.object(["frequency": .string("weekly"), "interval": .int(-1)]), "interval"),
            (.object(["frequency": .string("weekly"), "interval": .int(2_147_483_648)]), "interval"),
            (.object(["frequency": .string("weekly"), "occurrence_count": .int(0)]), "occurrence_count"),
            (.object(["frequency": .string("weekly"), "occurrence_count": .int(-1)]), "occurrence_count"),
            (.object(["frequency": .string("weekly"), "days_of_week": .int(5)]), "days_of_week"),
            (.object(["frequency": .string("monthly"), "days_of_month": .string("15")]), "days_of_month"),
        ]
        let tools: [(String, [String: Value])] = [
            ("update_reminder", ["reminder_id": .string("r")]),
            ("create_reminder", ["title": .string("t"), "due_date": .string("2026-12-10T09:00:00"), "calendar_name": .string("none")]),
            ("create_event", ["title": .string("t"), "start_time": .string("2026-12-10T09:00:00"),
                              "end_time": .string("2026-12-10T10:00:00"), "calendar_name": .string("none")]),
        ]
        for (rule, field) in bad {
            for (tool, base) in tools {
                var arguments = base
                arguments["recurrence"] = rule
                do {
                    _ = try await server.executeToolCall(name: tool, arguments: arguments)
                    XCTFail("\(tool) accepted \(rule)")
                } catch {
                    XCTAssertTrue("\(error)".contains("recurrence.\(field)"), "\(tool): \(error)")
                }
            }
        }
        let updated = await fake.updated
        XCTAssertTrue(updated.isEmpty)
    }

    func testTheRuleBoundsAreStatedInTheSchemas() {
        for name in ["create_event", "update_event", "create_reminder", "update_reminder"] {
            let schema = "\(String(describing: CheICalMCPServer.defineTools().first { $0.name == name }?.inputSchema))"
            XCTAssertTrue(schema.contains("1 to 1000"), "\(name): interval bound")
            XCTAssertTrue(schema.contains("1 to 10000"), "\(name): occurrence_count bound")
        }
    }
}
