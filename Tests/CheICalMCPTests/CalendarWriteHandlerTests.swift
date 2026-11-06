import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #449: what `create_calendar` and `update_calendar` refuse before anything is written, and what
/// reaches the `CalendarWriteSource` seam.
private actor CalendarWriteFake: CalendarWriteSource {
    private(set) var created: [(title: String, entityType: EKEntityType, color: String?)] = []
    private(set) var updated: [(identifier: String, title: String?, color: String?)] = []
    private let isDuplicate: Bool
    private let storeDiffers: [String]

    init(isDuplicate: Bool = false, storeDiffers: [String] = []) {
        self.isDuplicate = isDuplicate
        self.storeDiffers = storeDiffers
    }

    func writeNewCalendar(title: String, entityType: EKEntityType, color: String?) async throws -> CalendarWriteValue {
        created.append((title, entityType, color))
        return CalendarWriteValue(title: title, identifier: "new", isDuplicate: isDuplicate, storeDiffers: storeDiffers)
    }

    func writeCalendarUpdate(identifier: String, title: String?, color: String?) async throws -> CalendarWriteValue {
        updated.append((identifier, title, color))
        return CalendarWriteValue(title: title ?? "kept", identifier: identifier, isDuplicate: false, storeDiffers: [])
    }
}

final class CalendarWriteHandlerTests: XCTestCase {
    private let badTitles: [(String, String)] = [
        ("", "empty"), ("   ", "empty"), (" \n\t", "empty"),
        (String(repeating: "x", count: InputValidation.maxTitleLength + 1), "maximum length")
    ]

    private func refused(_ tool: String, _ args: [String: Value], _ phrase: String, _ fake: CalendarWriteFake) async throws {
        let server = try await CheICalMCPServer(calendarWriteSource: fake)
        do {
            _ = try await server.executeToolCall(name: tool, arguments: args)
            XCTFail("\(tool) took \(args)")
        } catch ToolError.invalidParameter(let message) {
            XCTAssertTrue(message.contains(phrase), message)
        }
    }

    func testCreateRefusesABlankOrOverLongTitle() async throws {
        for (title, phrase) in badTitles {
            let fake = CalendarWriteFake()
            try await refused("create_calendar", ["title": .string(title), "type": .string("event")], phrase, fake)
            let created = await fake.created
            XCTAssertTrue(created.isEmpty)
        }
    }

    func testUpdateRefusesTheSameTitles() async throws {
        for (title, phrase) in badTitles {
            let fake = CalendarWriteFake()
            try await refused("update_calendar", ["id": .string("c"), "title": .string(title)], phrase, fake)
            let updated = await fake.updated
            XCTAssertTrue(updated.isEmpty)
        }
    }

    /// Any other string used to make an event calendar, `Reminder` included, with no message.
    func testCreateRefusesAnUnknownType() async throws {
        for type in ["banana", "", "Event", "Reminder", "reminders", "calendar"] {
            let fake = CalendarWriteFake()
            try await refused("create_calendar", ["title": .string("t"), "type": .string(type)], "type must be 'event' or 'reminder'", fake)
            let created = await fake.created
            XCTAssertTrue(created.isEmpty, type)
        }
    }

    func testTheTwoTypesAndATitleAtTheLimitReachTheWrite() async throws {
        let longest = String(repeating: "x", count: InputValidation.maxTitleLength)
        for (type, entity) in [("event", EKEntityType.event), ("reminder", .reminder)] {
            for title in ["Work", " padded ", "日本語のカレンダー", longest] {
                let fake = CalendarWriteFake()
                let server = try await CheICalMCPServer(calendarWriteSource: fake)
                let text = try await server.executeToolCall(name: "create_calendar", arguments: ["title": .string(title), "type": .string(type)])
                let created = await fake.created
                XCTAssertEqual(created.map(\.title), [title])
                XCTAssertEqual(created.first?.entityType, entity)
                XCTAssertTrue(text.contains("\"created\""), text)
            }
        }
    }

    func testAnUpdateWithoutATitleIsNotChecked() async throws {
        let fake = CalendarWriteFake()
        let server = try await CheICalMCPServer(calendarWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_calendar", arguments: ["id": .string("c"), "color": .string("#FF5733")])
        let updated = await fake.updated
        XCTAssertEqual(updated.count, 1)
        XCTAssertNil(updated.first?.title, "a calendar of a longer title can still change color")
        XCTAssertEqual(updated.first?.color, "#FF5733")
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func testARenameAndAColorReachTheWrite() async throws {
        let fake = CalendarWriteFake()
        let server = try await CheICalMCPServer(calendarWriteSource: fake)
        let text = try await server.executeToolCall(name: "update_calendar", arguments: [
            "id": .string("c"), "title": .string("New name"), "color": .string("#112233")])
        let updated = await fake.updated
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.identifier, "c")
        XCTAssertEqual(updated.first?.title, "New name")
        XCTAssertEqual(updated.first?.color, "#112233")
        let body = try json(text)
        XCTAssertEqual(body["action"] as? String, "updated")
        XCTAssertEqual(body["calendar"] as? String, "New name")
    }

    func testAColorReachesTheCreate() async throws {
        let fake = CalendarWriteFake()
        let server = try await CheICalMCPServer(calendarWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_calendar", arguments: [
            "title": .string("t"), "type": .string("event"), "color": .string("#112233")])
        let created = await fake.created
        XCTAssertEqual(created.first?.color, "#112233")
    }

    func testADuplicateAnswersSkipped() async throws {
        let server = try await CheICalMCPServer(calendarWriteSource: CalendarWriteFake(isDuplicate: true))
        let body = try json(try await server.executeToolCall(name: "create_calendar", arguments: ["title": .string("t"), "type": .string("event")]))
        XCTAssertEqual(body["action"] as? String, "skipped")
        XCTAssertEqual(body["reason"] as? String, "duplicate")
        XCTAssertEqual(body["id"] as? String, "new")
    }

    func testStoreDiffersReachesTheResponse() async throws {
        let server = try await CheICalMCPServer(calendarWriteSource: CalendarWriteFake(storeDiffers: ["title"]))
        let body = try json(try await server.executeToolCall(name: "create_calendar", arguments: ["title": .string("t"), "type": .string("reminder")]))
        XCTAssertEqual(body["action"] as? String, "created")
        XCTAssertEqual(body["store_differs"] as? [String], ["title"])
    }

    /// The limit counts characters as `validateLength` does, so 255 emoji pass.
    func testTheLimitCountsCharacters() async throws {
        let title = String(repeating: "👨‍👩‍👧‍👦", count: InputValidation.maxTitleLength)
        let fake = CalendarWriteFake()
        let server = try await CheICalMCPServer(calendarWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_calendar", arguments: ["title": .string(title), "type": .string("event")])
        let created = await fake.created
        XCTAssertEqual(created.map(\.title), [title])
    }

    /// A title already in the account gets no exception: the handler does not read the store.
    func testALongTitleAlreadyInTheAccountIsRefusedWhenPassed() async throws {
        let long = String(repeating: "x", count: InputValidation.maxTitleLength + 1)
        let fake = CalendarWriteFake(isDuplicate: true)
        try await refused("create_calendar", ["title": .string(long), "type": .string("event")], "maximum length", fake)
        try await refused("update_calendar", ["id": .string("c"), "title": .string(long), "color": .string("#112233")], "maximum length", fake)
        let created = await fake.created, updated = await fake.updated
        XCTAssertTrue(created.isEmpty)
        XCTAssertTrue(updated.isEmpty)
    }

    /// The schema says what the handler does.
    func testTheSchemasStateTheLimitAndTheTypes() throws {
        let tools = CheICalMCPServer.defineTools()
        func property(_ tool: String, _ key: String) -> [String: Value] {
            tools.first { $0.name == tool }?.inputSchema.objectValue?["properties"]?.objectValue?[key]?.objectValue ?? [:]
        }
        for tool in ["create_calendar", "update_calendar"] {
            let description = property(tool, "title")["description"]?.stringValue ?? ""
            XCTAssertTrue(description.contains("1 to \(InputValidation.maxTitleLength) characters"), description)
        }
        XCTAssertEqual(property("create_calendar", "type")["enum"], .array([.string("event"), .string("reminder")]))
    }
}
