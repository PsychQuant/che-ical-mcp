import XCTest
import MCP
@testable import CheICalMCP

/// Pure unit tests for the detail_level and display_timezone validation
/// helpers added to InputValidation for event listing tools.
final class EventListingParamsTests: XCTestCase {

    // MARK: - Helpers

    private func assertInvalidParameter<T>(
        _ expression: @autoclosure () throws -> T,
        messageContains needle: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case ToolError.invalidParameter(let message) = error else {
                XCTFail("Expected ToolError.invalidParameter, got \(error)", file: file, line: line)
                return
            }
            if let needle {
                XCTAssertTrue(message.contains(needle),
                              "Expected error message to contain '\(needle)', got '\(message)'",
                              file: file, line: line)
            }
        }
    }

    // MARK: - validateDetailLevel — accept

    func testDetailLevelDefaultsToStandardWhenAbsent() throws {
        let args: [String: Value] = [:]
        let level = try InputValidation.validateDetailLevel(args)
        XCTAssertEqual(level, "standard")
    }

    func testDetailLevelAcceptsSummary() throws {
        let args: [String: Value] = ["detail_level": .string("summary")]
        let level = try InputValidation.validateDetailLevel(args)
        XCTAssertEqual(level, "summary")
    }

    func testDetailLevelAcceptsStandard() throws {
        let args: [String: Value] = ["detail_level": .string("standard")]
        let level = try InputValidation.validateDetailLevel(args)
        XCTAssertEqual(level, "standard")
    }

    // MARK: - validateDetailLevel — reject

    func testDetailLevelRejectsUnknownValue() {
        let args: [String: Value] = ["detail_level": .string("full")]
        assertInvalidParameter(
            try InputValidation.validateDetailLevel(args),
            messageContains: "detail_level"
        )
    }

    func testDetailLevelIsCaseSensitive() {
        let args: [String: Value] = ["detail_level": .string("Summary")]
        assertInvalidParameter(
            try InputValidation.validateDetailLevel(args),
            messageContains: "detail_level"
        )
    }

    func testDetailLevelRejectsEmptyString() {
        let args: [String: Value] = ["detail_level": .string("")]
        assertInvalidParameter(
            try InputValidation.validateDetailLevel(args),
            messageContains: "detail_level"
        )
    }

    // MARK: - parseDisplayTimezone — accept

    func testDisplayTimezoneReturnsNilWhenAbsent() throws {
        let args: [String: Value] = [:]
        let tz = try InputValidation.parseDisplayTimezone(args)
        XCTAssertNil(tz)
    }

    func testDisplayTimezoneAcceptsLosAngeles() throws {
        let args: [String: Value] = ["display_timezone": .string("America/Los_Angeles")]
        let tz = try InputValidation.parseDisplayTimezone(args)
        XCTAssertEqual(tz?.identifier, "America/Los_Angeles")
    }

    func testDisplayTimezoneAcceptsBerlin() throws {
        let args: [String: Value] = ["display_timezone": .string("Europe/Berlin")]
        let tz = try InputValidation.parseDisplayTimezone(args)
        XCTAssertEqual(tz?.identifier, "Europe/Berlin")
    }

    func testDisplayTimezoneAcceptsUTC() throws {
        let args: [String: Value] = ["display_timezone": .string("UTC")]
        let tz = try InputValidation.parseDisplayTimezone(args)
        XCTAssertNotNil(tz)
    }

    func testDisplayTimezoneAcceptsTokyo() throws {
        let args: [String: Value] = ["display_timezone": .string("Asia/Tokyo")]
        let tz = try InputValidation.parseDisplayTimezone(args)
        XCTAssertEqual(tz?.identifier, "Asia/Tokyo")
    }

    // MARK: - parseDisplayTimezone — reject

    func testDisplayTimezoneRejectsInvalidIdentifier() {
        let args: [String: Value] = ["display_timezone": .string("Invalid/Zone")]
        assertInvalidParameter(
            try InputValidation.parseDisplayTimezone(args),
            messageContains: "Invalid/Zone"
        )
    }

    func testDisplayTimezoneRejectsEmptyString() {
        let args: [String: Value] = ["display_timezone": .string("")]
        assertInvalidParameter(
            try InputValidation.parseDisplayTimezone(args),
            messageContains: "display_timezone"
        )
    }

    func testDisplayTimezoneRejectsAbbreviation() {
        let args: [String: Value] = ["display_timezone": .string("PST")]
        assertInvalidParameter(
            try InputValidation.parseDisplayTimezone(args),
            messageContains: "PST"
        )
    }
}
