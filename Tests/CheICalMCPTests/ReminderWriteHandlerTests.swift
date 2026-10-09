import MCP
import XCTest
@testable import CheICalMCP

private actor WriteFake: ReminderWriteSource {
    var created: [ReminderCreateRequest] = []
    var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        created.append(request)
        return .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: request.notes), isDuplicate: request.title == "duplicate",
                     storeDiffers: request.title == "differs" ? ["due", "title"] : [])
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        let touchedDue = request.due != nil || request.clearDueDate || request.realignToDue
        let sync: ReminderDateSync.Report
        if request.clearDueDate {
            sync = ReminderDateSync.Report(startDate: .cleared, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 1)
        } else if case .day? = request.due {
            sync = ReminderDateSync.Report(startDate: .shifted, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 2, aligned: true)
        } else {
            sync = ReminderDateSync.Report(startDate: .shifted, absoluteAlarmsShifted: 1, absoluteAlarmsRemoved: 0, aligned: true)
        }
        return ReminderUpdateResult(
            reminder: ReminderWriteSnapshot(id: request.identifier, title: request.title ?? "Saved", notes: request.notes),
            dateSync: touchedDue ? sync : nil)
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: "original\n#old")
    }
}
final class ReminderWriteHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    func testNormalAndDuplicateCreateResponses() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        for (title, action) in [("new", "created"), ("duplicate", "skipped")] {
            let result = try object(await server.executeToolCall(name: "create_reminder", arguments: ["title": .string(title), "tags": .array([.string("tag")])]))
            XCTAssertEqual(result["action"] as? String, action)
            XCTAssertEqual(result["id"] as? String, "saved")
        }
        let requests = await fake.created
        XCTAssertEqual(requests.first?.notes, "#tag")
    }
    // #261: a save that threw but that a new store found with some fields read back differently
    // succeeds, and the response names those fields (names only).
    func testACreateTheStoreHoldsDifferentlySucceedsAndNamesTheFields() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "create_reminder", arguments: ["title": .string("differs")]))
        XCTAssertEqual(result["action"] as? String, "created")
        XCTAssertEqual(result["store_differs"] as? [String], ["due", "title"])
        XCTAssertEqual(result["note"] as? String, "Saved, but the store holds a different due, title; check it. Creating it again with the same parameters may make a second copy.")
        let plain = try object(await server.executeToolCall(name: "create_reminder", arguments: ["title": .string("new")]))
        XCTAssertNil(plain["store_differs"])
        XCTAssertNil(plain["note"])
        let batch = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: [
            "reminders": .array([.object(["title": .string("differs")]), .object(["title": .string("new")])])]))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["store_differs"] as? [String], ["due", "title"])
        XCTAssertNil(rows[1]["store_differs"])
    }
    func testUpdateNotesPreservesTagsAndClearTagsPreservesBody() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "notes": .string("replacement")])
        _ = try await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "clear_tags": .bool(true)])
        let requests = await fake.updated
        XCTAssertEqual(requests[0].notes, "replacement\n#old")
        XCTAssertEqual(requests[1].notes, "original")
    }
    // #227: the response says what moved with the due date.
    func testUpdateResponseReportsDateSyncWhenTheDueDateMoves() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-08T10:00:00+08:00")]))
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["start_date"] as? String, "shifted")
        XCTAssertEqual(sync["absolute_alarms_shifted"] as? Int, 1)
        XCTAssertEqual(sync["absolute_alarms_removed"] as? Int, 0)
    }
    func testUpdateResponseReportsRemovedAlarmsWhenTheDueDateIsCleared() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "clear_due_date": .bool(true)]))
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["start_date"] as? String, "cleared")
        XCTAssertEqual(sync["absolute_alarms_removed"] as? Int, 1)
    }
    func testUpdateResponseOmitsDateSyncWhenTheDueDateIsUntouched() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "title": .string("Renamed")]))
        XCTAssertNil(result["date_sync"])
    }
    // #235: realign_to_due puts the start date and absolute alarms onto the due date.
    func testRealignToDueIsPassedThroughWithTheDueDate() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-08T10:00:00+08:00"), "realign_to_due": .bool(true)]))
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.realignToDue, true)
        XCTAssertNotNil(requests.first?.due)
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["aligned"] as? Bool, true)
    }
    func testRealignToDueAloneReportsDateSync() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "realign_to_due": .bool(true)]))
        let requests = await fake.updated
        XCTAssertEqual(requests.first?.realignToDue, true)
        XCTAssertNil(requests.first?.due)
        XCTAssertNotNil(result["date_sync"] as? [String: Any])
    }
    /// The handler's default: omitted, JSON null and `false` all leave realign off; only `true`
    /// turns it on. (What realign does to a reminder is pinned in `ReminderUpdateWriteTests`.)
    func testRealignToDueIsOffUnlessTrue() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let due: Value = .string("2026-10-08T10:00:00+08:00")
        for extra: [String: Value] in [[:], ["realign_to_due": .null], ["realign_to_due": .bool(false)], ["realign_to_due": .bool(true)]] {
            _ = try await server.executeToolCall(name: "update_reminder",
                                                 arguments: ["reminder_id": .string("r"), "due_date": due].merging(extra) { $1 })
        }
        let requests = await fake.updated
        XCTAssertEqual(requests.map(\.realignToDue), [false, false, false, true])
    }
    func testRealignToDueWithClearDueDateIsRejectedBeforeAnyWrite() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        do {
            _ = try await server.executeToolCall(name: "update_reminder", arguments: [
                "reminder_id": .string("r"), "clear_due_date": .bool(true), "realign_to_due": .bool(true)])
            XCTFail("realign_to_due with clear_due_date must be rejected")
        } catch let error as ToolError {
            XCTAssertTrue("\(error)".contains("realign_to_due"), "\(error)")
        }
        let requests = await fake.updated
        XCTAssertTrue(requests.isEmpty)
    }
    func testBatchCountsDuplicateAndInvalidRows() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: ["reminders": .array([.object(["title": .string("new")]), .object(["title": .string("duplicate")]), .object([:])])]))
        XCTAssertEqual(result["total"] as? Int, 3)
        XCTAssertEqual(result["succeeded"] as? Int, 1)
        XCTAssertEqual(result["failed"] as? Int, 1)
        XCTAssertEqual(result["skipped"] as? Int, 1)
    }

    // MARK: - date-only due (#267)

    // A bare date reaches the store as a day on every reminder writer.
    func testABareDueDateIsPassedAsADayOnEveryWriter() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("a"), "due_date": .string("2026-10-18")])
        _ = try await server.executeToolCall(name: "create_reminders_batch", arguments: [
            "reminders": .array([.object(["title": .string("b"), "due_date": .string("2026-10-19")])])])
        _ = try await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-20")])
        let created = await fake.created
        let updated = await fake.updated
        XCTAssertEqual(created.map(\.due), [.day(DateComponents(year: 2026, month: 10, day: 18)),
                                             .day(DateComponents(year: 2026, month: 10, day: 19))])
        XCTAssertEqual(updated.map(\.due), [.day(DateComponents(year: 2026, month: 10, day: 20))])
    }

    // Anything with a time is an instant, as before.
    func testADueDateWithATimeIsPassedAsAnInstant() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("a"), "due_date": .string("2026-10-18T09:00:00+08:00")])
        let created = await fake.created
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-18T09:00:00+08:00"))
        XCTAssertEqual(created.first?.due, .timed(expected))
    }

    // A bare date that is not a day is refused as before, before anything is written.
    func testABareDateThatIsNotADayIsRefused() async throws {
        let fake = WriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        do {
            _ = try await server.executeToolCall(name: "create_reminder", arguments: [
                "title": .string("a"), "due_date": .string("2026-02-30")])
            XCTFail("2026-02-30 must be refused")
        } catch let error as ToolError {
            XCTAssertTrue("\(error)".contains("not a valid date"), "\(error)")
        }
        let created = await fake.created
        XCTAssertTrue(created.isEmpty)
    }

    // PR #298 verify round 1: a date-only update answers with the date_sync of the day write: the
    // removed absolute alarms are counted, nothing is reported as shifted.
    func testADateOnlyUpdateReportsTheRemovedAlarms() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-10-20")]))
        let sync = try XCTUnwrap(result["date_sync"] as? [String: Any])
        XCTAssertEqual(sync["absolute_alarms_removed"] as? Int, 2)
        XCTAssertEqual(sync["absolute_alarms_shifted"] as? Int, 0)
        XCTAssertEqual(sync["start_date"] as? String, "shifted")
        XCTAssertEqual(sync["aligned"] as? Bool, true)
    }
}
