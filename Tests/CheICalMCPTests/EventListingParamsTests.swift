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

    func testDisplayTimezoneRejectsESTAbbreviation() {
        // East-coast abbreviation. Foundation accepts "EST" but its semantics
        // (always GMT-5, no DST) differ from "America/New_York" (DST-aware).
        // Reject so consumers can't be silently surprised by DST behavior.
        let args: [String: Value] = ["display_timezone": .string("EST")]
        assertInvalidParameter(
            try InputValidation.parseDisplayTimezone(args),
            messageContains: "EST"
        )
    }

    func testDisplayTimezoneRejectsPosixStyleOffset() {
        // POSIX-style offset like "GMT+08:00" — Foundation accepts this but
        // it has no DST awareness and behaves differently than a city zone.
        let args: [String: Value] = ["display_timezone": .string("GMT+08:00")]
        assertInvalidParameter(
            try InputValidation.parseDisplayTimezone(args),
            messageContains: "GMT+08:00"
        )
    }

    func testDisplayTimezoneAcceptsAsiaTaipei() throws {
        // Region/City form is the canonical IANA shape — must always work.
        let args: [String: Value] = ["display_timezone": .string("Asia/Taipei")]
        let tz = try InputValidation.parseDisplayTimezone(args)
        XCTAssertEqual(tz?.identifier, "Asia/Taipei")
    }

    // MARK: - parseFieldsFilter — accept

    func testFieldsReturnsNilWhenAbsent() throws {
        let args: [String: Value] = [:]
        let fields = try InputValidation.parseFieldsFilter(args)
        XCTAssertNil(fields)
    }

    func testFieldsAcceptsSingleField() throws {
        let args: [String: Value] = ["fields": .array([.string("title")])]
        let fields = try InputValidation.parseFieldsFilter(args)
        XCTAssertEqual(fields, ["title"])
    }

    func testFieldsAcceptsMultipleFields() throws {
        let args: [String: Value] = ["fields": .array([.string("title"), .string("start_date_local"), .string("calendar")])]
        let fields = try InputValidation.parseFieldsFilter(args)
        XCTAssertEqual(fields, ["title", "start_date_local", "calendar"])
    }

    func testFieldsAcceptsAllValidFields() throws {
        let allFields = InputValidation.validEventFields
        let args: [String: Value] = ["fields": .array(allFields.sorted().map { .string($0) })]
        let fields = try InputValidation.parseFieldsFilter(args)
        XCTAssertEqual(fields, allFields)
    }

    // MARK: - parseFieldsFilter — reject

    func testFieldsRejectsEmptyArray() {
        let args: [String: Value] = ["fields": .array([])]
        assertInvalidParameter(
            try InputValidation.parseFieldsFilter(args),
            messageContains: "empty"
        )
    }

    func testFieldsRejectsUnknownFieldName() {
        let args: [String: Value] = ["fields": .array([.string("title"), .string("nonexistent")])]
        assertInvalidParameter(
            try InputValidation.parseFieldsFilter(args),
            messageContains: "nonexistent"
        )
    }

    func testFieldsRejectsMisspelledField() {
        let args: [String: Value] = ["fields": .array([.string("titel")])]
        assertInvalidParameter(
            try InputValidation.parseFieldsFilter(args),
            messageContains: "titel"
        )
    }

    func testFieldsRejectsNonStringElement() {
        // Pre-fix the Set(fieldsArray.compactMap { $0.stringValue }) silently
        // dropped non-string elements. This is the #28 R2-F1 type-coerce-bypass
        // class — must throw with the offending index, not silently drop.
        let args: [String: Value] = [
            "fields": .array([.string("title"), .int(123), .string("location")])
        ]
        assertInvalidParameter(
            try InputValidation.parseFieldsFilter(args),
            messageContains: "fields[1]"
        )
    }

    func testFieldsRejectsNonArray() {
        // M5: pre-fix `arguments["fields"]?.arrayValue` returned nil for
        // non-array inputs (e.g. `fields="title"` string), silently disabling
        // the filter. Must throw to surface the type confusion.
        let args: [String: Value] = ["fields": .string("title")]
        assertInvalidParameter(
            try InputValidation.parseFieldsFilter(args),
            messageContains: "array of strings"
        )
    }

    // MARK: - requireOptionalInt + requireOptionalLimit — accept

    func testLimitReturnsNilWhenAbsent() throws {
        let args: [String: Value] = [:]
        let limit = try InputValidation.requireOptionalLimit(args)
        XCTAssertNil(limit)
    }

    func testLimitAcceptsPositiveInt() throws {
        let args: [String: Value] = ["limit": .int(50)]
        let limit = try InputValidation.requireOptionalLimit(args)
        XCTAssertEqual(limit, 50)
    }

    func testLimitAcceptsWholeDouble() throws {
        // JSON clients sometimes promote integer literals to Double to avoid
        // precision loss. Whole-number doubles (5.0) should pass through.
        let args: [String: Value] = ["limit": .double(5.0)]
        let limit = try InputValidation.requireOptionalLimit(args)
        XCTAssertEqual(limit, 5)
    }

    func testLimitAcceptsCapBoundary() throws {
        let args: [String: Value] = ["limit": .int(10000)]
        let limit = try InputValidation.requireOptionalLimit(args)
        XCTAssertEqual(limit, 10000)
    }

    // MARK: - requireOptionalLimit — reject (loud-failure invariant #25)

    func testLimitRejectsString() {
        // Pre-fix the raw `arguments["limit"]?.intValue` extraction silently
        // dropped non-int inputs. This is the #25 loud-failure invariant: type
        // mismatch must throw, not coerce-to-nil-then-default.
        let args: [String: Value] = ["limit": .string("5")]
        assertInvalidParameter(
            try InputValidation.requireOptionalLimit(args),
            messageContains: "limit"
        )
    }

    func testLimitRejectsFractional() {
        // 5.5 is clearly not an integer — reject rather than truncate.
        let args: [String: Value] = ["limit": .double(5.5)]
        assertInvalidParameter(
            try InputValidation.requireOptionalLimit(args),
            messageContains: "integer"
        )
    }

    func testLimitRejectsZero() {
        // limit=0 means "give me zero events" — never a useful intent;
        // most likely an off-by-one bug. Reject rather than silently
        // returning empty results.
        let args: [String: Value] = ["limit": .int(0)]
        assertInvalidParameter(
            try InputValidation.requireOptionalLimit(args),
            messageContains: "> 0"
        )
    }

    func testLimitRejectsNegative() {
        let args: [String: Value] = ["limit": .int(-1)]
        assertInvalidParameter(
            try InputValidation.requireOptionalLimit(args),
            messageContains: "> 0"
        )
    }

    func testLimitRejectsAboveCap() {
        // Defense-in-depth against accidentally-massive responses.
        let args: [String: Value] = ["limit": .int(10001)]
        assertInvalidParameter(
            try InputValidation.requireOptionalLimit(args),
            messageContains: "10000"
        )
    }

    // MARK: - envelopeTimezoneIdentifier (M4)

    func testEnvelopeTimezoneEchoesDisplayTimezoneWhenSet() {
        // M4: when display_timezone is set, list_events_quick's envelope
        // `timezone` field must echo the requested zone — otherwise readers
        // see system tz while *_local fields render in the requested zone
        // (internally contradictory).
        let displayTz = TimeZone(identifier: "America/Los_Angeles")
        let envelope = InputValidation.envelopeTimezoneIdentifier(displayTimezone: displayTz)
        XCTAssertEqual(envelope, "America/Los_Angeles")
    }

    func testEnvelopeTimezoneFallsBackToSystemWhenNil() {
        // Pre-fix behavior preserved when display_timezone is absent.
        let envelope = InputValidation.envelopeTimezoneIdentifier(displayTimezone: nil)
        XCTAssertEqual(envelope, TimeZone.current.identifier)
    }
}
