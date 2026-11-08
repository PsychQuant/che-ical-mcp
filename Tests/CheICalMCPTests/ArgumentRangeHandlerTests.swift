import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// A minimal reminder source: records the requests and writes nothing.
private actor RecordingReminderSource: ReminderWriteSource {
    private(set) var created: [ReminderCreateRequest] = []
    private(set) var updated: [ReminderUpdateRequest] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        created.append(request)
        return .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: nil), isDuplicate: false, storeDiffers: [])
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        updated.append(request)
        return ReminderUpdateResult(reminder: ReminderWriteSnapshot(id: request.identifier, title: "Saved", notes: nil), dateSync: nil)
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: nil)
    }
}

/// #473: number and enum arguments that were changed or dropped with no message are refused at the
/// handler, before anything is written, with a message that names the argument and what it takes.
final class ArgumentRangeHandlerTests: XCTestCase {
    private func decoded(_ json: String) throws -> [String: Value] {
        try JSONDecoder().decode([String: Value].self, from: Data(json.utf8))
    }

    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private let start = #""start_time": "2027-04-10T09:00:00", "end_time": "2027-04-10T10:00:00", "calendar_name": "Work""#

    /// The refusal message, or a failure when the call went through.
    private func refusal(_ server: CheICalMCPServer, _ tool: String, _ json: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        do {
            _ = try await server.executeToolCall(name: tool, arguments: decoded(json))
            XCTFail("\(tool) took \(json)", file: file, line: line)
            return ""
        } catch ToolError.invalidParameter(let message) {
            return message
        }
    }

    // MARK: - location_trigger

    private func trigger(_ inner: String) -> String {
        #""location_trigger": {"title": "Lab", \#(inner)}"#
    }

    func testALocationTriggerRadiusOfZeroOrLessIsRefused() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        for radius in ["0", "-5", "-0.5"] {
            let inner = #""latitude": 25, "longitude": 121, "proximity": "enter", "radius": \#(radius)"#
            for (tool, head) in [("create_reminder", #""title": "t""#), ("update_reminder", #""reminder_id": "r""#)] {
                let message = try await refusal(server, tool, "{\(head), \(trigger(inner))}")
                XCTAssertTrue(message.contains("location_trigger.radius must be greater than 0"), "\(tool) \(radius): \(message)")
                XCTAssertTrue(message.contains("100"), "the default is named: \(message)")
            }
        }
        let created = await source.created
        let updated = await source.updated
        XCTAssertTrue(created.isEmpty && updated.isEmpty, "nothing was written")
    }

    func testALocationTriggerProximityOtherThanEnterOrLeaveIsRefused() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        let given = [#", "proximity": "Leave""#, #", "proximity": "exit""#, #", "proximity": """#, ""]
        for proximity in given {
            let inner = #""latitude": 25, "longitude": 121\#(proximity)"#
            for (tool, head) in [("create_reminder", #""title": "t""#), ("update_reminder", #""reminder_id": "r""#)] {
                let message = try await refusal(server, tool, "{\(head), \(trigger(inner))}")
                XCTAssertTrue(message.contains("location_trigger.proximity"), "\(tool) \(proximity): \(message)")
                XCTAssertTrue(message.contains(#""enter" or "leave""#), "\(tool) \(proximity): \(message)")
                XCTAssertFalse(message.contains("exit") || message.contains("Leave"), "#37: \(message)")
            }
        }
        let created = await source.created
        let updated = await source.updated
        XCTAssertTrue(created.isEmpty && updated.isEmpty, "nothing was written")
    }

    func testALocationTriggerTakesEnterAndLeave() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        for proximity in ["enter", "leave"] {
            let inner = #""latitude": 25, "longitude": 121, "proximity": "\#(proximity)""#
            _ = try await server.executeToolCall(name: "create_reminder", arguments: decoded(#"{"title": "t", \#(trigger(inner))}"#))
        }
        let written = await source.created.map(\.locationTrigger?.proximity)
        XCTAssertEqual(written, [.enter, .leave])
    }

    // MARK: - structured_location

    private func place(_ inner: String) -> String {
        #""structured_location": {"title": "Lab"\#(inner)}"#
    }

    /// `create_event` and `update_event` refuse; a `create_events_batch` row fails alone.
    private func assertEveryEventToolRefuses(_ inner: String, saying expected: String,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: source)
        for (tool, json) in [("create_event", #"{"title": "t", \#(start), \#(place(inner))}"#),
                             ("update_event", #"{"event_id": "e", \#(place(inner))}"#)] {
            let message = try await refusal(server, tool, json, file: file, line: line)
            XCTAssertTrue(message.contains(expected), "\(tool) \(inner): \(message)", file: file, line: line)
        }
        let batch = try object(await server.executeToolCall(name: "create_events_batch", arguments: decoded(
            #"{"events": [{"title": "bad", \#(start), \#(place(inner))}, {"title": "good", \#(start)}]}"#)))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true], "the row fails alone", file: file, line: line)
        let error = rows.first?["error"] as? String ?? ""
        XCTAssertTrue(error.contains(expected), "row: \(error)", file: file, line: line)
        let creates = await source.creates
        let updates = await source.updates
        XCTAssertEqual(creates.map(\.title), ["good"], file: file, line: line)
        XCTAssertTrue(updates.isEmpty, file: file, line: line)
    }

    func testAStructuredLocationRadiusOfZeroOrLessIsRefused() async throws {
        for radius in ["0", "-1", "-0.5"] {
            try await assertEveryEventToolRefuses(#", "latitude": 25, "longitude": 121, "radius": \#(radius)"#,
                                                  saying: "structured_location.radius must be greater than 0")
        }
    }

    func testAStructuredLocationWithOnlyOneCoordinateIsRefused() async throws {
        try await assertEveryEventToolRefuses(#", "latitude": 25"#,
                                              saying: "structured_location.longitude is required when latitude is given")
        try await assertEveryEventToolRefuses(#", "longitude": 121"#,
                                              saying: "structured_location.latitude is required when longitude is given")
    }

    func testCoordinatesOutOfRangeAreRefused() async throws {
        let latitude = "latitude must be a number from -90 to 90"
        let longitude = "longitude must be a number from -180 to 180"
        for (coordinates, expected) in [(#""latitude": 90.5, "longitude": 121"#, latitude),
                                        (#""latitude": -91, "longitude": 121"#, latitude),
                                        (#""latitude": 25, "longitude": 180.5"#, longitude),
                                        (#""latitude": 25, "longitude": -200"#, longitude)] {
            try await assertEveryEventToolRefuses(", \(coordinates)", saying: "structured_location.\(expected)")
            let source = RecordingReminderSource()
            let server = try await CheICalMCPServer(reminderWriteSource: source)
            for (tool, head) in [("create_reminder", #""title": "t""#), ("update_reminder", #""reminder_id": "r""#)] {
                let message = try await refusal(server, tool, "{\(head), \(trigger(coordinates + #", "proximity": "enter""#))}")
                XCTAssertTrue(message.contains("location_trigger.\(expected)"), "\(tool) \(coordinates): \(message)")
            }
            let created = await source.created
            let updated = await source.updated
            XCTAssertTrue(created.isEmpty && updated.isEmpty, "nothing was written")
        }
    }

    /// The bounds themselves are coordinates.
    func testCoordinatesOnTheBoundsAreTaken() async throws {
        let events = FakeEventWriteSource()
        let reminders = RecordingReminderSource()
        let server = try await CheICalMCPServer(eventWriteSource: events, reminderWriteSource: reminders)
        for coordinates in [#""latitude": 90, "longitude": -180"#, #""latitude": -90, "longitude": 180"#] {
            _ = try await server.executeToolCall(name: "create_event", arguments: decoded(#"{"title": "t", \#(start), \#(place(", " + coordinates))}"#))
            _ = try await server.executeToolCall(name: "create_reminder", arguments: decoded(
                #"{"title": "t", \#(trigger(coordinates + #", "proximity": "enter""#))}"#))
        }
        let creates = await events.creates
        let created = await reminders.created
        XCTAssertEqual(creates.map { $0.structuredLocation?.latitude }, [90, -90])
        XCTAssertEqual(created.map { $0.locationTrigger?.longitude }, [-180, 180])
    }

    // MARK: - priority

    func testAPriorityOutsideZeroToNineIsRefused() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        for priority in ["10", "-1", "100"] {
            for (tool, head) in [("create_reminder", #""title": "t""#), ("update_reminder", #""reminder_id": "r""#)] {
                let message = try await refusal(server, tool, #"{\#(head), "priority": \#(priority)}"#)
                XCTAssertTrue(message.contains("priority must be an integer from 0 to 9"), "\(tool) \(priority): \(message)")
            }
        }
        let created = await source.created
        let updated = await source.updated
        XCTAssertTrue(created.isEmpty && updated.isEmpty, "nothing was written")
    }

    func testABatchRowWithAPriorityOutsideZeroToNineFailsAlone() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        let batch = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: decoded(
            #"{"reminders": [{"title": "low", "priority": 9}, {"title": "bad", "priority": 10}, {"title": "none", "priority": 0}]}"#)))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true, false, true])
        let error = rows[1]["error"] as? String ?? ""
        XCTAssertTrue(error.contains("priority must be an integer from 0 to 9"), error)
        let created = await source.created
        XCTAssertEqual(created.map(\.title), ["low", "none"])
        XCTAssertEqual(created.map(\.priority), [9, 0])
    }

    /// "Omit or JSON null = default", as update_reminder already read it.
    func testANullPriorityIsOmittedOnAllThreeTools() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: decoded(#"{"title": "one", "priority": null}"#))
        let batch = try object(await server.executeToolCall(name: "create_reminders_batch", arguments: decoded(
            #"{"reminders": [{"title": "row", "priority": null}]}"#)))
        _ = try await server.executeToolCall(name: "update_reminder", arguments: decoded(#"{"reminder_id": "r", "priority": null}"#))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [true])
        let created = await source.created
        let updated = await source.updated
        XCTAssertEqual(created.map(\.priority), [0, 0], "the default")
        XCTAssertEqual(updated.map(\.priority), [nil], "left as it is")
    }

    // MARK: - data URL in a string array

    func testADataURLElementInAStringArrayIsExplained() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        let arguments = try decoded(#"{"title": "t", "tags": ["a", "data: 12 subjects, 3 dropped"]}"#)
        XCTAssertNil(arguments["tags"]?.arrayValue?.last?.stringValue, "the SDK's reading, which this test depends on")
        do {
            _ = try await server.executeToolCall(name: "create_reminder", arguments: arguments)
            XCTFail("took a data URL as a tag")
        } catch ToolError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("tags must be an array of strings"), message)
            XCTAssertTrue(message.contains("read as a data URL, not as text, so reword its start"), message)
            XCTAssertFalse(message.contains("12 subjects"), "#37: \(message)")
        }
        let problem = ToolArgumentCheck.rowProblem(
            tool: "create_reminders_batch", rowsKey: "reminders",
            row: try decoded(#"{"title": "t", "tags": ["data: 12 subjects, 3 dropped"]}"#), index: 1, checksKeys: false) ?? ""
        XCTAssertTrue(problem.hasPrefix("Row 1: tags must be an array of strings"), problem)
        XCTAssertTrue(problem.contains("data URL"), problem)
        let created = await source.created
        XCTAssertTrue(created.isEmpty)
    }

    /// An element of another type keeps the plain message.
    func testAWrongTypeElementKeepsThePlainMessage() {
        XCTAssertEqual(ToolArgumentCheck.expectedType(.array([.string("a"), .int(5)]),
                                                      schema: .object(["type": .string("array"), "items": .object(["type": .string("string")])])),
                       "an array of strings")
    }
}
