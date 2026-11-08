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

/// PR #463 verify: what a value that passes `ToolArgumentCheck` becomes in the handler. The
/// arguments are decoded from JSON here, as they arrive over MCP: `Value` tries Int first, so a
/// test that builds `.double(25)` shows a value no client can send.
final class ArgumentValueHandlerTests: XCTestCase {
    private func decoded(_ json: String) throws -> [String: Value] {
        try JSONDecoder().decode([String: Value].self, from: Data(json.utf8))
    }

    private func object(_ raw: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private let start = #""start_time": "2027-04-10T09:00:00", "end_time": "2027-04-10T10:00:00", "calendar_name": "Work""#

    /// The premise of this file, on the SDK this package pins.
    func testAWholeNumberDecodesAsAnInt() throws {
        let values = try decoded(#"{"plain": 500, "point": 500.0, "exponent": 1e2, "fraction": 5.5}"#)
        XCTAssertEqual(values["plain"], .int(500))
        XCTAssertEqual(values["point"], .int(500))
        XCTAssertEqual(values["exponent"], .int(100))
        XCTAssertEqual(values["fraction"], .double(5.5))
    }

    func testALocationTriggerKeepsAWholeNumber() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        let trigger = #""location_trigger": {"title": "Lab", "latitude": 25, "longitude": 121.0, "radius": 500, "proximity": "enter"}"#
        _ = try await server.executeToolCall(name: "create_reminder", arguments: decoded(#"{"title": "t", \#(trigger)}"#))
        _ = try await server.executeToolCall(name: "update_reminder", arguments: decoded(#"{"reminder_id": "r", \#(trigger)}"#))
        let written = [await source.created.first?.locationTrigger, await source.updated.first?.locationTrigger]
        for location in written {
            XCTAssertEqual(location?.latitude, 25)
            XCTAssertEqual(location?.longitude, 121)
            XCTAssertEqual(location?.radius, 500)
        }
    }

    func testALocationTriggerKeepsAFractionAndItsDefault() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: decoded(
            #"{"title": "t", "location_trigger": {"title": "Lab", "latitude": 25.03, "longitude": 121.56, "proximity": "leave"}}"#))
        let location = await source.created.first?.locationTrigger
        XCTAssertEqual(location?.latitude, 25.03)
        XCTAssertEqual(location?.radius, 100, "not given: the documented default")
    }

    func testAStructuredLocationKeepsAWholeNumber() async throws {
        let source = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: source)
        let location = #""structured_location": {"title": "Lab", "latitude": 25, "longitude": 121, "radius": 200}"#
        _ = try await server.executeToolCall(name: "create_event", arguments: decoded(#"{"title": "t", \#(start), \#(location)}"#))
        _ = try await server.executeToolCall(name: "update_event", arguments: decoded(#"{"event_id": "e", \#(location)}"#))
        _ = try await server.executeToolCall(name: "create_events_batch", arguments: decoded(#"{"events": [{"title": "row", \#(start), \#(location)}]}"#))
        let creates = await source.creates
        let updates = await source.updates
        XCTAssertEqual(creates.count, 2)
        for written in creates.map(\.structuredLocation) + updates.map(\.structuredLocation) {
            XCTAssertEqual(written?.latitude, 25)
            XCTAssertEqual(written?.longitude, 121)
            XCTAssertEqual(written?.radius, 200)
        }
    }

    /// The schema requires `title`; without it the location was dropped with no message.
    func testAStructuredLocationWithoutATitleIsRefused() async throws {
        let source = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: source)
        let location = #""structured_location": {"latitude": 25.03, "longitude": 121.5}"#
        for (tool, json) in [("create_event", #"{"title": "t", \#(start), \#(location)}"#), ("update_event", #"{"event_id": "e", \#(location)}"#)] {
            do {
                _ = try await server.executeToolCall(name: tool, arguments: decoded(json))
                XCTFail("\(tool) took a location without a title")
            } catch ToolError.invalidParameter(let message) {
                XCTAssertTrue(message.contains("structured_location.title is required"), message)
            }
        }
        let batch = try object(await server.executeToolCall(name: "create_events_batch", arguments: decoded(
            #"{"events": [{"title": "bad", \#(start), \#(location)}, {"title": "good", \#(start)}]}"#)))
        let rows = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["success"] as? Bool }, [false, true], "the row fails alone")
        let creates = await source.creates
        XCTAssertEqual(creates.map(\.title), ["good"])
        let updates = await source.updates
        XCTAssertTrue(updates.isEmpty)
    }

    /// `.double(5)` cannot come from a client today; the check passes it, so the handler reads it.
    func testAWholeNumberDoublePriorityIsReadAndNullIsAbsent() async throws {
        let source = RecordingReminderSource()
        let server = try await CheICalMCPServer(reminderWriteSource: source)
        _ = try await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "priority": .double(5)])
        _ = try await server.executeToolCall(name: "update_reminder", arguments: ["reminder_id": .string("r"), "priority": .null])
        let priorities = await source.updated.map(\.priority)
        XCTAssertEqual(priorities, [5, nil])
    }

    /// The elements were dropped by `compactMap`, behind a message that promises they are checked.
    func testAWrongArrayElementIsRefusedBeforeTheHandler() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource(), reminderWriteSource: RecordingReminderSource())
        let cases: [(String, String, String)] = [
            ("create_reminder", #"{"title": "t", "tags": [5]}"#, "tags must be an array of strings"),
            ("update_reminder", #"{"reminder_id": "r", "tags": ["a", 5]}"#, "tags must be an array of strings"),
            ("create_reminder", #"{"title": "t", "tags": [null]}"#, "tags must be an array of strings"),
            ("delete_reminders_batch", #"{"reminder_ids": ["a", 5]}"#, "reminder_ids must be an array of strings"),
            ("delete_events_batch", #"{"event_ids": ["a", 5]}"#, "event_ids must be an array of strings"),
            ("create_reminder", #"{"title": "t", "due_date": "2027-01-01T09:00:00", "alarms_minutes_offsets": ["5"]}"#, "alarms_minutes_offsets must be an array of integers"),
            ("create_reminder", #"{"title": "t", "due_date": "2027-01-01T09:00:00", "alarms_minutes_offsets": [1.5]}"#, "alarms_minutes_offsets must be an array of integers")
        ]
        for (tool, json, expected) in cases {
            do {
                _ = try await server.executeToolCall(name: tool, arguments: decoded(json))
                XCTFail("\(tool) took \(json)")
            } catch ToolError.invalidParameter(let message) {
                XCTAssertTrue(message.contains(expected), "\(tool): \(message)")
            }
        }
        XCTAssertNoThrow(try ToolArgumentCheck.check(tool: "create_reminder", arguments: decoded(
            #"{"title": "t", "tags": ["a", "b"], "alarms_minutes_offsets": [5, -5]}"#)))
    }

    /// `occurrence_dates` declares several item types, so its elements stay with the handler.
    func testARowFailsAloneOnAWrongElement() {
        let problem = ToolArgumentCheck.rowProblem(tool: "create_reminders_batch", rowsKey: "reminders",
                                                   row: ["title": .string("t"), "tags": .array([.int(5)])], index: 2, checksKeys: false)
        XCTAssertEqual(problem, "Row 2: tags must be an array of strings.")
    }

    /// The caller sent a string and the SDK decoded it as data; "must be a string" gave no way out.
    func testTextShapedLikeADataURLIsNamed() async throws {
        let server = try await CheICalMCPServer(reminderWriteSource: RecordingReminderSource())
        let arguments = try decoded(#"{"title": "t", "notes": "data: 12 subjects, 3 dropped"}"#)
        XCTAssertNil(arguments["notes"]?.stringValue, "the SDK's reading, which this test depends on")
        do {
            _ = try await server.executeToolCall(name: "create_reminder", arguments: arguments)
            XCTFail("took a data URL as notes")
        } catch ToolError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("notes must be a string"), message)
            XCTAssertTrue(message.contains("data URL"), message)
            XCTAssertFalse(message.contains("12 subjects"), "#37: \(message)")
        }
    }

    /// The parser's message has the example; the check must not get there first (#184, #434).
    func testANonObjectRecurrenceKeepsItsParsersMessage() async throws {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource(), reminderWriteSource: RecordingReminderSource())
        for (tool, arguments) in [("update_event", ["event_id": Value.string("e"), "recurrence": .string("daily")]),
                                  ("update_reminder", ["reminder_id": .string("r"), "recurrence": .string("daily")])] {
            do {
                _ = try await server.executeToolCall(name: tool, arguments: arguments)
                XCTFail("\(tool) took a string rule")
            } catch ToolError.invalidParameter(let message) {
                XCTAssertTrue(message.contains(#"e.g. {"frequency": "daily"}"#), "\(tool): \(message)")
            }
        }
    }

    /// README and CHANGELOG: the check treats null as absent on a declared key; a handler may still
    /// refuse it, and an undeclared key is refused whatever its value.
    func testWhatNullMeans() async throws {
        XCTAssertNoThrow(try ToolArgumentCheck.check(tool: "update_reminder", arguments: ["reminder_id": .string("r"), "notes": .null]))
        XCTAssertThrowsError(try ToolArgumentCheck.check(tool: "create_reminder", arguments: ["title": .string("t"), "url": .null]), "undeclared")
        let server = try await CheICalMCPServer()
        do {
            _ = try await server.executeToolCall(name: "list_reminders", arguments: ["limit": .null])
            XCTFail("the handler refuses a null limit")
        } catch ToolError.invalidParameter(let message) {
            XCTAssertTrue(message.contains("limit must be an integer"), message)
        }
    }
}
