import XCTest
@testable import CheICalMCP

/// Tests for input validators used at MCP tool boundaries.
/// Validators must throw on invalid input — never silently drop or coerce.
final class InputValidationTests: XCTestCase {

    // MARK: - Helpers

    private func assertInvalidParameter(_ expression: @autoclosure () throws -> Void, messageContains needle: String? = nil, file: StaticString = #file, line: UInt = #line) {
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

    // MARK: - URL Scheme — accept

    func testAcceptsHTTPS() throws {
        try InputValidation.validateHTTPScheme("https://example.com")
    }

    func testAcceptsHTTP() throws {
        try InputValidation.validateHTTPScheme("http://example.com")
    }

    func testAcceptsMixedCaseScheme() throws {
        try InputValidation.validateHTTPScheme("HtTpS://example.com")
    }

    func testAcceptsUppercaseScheme() throws {
        try InputValidation.validateHTTPScheme("HTTPS://EXAMPLE.COM")
    }

    func testAcceptsHTTPSWithPath() throws {
        try InputValidation.validateHTTPScheme("https://example.com/path/to/resource?q=1#frag")
    }

    // MARK: - URL Scheme — reject

    func testRejectsJavascriptScheme() {
        assertInvalidParameter(
            try InputValidation.validateHTTPScheme("javascript:alert(1)"),
            messageContains: "http://"
        )
    }

    func testRejectsFileScheme() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme("file:///etc/passwd"))
    }

    func testRejectsDataScheme() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme("data:text/html,<script>alert(1)</script>"))
    }

    func testRejectsFTPScheme() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme("ftp://example.com"))
    }

    func testRejectsMailtoScheme() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme("mailto:user@example.com"))
    }

    func testRejectsVBScriptScheme() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme("vbscript:msgbox(1)"))
    }

    func testRejectsSchemelessRelativeURL() {
        // "//evil.example" has no scheme — must be rejected
        assertInvalidParameter(try InputValidation.validateHTTPScheme("//evil.example/path"))
    }

    func testRejectsEmptyString() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme(""))
    }

    func testRejectsBareDomain() {
        assertInvalidParameter(try InputValidation.validateHTTPScheme("example.com"))
    }

    func testRejectsLeadingWhitespace() {
        // URLComponents is lenient about whitespace in various positions.
        // Leading whitespace before the scheme must be rejected — an attacker
        // could try " javascript:" style payloads to bypass naive prefix checks.
        assertInvalidParameter(try InputValidation.validateHTTPScheme(" javascript:alert(1)"))
    }

    // MARK: - Length — accept boundaries

    func testAcceptsTitleAt255Chars() throws {
        let s = String(repeating: "a", count: 255)
        try InputValidation.validateLength(s, field: "title", max: InputValidation.maxTitleLength)
    }

    func testAcceptsEmptyString() throws {
        try InputValidation.validateLength("", field: "title", max: InputValidation.maxTitleLength)
    }

    func testAcceptsNotesAt65535Chars() throws {
        let s = String(repeating: "b", count: InputValidation.maxNotesLength)
        try InputValidation.validateLength(s, field: "notes", max: InputValidation.maxNotesLength)
    }

    func testAcceptsLocationAt1024Chars() throws {
        let s = String(repeating: "c", count: InputValidation.maxLocationLength)
        try InputValidation.validateLength(s, field: "location", max: InputValidation.maxLocationLength)
    }

    // MARK: - Length — reject over boundary

    func testRejectsTitleAt256Chars() {
        let s = String(repeating: "a", count: 256)
        assertInvalidParameter(
            try InputValidation.validateLength(s, field: "title", max: InputValidation.maxTitleLength),
            messageContains: "255"
        )
    }

    func testRejectsNotesAt65536Chars() {
        let s = String(repeating: "b", count: 65536)
        assertInvalidParameter(
            try InputValidation.validateLength(s, field: "notes", max: InputValidation.maxNotesLength),
            messageContains: "notes"
        )
    }

    func testRejectsLocationAt1025Chars() {
        let s = String(repeating: "c", count: 1025)
        assertInvalidParameter(
            try InputValidation.validateLength(s, field: "location", max: InputValidation.maxLocationLength)
        )
    }

    // MARK: - Length — Unicode semantics

    // Swift's String.count is grapheme-cluster based. These tests pin the
    // expectation: 255 emoji are 255 counted characters (even though each
    // occupies multiple UTF-16 code units), and 255 combining-character
    // composed graphemes are 255 counted characters.

    func testTitleWith255EmojiIsAccepted() throws {
        let s = String(repeating: "🎉", count: 255)
        try InputValidation.validateLength(s, field: "title", max: InputValidation.maxTitleLength)
    }

    func testTitleWith256EmojiIsRejected() {
        let s = String(repeating: "🎉", count: 256)
        assertInvalidParameter(try InputValidation.validateLength(s, field: "title", max: InputValidation.maxTitleLength))
    }

    func testTitleWithCombiningCharactersCountsAsGraphemes() throws {
        // "é" composed as e + U+0301 combining acute is 1 grapheme
        let combined = "e\u{0301}"
        XCTAssertEqual(combined.count, 1)
        let s = String(repeating: combined, count: 255)
        try InputValidation.validateLength(s, field: "title", max: InputValidation.maxTitleLength)
    }

    func testTitleWith255CJKCharsIsAccepted() throws {
        let s = String(repeating: "字", count: 255)
        try InputValidation.validateLength(s, field: "title", max: InputValidation.maxTitleLength)
    }

    // MARK: - Composite validators

    func testEventTextInputAllNilIsAccepted() throws {
        try InputValidation.validateEventTextInput(title: nil, notes: nil, location: nil, url: nil)
    }

    func testEventTextInputRejectsBadURL() {
        assertInvalidParameter(
            try InputValidation.validateEventTextInput(
                title: "OK", notes: nil, location: nil, url: "javascript:alert(1)"
            )
        )
    }

    func testEventTextInputRejectsOverlongTitle() {
        let longTitle = String(repeating: "a", count: 256)
        assertInvalidParameter(
            try InputValidation.validateEventTextInput(
                title: longTitle, notes: nil, location: nil, url: nil
            ),
            messageContains: "title"
        )
    }

    func testReminderTextInputRejectsLongNotes() {
        let longNotes = String(repeating: "x", count: 65536)
        assertInvalidParameter(
            try InputValidation.validateReminderTextInput(title: "OK", notes: longNotes),
            messageContains: "notes"
        )
    }

    func testReminderTextInputAllNilIsAccepted() throws {
        try InputValidation.validateReminderTextInput(title: nil, notes: nil)
    }
}
