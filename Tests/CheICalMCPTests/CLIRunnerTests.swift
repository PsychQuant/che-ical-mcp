import EventKit
import Foundation
import MCP
import XCTest

@testable import CheICalMCP

final class CLIRunnerTests: XCTestCase {

    // MARK: - Flag-based arg parsing

    func testParseFlagArgs() throws {
        let args = ["--cli", "list_events", "--start_date", "2026-03-29", "--end_date", "2026-03-30"]
        let (tool, arguments) = try CLIRunner.parseArgs(args)
        XCTAssertEqual(tool, "list_events")
        XCTAssertEqual(arguments["start_date"], "2026-03-29")
        XCTAssertEqual(arguments["end_date"], "2026-03-30")
    }

    func testParseFlagArgsNoArguments() throws {
        let args = ["--cli", "list_calendars"]
        let (tool, arguments) = try CLIRunner.parseArgs(args)
        XCTAssertEqual(tool, "list_calendars")
        XCTAssertTrue(arguments.isEmpty)
    }

    func testParseFlagArgsBooleanFlag() throws {
        let args = ["--cli", "delete_events_batch", "--dry_run", "true", "--calendar_name", "Work"]
        let (tool, arguments) = try CLIRunner.parseArgs(args)
        XCTAssertEqual(tool, "delete_events_batch")
        XCTAssertEqual(arguments["dry_run"], "true")
        XCTAssertEqual(arguments["calendar_name"], "Work")
    }

    func testParseFlagArgsMissingToolName() {
        let args = ["--cli"]
        XCTAssertThrowsError(try CLIRunner.parseArgs(args)) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                msg.contains("tool name") || msg.contains("Tool"),
                "Error should mention missing tool name, got: \(msg)")
        }
    }

    func testParseFlagArgsDanglingKey() {
        let args = ["--cli", "list_events", "--start_date"]
        XCTAssertThrowsError(try CLIRunner.parseArgs(args)) { error in
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
        let mcpArgs = CLIRunner.toMCPArguments(args)
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
        let (jsonMessage, rawLog) = CLIRunner.formatErrorForCLI(appleErr)

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
        let (jsonMessage, rawLog) = CLIRunner.formatErrorForCLI(err)

        XCTAssertTrue(jsonMessage.contains("Invalid parameter: calendar_name is required"))
        XCTAssertEqual(rawLog, "Invalid parameter: calendar_name is required")
    }

    func testFormatErrorForCLIPreservesTrustedCLIErrorMessage() {
        let err = CLIRunner.CLIError.missingToolName
        let (jsonMessage, _) = CLIRunner.formatErrorForCLI(err)
        XCTAssertTrue(jsonMessage.contains("Missing tool name"))
    }
}
