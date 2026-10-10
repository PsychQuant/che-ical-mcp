import MCP
import XCTest
@testable import CheICalMCP

private actor WriteFake: ReminderWriteSource {
    var created: [ReminderCreateRequest] = []
    var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        created.append(request)
        let isDuplicate = request.title == "duplicate" || request.title == "duplicate-timed"
        // #301: a created date-only reminder carries the read-back report; "unconfirmed" reads back
        // not aligned.
        var dateSync: ReminderDateSync.Report?
        if case .day? = request.due, !isDuplicate {
            dateSync = ReminderDateSync.Report(startDate: .set, absoluteAlarmsShifted: 0, absoluteAlarmsRemoved: 0,
                                               aligned: request.title != "unconfirmed")
        }
        return .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: request.notes),
                     isDuplicate: isDuplicate,
                     storeDiffers: request.title == "differs" ? ["due", "title"] : [],
                     duplicateHasTime: request.title == "duplicate-timed",
                     dateSync: dateSync)
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
        // PR #298 verify round 2: the removal is said in words too, with how to get the alarms back.
        XCTAssertEqual(result["note"] as? String, "Made date-only: removed 2 absolute-date alarms, because Reminders.app would go on showing an alarm's time. undo restores them while this server is running, if the reminder has not been changed since.")
    }

    func testTheAlarmRemovalNoteMatchesTheCount() {
        XCTAssertEqual(CheICalMCPServer.dateOnlyAlarmRemovalNote(1), "Made date-only: removed 1 absolute-date alarm, because Reminders.app would go on showing an alarm's time. undo restores it while this server is running, if the reminder has not been changed since.")
    }

    func testOnlyADateOnlyUpdateThatRemovedAlarmsCarriesANote() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        for arguments: [String: Value] in [["due_date": .string("2026-10-20T09:00:00+08:00")], ["clear_due_date": .bool(true)], ["title": .string("Renamed")]] {
            let result = try object(await server.executeToolCall(name: "update_reminder", arguments: arguments.merging(["reminder_id": .string("r")]) { $1 }))
            XCTAssertNil(result["note"], "\(arguments)")
        }
    }

    // PR #298 verify round 2: a bare-date create that meets an existing reminder with a time (what
    // a bare date was stored as before #267) is still skipped as a duplicate, and says how to make
    // the existing one date-only.
    func testABareDateDuplicateOfATimedReminderSaysHowToMakeItDateOnly() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        let note = "The existing reminder with this title has a time on that day and was left as it is. To make it date-only, call update_reminder with this bare date."
        let single = try object(await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("duplicate-timed"), "due_date": .string("2026-10-18")]))
        XCTAssertEqual(single["action"] as? String, "skipped")
        XCTAssertEqual(single["note"] as? String, note)
        let batch = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: [
            "reminders": .array([.object(["title": .string("duplicate-timed"), "due_date": .string("2026-10-18")])])]))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["note"] as? String, note)
    }

    func testOtherDuplicatesCarryNoNote() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        for (title, due) in [("duplicate-timed", "2026-10-18T00:00:00+08:00"), ("duplicate", "2026-10-18")] {
            let result = try object(await server.executeToolCall(name: "create_reminder", arguments: [
                "title": .string(title), "due_date": .string(due)]))
            XCTAssertEqual(result["action"] as? String, "skipped")
            XCTAssertNil(result["note"], title)
        }
    }

    func testCreateReminderReportsWhetherTheDuplicateHasATime() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func createReminder(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertTrue(SourceScan.collapsingWhitespace(body).contains("isDuplicate: true, storeDiffers: [], duplicateHasTime: existing.dueDateComponents?.hour != nil)"), body)
    }

    // MARK: - #301: a date-only create says whether the saved reminder reads back as asked

    func testADateOnlyCreateReportsDateSync() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        for (title, aligned) in [("new", true), ("unconfirmed", false)] {
            let single = try object(await server.executeToolCall(name: "create_reminder", arguments: [
                "title": .string(title), "due_date": .string("2026-10-18")]))
            XCTAssertEqual(single["action"] as? String, "created")
            let sync = try XCTUnwrap(single["date_sync"] as? [String: Any], title)
            XCTAssertEqual(sync["aligned"] as? Bool, aligned, title)
            XCTAssertEqual(sync["start_date"] as? String, "set", title)
        }
        let batch = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: [
            "reminders": .array([.object(["title": .string("new"), "due_date": .string("2026-10-18")]),
                                 .object(["title": .string("unconfirmed"), "due_date": .string("2026-10-18")]),
                                 .object(["title": .string("new"), "due_date": .string("2026-10-18T09:00:00+08:00")]),
                                 .object(["title": .string("duplicate"), "due_date": .string("2026-10-18")])])]))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual((rows[0]["date_sync"] as? [String: Any])?["aligned"] as? Bool, true)
        XCTAssertEqual((rows[1]["date_sync"] as? [String: Any])?["aligned"] as? Bool, false)
        XCTAssertNil(rows[2]["date_sync"], "a timed create carries none")
        XCTAssertNil(rows[3]["date_sync"], "a skipped row carries none")
    }

    func testATimedOrDuplicateCreateCarriesNoDateSync() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: WriteFake())
        for (title, due) in [("new", "2026-10-18T09:00:00+08:00"), ("duplicate", "2026-10-18"), ("new", nil)] as [(String, String?)] {
            var args: [String: Value] = ["title": .string(title)]
            if let due { args["due_date"] = .string(due) }
            let result = try object(await server.executeToolCall(name: "create_reminder", arguments: args))
            XCTAssertNil(result["date_sync"], "\(title) \(due ?? "no due")")
        }
    }

    // The day's report is judged on the saved reminder, not thrown away (source pin: the store path
    // needs a real EKEventStore).
    func testCreateReminderJudgesTheDayOnTheSavedReminder() throws {
        let body = try XCTUnwrap(SourcePins.body(of: "func createReminder(", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let flat = SourceScan.collapsingWhitespace(body)
        XCTAssertFalse(flat.contains("_ = ReminderDateSync.setDueDay"), flat)
        XCTAssertTrue(flat.contains("dayReport = ReminderDateSync.setDueDay(reminder, to: day)"), flat)
        XCTAssertTrue(flat.contains("ReminderDateSync.confirmSaved(reminder, report: dayReport, save: {}, reload: { reminder.refresh() }, rollback: {})"), flat)
        XCTAssertTrue(flat.contains("dateSync: dateSync"), flat)
        let save = try XCTUnwrap(flat.range(of: "saveNewReminder("))
        let confirm = try XCTUnwrap(flat.range(of: "ReminderDateSync.confirmSaved("))
        XCTAssertLessThan(save.lowerBound, confirm.lowerBound, "judged after the save")
    }
}
