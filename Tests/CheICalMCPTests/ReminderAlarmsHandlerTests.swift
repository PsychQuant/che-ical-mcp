import MCP
import XCTest
@testable import CheICalMCP

/// #333: `alarms_minutes_offsets` on `create_reminder`, `create_reminders_batch` and
/// `update_reminder`, through the handlers with a fake write source.
private actor AlarmWriteFake: ReminderWriteSource {
    var created: [ReminderCreateRequest] = []
    var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        created.append(request)
        let duplicate = request.title == "duplicate"
        // "short" stores one alarm fewer than asked, to drive the mismatch report.
        let stored = request.alarmOffsets.map { offsets in
            (request.title == "short" ? Array(offsets.dropLast()) : offsets).map(Double.init).sorted(by: >)
        }
        return .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: request.notes),
                     isDuplicate: duplicate, storeDiffers: [],
                     storedRelativeAlarms: duplicate ? nil : stored)
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        return ReminderUpdateResult(reminder: ReminderWriteSnapshot(id: request.identifier, title: "Saved", notes: nil),
                                    dateSync: nil,
                                    storedRelativeAlarms: request.alarmOffsets.map { $0.map(Double.init).sorted(by: >) })
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: nil)
    }
}

final class ReminderAlarmsHandlerTests: XCTestCase {
    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testCreatePassesTheOffsetsAndReportsWhatWasStored() async throws {
        let fake = AlarmWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("new"), "due_date": .string("2026-12-10T09:00:00"),
            "alarms_minutes_offsets": .array([.int(15), .int(60)])]))
        XCTAssertEqual(result["action"] as? String, "created")
        XCTAssertEqual(result["alarms_minutes_offsets"] as? [Double], [60, 15])
        XCTAssertNil(result["alarms_note"])
        let requests = await fake.created
        XCTAssertEqual(requests.first?.alarmOffsets, [15, 60])
    }

    func testACreateWithoutOffsetsHasNoAlarmKeys() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        let result = try object(await server.executeToolCall(name: "create_reminder", arguments: ["title": .string("new")]))
        XCTAssertNil(result["alarms_minutes_offsets"])
    }

    func testAStoredSetThatDiffersIsReported() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        let result = try object(await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("short"), "due_date": .string("2026-12-10T09:00:00"),
            "alarms_minutes_offsets": .array([.int(15), .int(60)])]))
        XCTAssertEqual(result["alarms_minutes_offsets"] as? [Double], [15])
        XCTAssertEqual(result["alarms_differ"] as? Bool, true)
        XCTAssertNotNil(result["alarms_note"])
    }

    func testASkippedDuplicateSaysTheAlarmsWereNotApplied() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        let result = try object(await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("duplicate"), "due_date": .string("2026-12-10T09:00:00"),
            "alarms_minutes_offsets": .array([.int(15)])]))
        XCTAssertEqual(result["action"] as? String, "skipped")
        XCTAssertEqual(result["alarms_applied"] as? Bool, false)
        XCTAssertEqual(result["alarms_note"] as? String, CheICalMCPServer.duplicateAlarmsNote)
    }

    /// Refused before the store is called: no due date, or a date-only one.
    func testCreateRefusesAnAlarmThatCannotFireOrIsNotMeasured() async throws {
        let fake = AlarmWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        for (due, message) in [(nil as String?, ReminderRelativeAlarms.noDueMessage), ("2026-12-10", ReminderRelativeAlarms.dateOnlyMessage)] {
            var arguments: [String: Value] = ["title": .string("new"), "alarms_minutes_offsets": .array([.int(240)])]
            if let due { arguments["due_date"] = .string(due) }
            do {
                _ = try await server.executeToolCall(name: "create_reminder", arguments: arguments)
                XCTFail("expected a refusal for due \(String(describing: due))")
            } catch {
                XCTAssertTrue("\(error)".contains(message), "\(error)")
            }
        }
        let created = await fake.created
        XCTAssertTrue(created.isEmpty)
    }

    func testOffsetsMustBeAnArrayOfIntegers() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        for bad: Value in [.string("15"), .array([.string("x")]), .array([.double(1.5)])] {
            do {
                _ = try await server.executeToolCall(name: "create_reminder", arguments: [
                    "title": .string("new"), "due_date": .string("2026-12-10T09:00:00"), "alarms_minutes_offsets": bad])
                XCTFail("expected a refusal for \(bad)")
            } catch {
                XCTAssertTrue("\(error)".contains("alarms_minutes_offsets"), "\(error)")
            }
        }
    }

    func testUpdatePassesTheOffsetsAndAnEmptyListClears() async throws {
        let fake = AlarmWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "alarms_minutes_offsets": .array([.int(30)])]))
        XCTAssertEqual(result["alarms_minutes_offsets"] as? [Double], [30])
        let cleared = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "alarms_minutes_offsets": .array([])]))
        XCTAssertEqual(cleared["alarms_minutes_offsets"] as? [Double], [])
        let untouched = try object(await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "title": .string("t")]))
        XCTAssertNil(untouched["alarms_minutes_offsets"])
        let requests = await fake.updated
        XCTAssertEqual(requests.map(\.alarmOffsets), [[30], [], nil])
    }

    func testUpdateRefusesADateOnlyOrClearedDueWithAlarmsBeforeTheStore() async throws {
        let fake = AlarmWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        for extra: [String: Value] in [["due_date": .string("2026-12-11")], ["clear_due_date": .bool(true)]] {
            var arguments: [String: Value] = ["reminder_id": .string("r"), "alarms_minutes_offsets": .array([.int(15)])]
            arguments.merge(extra) { $1 }
            do {
                _ = try await server.executeToolCall(name: "update_reminder", arguments: arguments)
                XCTFail("expected a refusal for \(extra)")
            } catch {}
        }
        let updated = await fake.updated
        XCTAssertTrue(updated.isEmpty)
    }

    func testBatchRowsCarryTheirOwnOffsets() async throws {
        let fake = AlarmWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let batch = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: [
            "reminders": .array([
                .object(["title": .string("a"), "due_date": .string("2026-12-10T09:00:00"), "alarms_minutes_offsets": .array([.int(10)])]),
                .object(["title": .string("b"), "due_date": .string("2026-12-10"), "alarms_minutes_offsets": .array([.int(10)])]),
                .object(["title": .string("c")]),
            ])]))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["alarms_minutes_offsets"] as? [Double], [10])
        XCTAssertEqual(rows[1]["success"] as? Bool, false)
        XCTAssertTrue((rows[1]["error"] as? String ?? "").contains("date-only"), "\(rows[1])")
        XCTAssertNil(rows[2]["alarms_minutes_offsets"])
        let created = await fake.created
        XCTAssertEqual(created.map(\.title), ["a", "c"])
    }

    func testTheToolsDescribeTheParameter() throws {
        let tools = CheICalMCPServer.defineTools()
        for name in ["create_reminder", "update_reminder", "create_reminders_batch"] {
            let schema = "\(String(describing: tools.first { $0.name == name }?.inputSchema))"
            XCTAssertTrue(schema.contains("alarms_minutes_offsets"), name)
            XCTAssertTrue(schema.contains("only the relative alarms"), name)
            XCTAssertTrue(schema.contains("date-only"), name)
        }
    }
}
