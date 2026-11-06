import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #449: what `create_calendar` and `update_calendar` refuse before anything is written, and what
/// reaches the `CalendarWriteSource` seam.
private actor CalendarWriteFake: CalendarWriteSource {
    private(set) var created: [(title: String, entityType: EKEntityType)] = []
    private(set) var updated: [String?] = []

    func writeNewCalendar(title: String, entityType: EKEntityType, color: String?) async throws -> CalendarWriteValue {
        created.append((title, entityType))
        return CalendarWriteValue(title: title, identifier: "new", isDuplicate: false, storeDiffers: [])
    }

    func writeCalendarUpdate(identifier: String, title: String?, color: String?) async throws -> CalendarWriteValue {
        updated.append(title)
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

    func testCreateRefusesATitleThatWouldNotStay() async throws {
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
        XCTAssertEqual(updated, [nil], "a calendar of a longer title can still change color")
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
