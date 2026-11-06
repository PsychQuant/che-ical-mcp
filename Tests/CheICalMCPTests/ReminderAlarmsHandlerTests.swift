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
                     storedRelativeAlarms: duplicate ? nil : stored,
                     listShowsAlarmTime: !duplicate && Self.moved(stored))
    }
    private static func moved(_ stored: [Double]?) -> Bool {
        ReminderRelativeAlarms.listShowsAlarmTime(due: Date(timeIntervalSince1970: 0),
                                                  alarms: (stored ?? []).map { .relative(seconds: -$0 * 60) })
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        // "early-alarms" stands for a reminder that keeps an alarm before its due time.
        let shows = ReminderRelativeAlarms.reportsListTime(request)
            && (request.identifier == "early-alarms" || Self.moved(request.alarmOffsets?.map(Double.init)))
        // "keeps-alarms" stands for a reminder with two relative alarms the update leaves in place.
        let leftover = request.identifier == "keeps-alarms"
            ? ReminderRelativeAlarms.leftoverNote(requested: request.alarmOffsets, dueTouched: request.due != nil || request.clearDueDate,
                                                  dueAfter: ReminderRelativeAlarms.dueState(requested: request.due, clearDue: request.clearDueDate, existing: nil),
                                                  relativeCount: 2)
            : request.identifier == "both-notes" ? "leftover" : nil
        return ReminderUpdateResult(reminder: ReminderWriteSnapshot(id: request.identifier, title: "Saved", notes: nil),
                                    dateSync: nil,
                                    storedRelativeAlarms: request.alarmOffsets.map { $0.map(Double.init).sorted(by: >) },
                                    leftoverAlarmsNote: leftover,
                                    listShowsAlarmTime: shows || request.identifier == "both-notes")
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
        XCTAssertNil(result["alarms_differ"])
        XCTAssertEqual(result["alarms_note"] as? String, ReminderRelativeAlarms.alarmDisplayNote, "#433")
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
        let note = try XCTUnwrap(result["alarms_note"] as? String)
        XCTAssertTrue(note.contains("different relative alarms"), note)
        XCTAssertTrue(note.contains(ReminderRelativeAlarms.alarmDisplayNote), "#433: the stored one still sets the list's time: \(note)")
    }

    /// #433: `alarms_note` carries the display difference when the store judged it, next to the
    /// mismatch note and not instead of it. The judgement itself is `listShowsAlarmTime`.
    func testTheNoteFollowsTheJudgement() {
        let display = ReminderRelativeAlarms.alarmDisplayNote
        let matched = CheICalMCPServer.storedAlarmFields(requested: [15], stored: [15], listShowsAlarmTime: true)
        XCTAssertEqual(matched["alarms_note"] as? String, display)
        XCTAssertNil(matched["alarms_differ"])
        XCTAssertNil(CheICalMCPServer.storedAlarmFields(requested: [15], stored: [15], listShowsAlarmTime: false)["alarms_note"],
                     "an absolute alarm at the due time can keep the list on the due time")
        let both = CheICalMCPServer.storedAlarmFields(requested: [15, 60], stored: [15], listShowsAlarmTime: true)
        XCTAssertEqual(both["alarms_differ"] as? Bool, true)
        XCTAssertTrue((both["alarms_note"] as? String ?? "").hasSuffix(display))
        let mismatch = CheICalMCPServer.storedAlarmFields(requested: [15], stored: [], listShowsAlarmTime: false)
        XCTAssertEqual(mismatch["alarms_differ"] as? Bool, true)
        XCTAssertFalse((mismatch["alarms_note"] as? String ?? "").contains(display))
        XCTAssertTrue(CheICalMCPServer.storedAlarmFields(requested: [15], stored: nil, listShowsAlarmTime: true).isEmpty,
                      "not read back, nothing claimed")
    }

    /// PR #438 verify: both directions, no formula that holds only without absolute alarms, nothing
    /// said of a moved due date, and only the notification that was measured.
    func testTheDisplayNoteStatesWhatWasMeasured() {
        let note = ReminderRelativeAlarms.alarmDisplayNote
        for part in ["The alarm does not change the due date", "Reminders.app list", "earliest alarm time",
                     "instead of the due time", "earlier or later than the due time",
                     "one check", "future due date", "Early Reminder"] {
            XCTAssertTrue(note.contains(part), "\(part): \(note)")
        }
        for part in ["due date is unchanged", "due minus", "positive offset notifies"] {
            XCTAssertFalse(note.contains(part), "\(part): \(note)")
        }
    }

    func testAnUpdateThatMovesTheListTimeCarriesTheNote() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        let early = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "alarms_minutes_offsets": .array([.int(15)])]))
        XCTAssertEqual(early["alarms_note"] as? String, ReminderRelativeAlarms.alarmDisplayNote)
        let late = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "alarms_minutes_offsets": .array([.int(-15)])]))
        XCTAssertEqual(late["alarms_note"] as? String, ReminderRelativeAlarms.alarmDisplayNote)
        let cleared = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "alarms_minutes_offsets": .array([])]))
        XCTAssertNil(cleared["alarms_note"])
    }

    /// PR #438 verify: rescheduling a reminder that keeps an early alarm is the case #433 explains.
    func testAnUpdateThatTouchesTheDueCarriesTheNote() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        for arguments: [String: Value] in [["due_date": .string("2026-12-11T15:30:00")], ["realign_to_due": .bool(true)]] {
            let raw = try await server.executeToolCall(name: "update_reminder", arguments: arguments.merging(["reminder_id": .string("early-alarms")]) { $1 })
            XCTAssertEqual(try object(raw)["alarms_note"] as? String, ReminderRelativeAlarms.alarmDisplayNote, "\(arguments)")
        }
        let title = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("early-alarms"), "title": .string("t")]))
        XCTAssertNil(title["alarms_note"], "a call that touches no alarm and no due says nothing")
    }

    /// PR #438 verify: the due moves in the same call, and the note does not contradict it.
    func testAnUpdateMovingTheDueWithOffsetsCarriesTheNote() async throws {
        let fake = AlarmWriteFake()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-12-11T16:00:00"), "alarms_minutes_offsets": .array([.int(15)])]))
        let note = try XCTUnwrap(result["alarms_note"] as? String)
        XCTAssertEqual(note, ReminderRelativeAlarms.alarmDisplayNote)
        XCTAssertFalse(note.contains("unchanged"), note)
        let requests = await fake.updated
        XCTAssertNotNil(requests.first?.due)
    }

    /// Neither note replaces the other. The two cannot both be set by the store (the leftover note
    /// needs a due that is not timed, the display note a timed one); this pins the merge.
    func testALeftoverNoteAndTheDisplayNoteBothStay() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        var fields: [String: Any] = ["alarms_note": "first"]
        CheICalMCPServer.appendAlarmNote("second", to: &fields)
        XCTAssertEqual(fields["alarms_note"] as? String, "first second")
        var empty: [String: Any] = [:]
        CheICalMCPServer.appendAlarmNote("only", to: &empty)
        XCTAssertEqual(empty["alarms_note"] as? String, "only")
        let result = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("both-notes"), "title": .string("t")]))
        XCTAssertEqual(result["alarms_note"] as? String, "leftover \(ReminderRelativeAlarms.alarmDisplayNote)")
    }

    func testABatchRowThatMovesTheListTimeCarriesTheNote() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        let raw = try await server.executeToolCall(name: "create_reminders_batch", arguments: ["reminders": .array([
            .object(["title": .string("a"), "due_date": .string("2026-12-10T09:00:00"), "alarms_minutes_offsets": .array([.int(15)])]),
            .object(["title": .string("b"), "due_date": .string("2026-12-10T09:00:00"), "alarms_minutes_offsets": .array([.int(0)])]),
            .object(["title": .string("c"), "due_date": .string("2026-12-10T09:00:00")])])])
        let rows = try XCTUnwrap(try object(raw)["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["alarms_note"] as? String }, [ReminderRelativeAlarms.alarmDisplayNote, nil, nil])
    }

    /// #433: every tool that writes the offsets says what the list then shows, on what condition,
    /// and that the condition is inferred.
    func testTheToolsDescribeTheDisplay() throws {
        let tools = CheICalMCPServer.defineTools()
        var parameters: [(String, String)] = []
        for name in ["create_reminder", "update_reminder"] {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            parameters.append((name, tool.inputSchema.objectValue?["properties"]?.objectValue?["alarms_minutes_offsets"]?.objectValue?["description"]?.stringValue ?? ""))
        }
        let batch = try XCTUnwrap(tools.first { $0.name == "create_reminders_batch" })
        let rows = batch.inputSchema.objectValue?["properties"]?.objectValue?["reminders"]?.objectValue?["items"]?.objectValue?["properties"]
        parameters.append(("create_reminders_batch", rows?.objectValue?["alarms_minutes_offsets"]?.objectValue?["description"]?.stringValue ?? ""))
        for (name, parameter) in parameters {
            XCTAssertTrue(parameter.contains(ReminderRelativeAlarms.alarmDisplayNote), "\(name): \(parameter)")
            XCTAssertTrue(parameter.contains(ReminderRelativeAlarms.alarmNoteCondition), "\(name): \(parameter)")
            XCTAssertTrue(parameter.contains("alarms_note"), "\(name): \(parameter)")
        }
        for part in ["relative or absolute", "inferred", "[0, -15]"] {
            XCTAssertTrue(ReminderRelativeAlarms.alarmNoteCondition.contains(part), part)
        }
        let update = try XCTUnwrap(tools.first { $0.name == "update_reminder" })
        XCTAssertTrue(update.description?.contains("earliest time-based alarm") ?? false, update.description ?? "")
        XCTAssertFalse(update.description?.contains("the date of the earliest absolute-date alarm") ?? true, update.description ?? "")
    }

    func testTheToolsDescribeTheParameter() throws {
        let tools = CheICalMCPServer.defineTools()
        for name in ["create_reminder", "update_reminder", "create_reminders_batch"] {
            let schema = "\(String(describing: tools.first { $0.name == name }?.inputSchema))"
            XCTAssertTrue(schema.contains("alarms_minutes_offsets"), name)
            XCTAssertTrue(schema.contains("only the relative alarms"), name)
            XCTAssertTrue(schema.contains("date-only"), name)
            XCTAssertTrue(schema.contains("525600"), "\(name): the bound is stated")
        }
        // PR #415 verify round 1: the recurring claim is stated as unchecked, and the event tools state the bound.
        let create = "\(String(describing: tools.first { $0.name == "create_reminder" }?.inputSchema))"
        XCTAssertTrue(create.contains("that is not yet checked on a device"), create)
        XCTAssertFalse(create.contains("the alarm moves with each occurrence"), create)
        for name in ["create_event", "update_event"] {
            XCTAssertTrue("\(String(describing: tools.first { $0.name == name }?.inputSchema))".contains("from -525600 to 525600"), name)
        }
    }

    func testAnUpdateThatLeavesRelativeAlarmsWithoutATimedDueSaysSo() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: AlarmWriteFake())
        let cleared = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("keeps-alarms"), "clear_due_date": .bool(true)]))
        XCTAssertEqual(cleared["alarms_note"] as? String, ReminderRelativeAlarms.leftoverNoDueNote(2))
        let dated = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("keeps-alarms"), "due_date": .string("2026-12-11")]))
        XCTAssertEqual(dated["alarms_note"] as? String, ReminderRelativeAlarms.leftoverDateOnlyNote(2))
        let plain = try object(await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "due_date": .string("2026-12-11")]))
        XCTAssertNil(plain["alarms_note"])
    }

    /// PR #415 verify round 1: the event tools refuse a present non-array value and an offset
    /// outside one year (Int.max used to trap `Int * 60` on create_event / update_event) before
    /// anything is looked up or written.
    func testTheEventToolsRefuseANonArrayOrOutOfRangeOffset() async throws {
        let server = try await CheICalMCPServer()
        let event: [String: Value] = ["title": .string("x"), "start_time": .string("2026-12-10T09:00:00"),
                                      "end_time": .string("2026-12-10T10:00:00"), "calendar_name": .string("none")]
        for (value, expected) in [(Value.string("15"), "must be an array of integers"), (.array([.int(Int.max)]), "525600")] {
            for (tool, base) in [("create_event", event), ("update_event", ["event_id": .string("none")] as [String: Value])] {
                var arguments = base
                arguments["alarms_minutes_offsets"] = value
                do {
                    _ = try await server.executeToolCall(name: tool, arguments: arguments)
                    XCTFail("\(tool) accepted \(value)")
                } catch {
                    XCTAssertTrue("\(error)".contains(expected), "\(tool): \(error)")
                }
            }
        }
    }
}
