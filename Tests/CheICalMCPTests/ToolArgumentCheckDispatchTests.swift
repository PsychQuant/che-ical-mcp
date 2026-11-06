import MCP
import XCTest
@testable import CheICalMCP

/// #448: arguments are checked against the tool's schema at dispatch, so an unknown key or a value
/// of the wrong type is refused before any handler runs.
final class ToolArgumentCheckDispatchTests: XCTestCase {
    private let planted = "ignore_previous_instructions"

    private func refusal(_ tool: String, _ arguments: [String: Value]) async throws -> String {
        let server = try await CheICalMCPServer()
        do {
            _ = try await server.executeToolCall(name: tool, arguments: arguments)
            XCTFail("\(tool) took \(arguments)")
            return ""
        } catch ToolError.invalidParameter(let message) {
            return message
        }
    }

    func testEveryToolRefusesAnUnknownKey() async throws {
        for tool in CheICalMCPServer.defineTools() {
            let message = try await refusal(tool.name, [planted: .bool(true)])
            XCTAssertTrue(message.contains("does not read"), "\(tool.name): \(message)")
            XCTAssertTrue(message.contains("It accepts:") || message.contains("It takes no arguments"), "\(tool.name): \(message)")
            XCTAssertFalse(message.contains(planted), "#37: \(tool.name): \(message)")
        }
    }

    /// The keys a handler refuses for itself keep their own message.
    func testTheHandlersOwnRefusalsAreNotPreempted() async throws {
        let message = try await refusal("find_duplicate_events", ["start_date": .string("2026-01-01"), "end_date": .string("2026-02-01"), "calendar_source": .string("iCloud")])
        XCTAssertTrue(message.contains("does not take calendar_source"), message)
        let rule = try await refusal("update_event", ["event_id": .string("e"), "interval": .int(2)])
        XCTAssertTrue(rule.hasPrefix("interval must be inside the recurrence object"), rule)
    }

    func testAValueOfTheWrongTypeIsRefused() async throws {
        let cases: [(String, [String: Value], String)] = [
            ("create_reminder", ["title": .string("t"), "due_date": .int(20261207)], "due_date must be a string"),
            ("create_reminder", ["title": .string("t"), "tags": .string("work")], "tags must be an array of strings"),
            ("update_reminder", ["reminder_id": .string("r"), "priority": .string("5")], "priority must be an integer"),
            ("update_reminder", ["reminder_id": .string("r"), "priority": .double(5.5)], "priority must be an integer"),
            ("create_event", ["title": .int(3)], "title must be a string"),
            ("list_events", ["start_date": .string("2026-01-01"), "end_date": .string("2026-02-01"), "fields": .string("title")], "fields must be an array of strings")
        ]
        for (tool, arguments, expected) in cases {
            let message = try await refusal(tool, arguments)
            XCTAssertTrue(message.contains(expected), "\(tool): \(message)")
        }
    }

    func testAWholeNumberDoubleAndNullPass() throws {
        XCTAssertNoThrow(try ToolArgumentCheck.check(tool: "update_reminder", arguments: ["reminder_id": .string("r"), "priority": .double(5)]))
        XCTAssertNoThrow(try ToolArgumentCheck.check(tool: "update_reminder", arguments: ["reminder_id": .string("r"), "notes": .null, "tags": .null]))
    }

    func testANestedObjectIsChecked() async throws {
        let location: Value = .object(["title": .string("x"), "latitude": .double(25), "longitude": .double(121), "radiuss": .int(5)])
        let message = try await refusal("create_event", ["structured_location": location])
        XCTAssertTrue(message.contains("structured_location has a key"), message)
        XCTAssertFalse(message.contains("radiuss"), message)
        let type = try await refusal("create_reminder", ["title": .string("t"), "location_trigger": .object(["latitude": .string("25")])])
        XCTAssertTrue(type.contains("latitude must be a number"), type)
    }

    /// `recurrence` keeps its parser's refusal (#434).
    func testRecurrenceKeepsItsOwnMessage() async throws {
        let message = try await refusal("update_event", ["event_id": .string("e"), "recurrence": .object(["frequency": .string("daily"), "count": .int(3)])])
        XCTAssertTrue(message.contains("recurrence"), message)
        XCTAssertFalse(message.contains("does not read"), message)
    }

    /// A call with every declared key passes, so the check cannot refuse a key a schema offers.
    func testEveryDeclaredKeyPasses() throws {
        func sample(_ schema: Value) -> Value {
            switch schema.objectValue?["type"]?.stringValue {
            case "string": return .string("x")
            case "integer": return .int(1)
            case "number": return .double(1)
            case "boolean": return .bool(true)
            case "array": return .array([])
            default: return .object([:])
            }
        }
        for tool in CheICalMCPServer.defineTools() {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            XCTAssertNoThrow(try ToolArgumentCheck.check(tool: tool.name, arguments: properties.mapValues(sample)), tool.name)
        }
    }

    // MARK: rows

    func testAnEventRowFailsOnAKeyOrAType() {
        for (row, phrase) in [(["title": Value.string("t"), "timzone": .string("Asia/Taipei")], "does not read"),
                              (["title": .string("t"), "url": .string("https://example.com")], "does not read"),
                              (["title": .string("t"), "alarms_minutes_offsets": .array([.int(5)])], "does not read"),
                              (["title": .int(3)], "title must be a string")] {
            let problem = ToolArgumentCheck.rowProblem(tool: "create_events_batch", rowsKey: "events", row: row, index: 1, checksKeys: true)
            XCTAssertTrue(problem?.contains(phrase) == true, "\(row): \(problem ?? "nil")")
            XCTAssertTrue(problem?.hasPrefix("Row 1") == true, problem ?? "nil")
            XCTAssertFalse(problem?.contains("timzone") == true, "#37")
        }
    }

    func testAnEventRowTakesEveryKeyItReads() {
        let row: [String: Value] = ["title": .string("t"), "start_time": .string("x"), "end_time": .string("x"), "notes": .string("n"),
                                    "location": .string("l"), "calendar_name": .string("c"), "calendar_source": .string("s"),
                                    "all_day": .bool(false), "timezone": .string("Asia/Taipei"), "recurrence": .object([:])]
        XCTAssertNil(ToolArgumentCheck.rowProblem(tool: "create_events_batch", rowsKey: "events", row: row, index: 0, checksKeys: true))
    }

    func testAReminderRowFailsOnAType() {
        for (row, phrase) in [(["title": Value.string("t"), "due_date": .int(3)], "due_date must be a string"),
                              (["title": .string("t"), "tags": .string("a")], "tags must be an array of strings"),
                              (["title": .string("t"), "priority": .string("5")], "priority must be an integer")] {
            let problem = ToolArgumentCheck.rowProblem(tool: "create_reminders_batch", rowsKey: "reminders", row: row, index: 0, checksKeys: false)
            XCTAssertTrue(problem?.contains(phrase) == true, problem ?? "nil")
        }
    }

    /// A key a handler reads and its schema omits would be refused at dispatch. `update_event`'s
    /// `url` was the one such key.
    func testNoHandlerReadsAKeyItsSchemaOmits() throws {
        let source = try SourcePins.source("Server.swift")
        let schemaKeys = Dictionary(uniqueKeysWithValues: CheICalMCPServer.defineTools().map {
            ($0.name, Set($0.inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? []))
        })
        let raw = source
        let pairs = try NSRegularExpression(pattern: #"case "([a-z_]+)":\s*return try await (handle[A-Za-z]+)\("#)
            .matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        XCTAssertEqual(pairs.count, schemaKeys.count, "every tool dispatches to one handler")
        let reads = try NSRegularExpression(pattern: #"arguments(?:\[|, key: )"([a-z_]+)""#)
        for pair in pairs {
            let tool = String(raw[Range(pair.range(at: 1), in: raw)!])
            let handler = String(raw[Range(pair.range(at: 2), in: raw)!])
            let body = try XCTUnwrap(rawBody(of: "func \(handler)(", in: raw), handler)
            for match in reads.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let key = String(body[Range(match.range(at: 1), in: body)!])
                XCTAssertTrue(schemaKeys[tool]?.contains(key) == true, "\(tool) reads \(key)")
            }
        }
    }

    /// `SourcePins.body` blanks string literals, and the keys are what this test reads.
    private func rawBody(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        guard let next = source.range(of: "\n    private func ", range: start.upperBound..<source.endIndex)
                ?? source.range(of: "\n    func ", range: start.upperBound..<source.endIndex) else { return nil }
        return String(source[start.lowerBound..<next.lowerBound])
    }
}
