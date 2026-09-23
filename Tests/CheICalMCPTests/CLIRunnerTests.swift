import CheMCPKit
import EventKit
import Foundation
import MCP
import XCTest

@testable import CheICalMCP

final class CLIRunnerTests: XCTestCase {

    // MARK: - Flag-based arg parsing

    func testParseFlagArgs() throws {
        let args = ["--cli", "list_events", "--start_date", "2026-03-29", "--end_date", "2026-03-30"]
        let (tool, arguments) = try CLIRunner.parseArgs(args, usageName: "CheICalMCP")
        XCTAssertEqual(tool, "list_events")
        XCTAssertEqual(arguments["start_date"], "2026-03-29")
        XCTAssertEqual(arguments["end_date"], "2026-03-30")
    }

    func testParseFlagArgsNoArguments() throws {
        let args = ["--cli", "list_calendars"]
        let (tool, arguments) = try CLIRunner.parseArgs(args, usageName: "CheICalMCP")
        XCTAssertEqual(tool, "list_calendars")
        XCTAssertTrue(arguments.isEmpty)
    }

    func testParseFlagArgsBooleanFlag() throws {
        let args = ["--cli", "delete_events_batch", "--dry_run", "true", "--calendar_name", "Work"]
        let (tool, arguments) = try CLIRunner.parseArgs(args, usageName: "CheICalMCP")
        XCTAssertEqual(tool, "delete_events_batch")
        XCTAssertEqual(arguments["dry_run"], "true")
        XCTAssertEqual(arguments["calendar_name"], "Work")
    }

    func testParseFlagArgsMissingToolName() {
        let args = ["--cli"]
        XCTAssertThrowsError(try CLIRunner.parseArgs(args, usageName: "CheICalMCP")) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                msg.contains("tool name") || msg.contains("Tool"),
                "Error should mention missing tool name, got: \(msg)")
        }
    }

    func testParseFlagArgsDanglingKey() {
        let args = ["--cli", "list_events", "--start_date"]
        XCTAssertThrowsError(try CLIRunner.parseArgs(args, usageName: "CheICalMCP")) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(msg.contains("start_date"), "Error should mention the dangling key, got: \(msg)")
        }
    }

    // MARK: - Type inference (inferValue)

    func testInferValueBool() {
        XCTAssertEqual(CLIRunner.inferValue("true"), .bool(true))
        XCTAssertEqual(CLIRunner.inferValue("false"), .bool(false))
    }

    func testInferValueInt() {
        XCTAssertEqual(CLIRunner.inferValue("42"), .int(42))
        XCTAssertEqual(CLIRunner.inferValue("0"), .int(0))
        XCTAssertEqual(CLIRunner.inferValue("-1"), .int(-1))
    }

    func testInferValueDouble() {
        XCTAssertEqual(CLIRunner.inferValue("3.14"), .double(3.14))
        XCTAssertEqual(CLIRunner.inferValue("0.5"), .double(0.5))
    }

    func testInferValueString() {
        XCTAssertEqual(CLIRunner.inferValue("hello"), .string("hello"))
        XCTAssertEqual(CLIRunner.inferValue("2026-03-29"), .string("2026-03-29"))
    }

    func testInferValueJSONArray() {
        let result = CLIRunner.inferValue(#"["work","urgent"]"#)
        if case .array(let arr) = result {
            XCTAssertEqual(arr.count, 2)
            XCTAssertEqual(arr[0].stringValue, "work")
            XCTAssertEqual(arr[1].stringValue, "urgent")
        } else {
            XCTFail("Expected .array, got \(result)")
        }
    }

    func testInferValueJSONObject() {
        let result = CLIRunner.inferValue(#"{"key":"val"}"#)
        if case .object(let dict) = result {
            XCTAssertEqual(dict["key"]?.stringValue, "val")
        } else {
            XCTFail("Expected .object, got \(result)")
        }
    }

    // MARK: - toMCPArguments preserves types

    func testToMCPArgumentsTypeInference() {
        let args = ["dry_run": "true", "limit": "10", "name": "Work", "lat": "25.03"]
        // A tool without a schema entry: every value goes through inference, as before #223.
        let mcpArgs = CLIRunner.toMCPArguments(args, tool: "no_such_tool", tools: CheICalMCPServer.defineTools())
        XCTAssertEqual(mcpArgs["dry_run"]?.boolValue, true)
        XCTAssertEqual(mcpArgs["limit"]?.intValue, 10)
        XCTAssertEqual(mcpArgs["name"]?.stringValue, "Work")
        XCTAssertEqual(mcpArgs["lat"]?.doubleValue, 25.03)
    }

    // MARK: - JSON stdin parsing (string-based, legacy)

    func testParseJSONStdin() throws {
        let json = #"{"tool":"list_calendars","arguments":{}}"#
        let (tool, arguments) = try CLIRunner.parseJSONInput(json)
        XCTAssertEqual(tool, "list_calendars")
        XCTAssertTrue(arguments.isEmpty)
    }

    func testParseJSONStdinWithArguments() throws {
        let json = #"{"tool":"list_events","arguments":{"start_date":"2026-03-29","end_date":"2026-03-30"}}"#
        let (tool, arguments) = try CLIRunner.parseJSONInput(json)
        XCTAssertEqual(tool, "list_events")
        XCTAssertEqual(arguments["start_date"], "2026-03-29")
        XCTAssertEqual(arguments["end_date"], "2026-03-30")
    }

    func testParseJSONStdinMissingTool() {
        let json = #"{"arguments":{}}"#
        XCTAssertThrowsError(try CLIRunner.parseJSONInput(json)) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(msg.contains("tool"), "Error should mention missing tool field, got: \(msg)")
        }
    }

    func testParseJSONStdinMalformed() {
        let json = "not json at all"
        XCTAssertThrowsError(try CLIRunner.parseJSONInput(json))
    }

    // MARK: - JSON stdin with native types (parseJSONInputToValues)

    func testParseJSONInputToValuesPreservesTypes() throws {
        let json = #"{"tool":"create_event","arguments":{"title":"Test","all_day":true,"priority":3,"tags":["a","b"]}}"#
        let (tool, args) = try CLIRunner.parseJSONInputToValues(json)
        XCTAssertEqual(tool, "create_event")
        XCTAssertEqual(args["title"]?.stringValue, "Test")
        XCTAssertEqual(args["all_day"]?.boolValue, true)
        XCTAssertEqual(args["priority"]?.intValue, 3)
        XCTAssertEqual(args["tags"]?.arrayValue?.count, 2)
    }

    // MARK: - Help message

    func testHelpMessageIncludesCLIFlag() {
        let help = AppVersion.helpMessage
        XCTAssertTrue(help.contains("--cli"), "Help message should document the --cli flag")
    }

    // MARK: - Error sanitization (#37 verify Codex finding)

    func testFormatErrorForCLISanitizesFrameworkError() {
        // Codex medium finding: an EventKit-thrown NSError reaching CLI mode
        // must have its localizedDescription sanitized before stdout JSON.
        let appleErr = NSError(
            domain: EKErrorDomain,
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Apple-produced text MUST NOT appear on stdout"]
        )
        let (jsonMessage, rawLog) = KitConfiguration.formatCLIError(appleErr)

        XCTAssertTrue(
            jsonMessage.contains("eventkit_error_5"),
            "stdout must carry sanitized code; got \(jsonMessage)"
        )
        XCTAssertFalse(
            jsonMessage.contains("Apple-produced"),
            "stdout must not echo Apple localizedDescription; got \(jsonMessage)"
        )

        XCTAssertTrue(
            rawLog.contains("Apple-produced"),
            "stderr raw log preserves original text for operator debug"
        )
    }

    func testFormatErrorForCLIPreservesTrustedToolErrorMessage() {
        let err = ToolError.invalidParameter("calendar_name is required")
        let (jsonMessage, rawLog) = KitConfiguration.formatCLIError(err)

        XCTAssertTrue(jsonMessage.contains("Invalid parameter: calendar_name is required"))
        XCTAssertEqual(rawLog, "Invalid parameter: calendar_name is required")
    }

    func testFormatErrorForCLIPreservesTrustedCLIErrorMessage() {
        let err = CLIRunner.CLIError.missingToolName(usageName: "CheICalMCP")
        let (jsonMessage, _) = KitConfiguration.formatCLIError(err)
        XCTAssertTrue(jsonMessage.contains("Missing tool name"))
    }

    /// #223: the `--cli` error line keeps this server's `{"error":true,"message":…}` shape, not
    /// the package's `{"error":{"code","message"}}` envelope.
    func testCLIErrorLineKeepsTheLegacyShape() {
        let appleErr = NSError(domain: EKErrorDomain, code: 5, userInfo: [NSLocalizedDescriptionKey: "x"])
        XCTAssertEqual(KitConfiguration.formatCLIError(appleErr).jsonMessage, #"{"error":true,"message":"eventkit_error_5"}"#)
        XCTAssertEqual(KitConfiguration.formatCLIError(CLIRunner.CLIError.missingToolName(usageName: "CheICalMCP")).jsonMessage,
                       #"{"error":true,"message":"Missing tool name. Usage: CheICalMCP --cli <tool_name> [--key value ...]"}"#)
    }

    // MARK: - #223 intended changes

    /// String-typed schema parameters keep their text: `--keyword 007` searches "007", not 7.
    func testStringTypedParametersKeepNumericLookingValues() throws {
        let (tool, raw) = try CLIRunner.parseArgs(["CheICalMCP", "--cli", "search_events", "--keyword", "007", "--limit", "3"],
                                                  usageName: KitConfiguration.usageName)
        let args = CLIRunner.toMCPArguments(raw, tool: tool, tools: CheICalMCPServer.defineTools())
        XCTAssertEqual(args["keyword"], .string("007"))
        XCTAssertTrue(CLIRunner.stringTypedParameters(for: "search_events", in: CheICalMCPServer.defineTools()).contains("keyword"))
    }

    /// A stray positional argument is an error instead of being skipped silently.
    func testStrayPositionalArgumentIsRejected() {
        XCTAssertThrowsError(try CLIRunner.parseArgs(["CheICalMCP", "--cli", "list_events", "oops"], usageName: "CheICalMCP")) { error in
            XCTAssertEqual(error as? CLIRunner.CLIError, .unexpectedPositional)
        }
    }

    /// One JSON object after the tool name is accepted as the arguments.
    func testPositionalJSONObjectIsAccepted() throws {
        let parsed = try XCTUnwrap(try CLIRunner.parsePositionalJSON(["CheICalMCP", "--cli", "list_events", #"{"limit": 2}"#]))
        XCTAssertEqual(parsed.tool, "list_events")
        XCTAssertEqual(parsed.arguments["limit"], .int(2))
    }

    func testStdinJSONNullBecomesValueNull() throws {
        // #205: `null` means "omitted" everywhere; mapping it to "" would turn a
        // documented no-op into a rejected argument on the --cli surface.
        let (_, args) = try CLIRunner.parseJSONInputToValues(#"{"tool":"complete_reminder","arguments":{"reminder_id":"r","completed":null}}"#)
        guard case .null? = args["completed"] else { return XCTFail("expected Value.null, got \(String(describing: args["completed"]))") }
    }
}
