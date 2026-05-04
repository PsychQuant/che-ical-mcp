import EventKit
import Foundation
import XCTest
@testable import CheICalMCP

/// Unit tests for `EventKitErrorSanitizer` — the pure-function utility that
/// maps Swift `Error` values to stable string codes safe to embed in MCP
/// responses. See `openspec/changes/sanitize-eventkit-failure-errors/specs/`
/// for the requirements these tests pin.
final class EventKitErrorSanitizerTests: XCTestCase {

    // MARK: - EKErrorDomain → eventkit_error_<N>

    func testEventKitDomainProducesEventkitErrorN() {
        let err = NSError(domain: EKErrorDomain, code: 3, userInfo: nil)
        let result = EventKitErrorSanitizer.sanitize(err)
        XCTAssertEqual(result.code, "eventkit_error_3")
    }

    func testValueMappingTable() {
        let cases: [(domain: String, code: Int, expected: String)] = [
            (EKErrorDomain, 0, "eventkit_error_0"),
            (EKErrorDomain, 3, "eventkit_error_3"),
            (EKErrorDomain, 15, "eventkit_error_15"),
            ("NSCocoaErrorDomain", 256, "error_nscocoaerrordomain_256"),
            ("com.apple.foundation", 42, "error_foundation_42"),
            ("NSPOSIXErrorDomain", 1, "error_nsposixerrordomain_1"),
        ]
        for c in cases {
            let err = NSError(domain: c.domain, code: c.code, userInfo: nil)
            let result = EventKitErrorSanitizer.sanitize(err)
            XCTAssertEqual(
                result.code, c.expected,
                "domain=\(c.domain) code=\(c.code)"
            )
        }
    }

    // MARK: - Slug rules

    func testDomainSlugStripsDotPrefixAndNonAlnum() {
        let err = NSError(domain: "my-custom.sub-domain", code: 7, userInfo: nil)
        let result = EventKitErrorSanitizer.sanitize(err)
        XCTAssertEqual(result.code, "error_sub_domain_7")
    }

    func testSlugHandlesNonASCIIAndControlChars() {
        // Non-ASCII (日本) and zero-width space (U+200B) must collapse to `_`,
        // never appear in the output. The slug must be pure [a-z0-9_].
        let err = NSError(domain: "com.\u{65E5}\u{672C}.\u{200B}x", code: 9, userInfo: nil)
        let result = EventKitErrorSanitizer.sanitize(err)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        for scalar in result.code.unicodeScalars {
            XCTAssertTrue(
                allowed.contains(scalar),
                "scalar \(scalar) (U+\(String(scalar.value, radix: 16))) not in allow-list; full code=\(result.code)"
            )
        }
        XCTAssertTrue(result.code.hasSuffix("_9"))
    }

    // MARK: - userInfo isolation

    func testUserInfoIsNeverInterpolated() {
        let err = NSError(
            domain: EKErrorDomain,
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey: "Buy groceries at Whole Foods",
                NSLocalizedFailureReasonErrorKey: "Apartment 4B notes leaked",
                NSLocalizedRecoverySuggestionErrorKey: "Call Alice at 555-1234",
            ]
        )
        let result = EventKitErrorSanitizer.sanitize(err)
        XCTAssertEqual(result.code, "eventkit_error_5")
        for needle in ["Buy", "groceries", "Whole Foods", "Apartment", "notes leaked", "Alice", "555-1234"] {
            XCTAssertFalse(
                result.code.contains(needle),
                "code \(result.code) leaked substring \(needle)"
            )
        }
    }

    // MARK: - Negative codes (spec R4 invariant)

    func testNegativeCodeProducesPositiveMagnitude() {
        // Some Foundation domains (e.g. NSCocoaErrorDomain historically)
        // ship negative `NSError.code` values. The spec's response-value
        // regex `[0-9]+` doesn't admit the `-` sign, so the sanitizer
        // must encode magnitude only.
        let allowed = try! NSRegularExpression(
            pattern: #"^(eventkit_error_[0-9]+|error_[a-z0-9_]+_[0-9]+)$"#
        )
        let cases: [(domain: String, code: Int, contains: String)] = [
            (EKErrorDomain, -1, "eventkit_error_1"),
            (EKErrorDomain, Int.min + 1, "eventkit_error_"),
            ("NSCocoaErrorDomain", -42, "error_nscocoaerrordomain_42"),
        ]
        for c in cases {
            let err = NSError(domain: c.domain, code: c.code, userInfo: nil)
            let result = EventKitErrorSanitizer.sanitize(err)
            XCTAssertTrue(
                result.code.hasPrefix(c.contains),
                "domain=\(c.domain) code=\(c.code) → \(result.code), expected prefix \(c.contains)"
            )
            let nsRange = NSRange(location: 0, length: (result.code as NSString).length)
            XCTAssertNotNil(
                allowed.firstMatch(in: result.code, range: nsRange),
                "code \(result.code) violates spec regex"
            )
        }
    }

    // MARK: - Non-NSError Swift Error

    func testNonNSErrorSwiftErrorCollapses() {
        enum LocalError: Error { case foo }
        let result = EventKitErrorSanitizer.sanitize(LocalError.foo)
        // A Swift enum Error bridges to NSError with a synthetic
        // "ModuleName.TypeName" domain. Sanitizer must detect this and
        // collapse to a single literal — without leaking the type name.
        XCTAssertEqual(result.code, "error_unknown")
    }

    // MARK: - rawLog passthrough

    func testRawLogEqualsLocalizedDescription() {
        let err = NSError(
            domain: EKErrorDomain,
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (EKErrorDomain error 3.)"]
        )
        let result = EventKitErrorSanitizer.sanitize(err)
        XCTAssertEqual(result.rawLog, "The operation couldn't be completed. (EKErrorDomain error 3.)")
    }

    // MARK: - sanitizeForResponse trusted-vs-framework dispatch (#37)

    func testSanitizeForResponseTrustedErrorPassesThrough() {
        let err: any Error = ToolError.invalidParameter("foo")
        let result = EventKitErrorSanitizer.sanitizeForResponse(err)
        XCTAssertEqual(result.code, "Invalid parameter: foo")
        XCTAssertEqual(result.rawLog, result.code)
    }

    func testSanitizeForResponseFrameworkErrorMatchesSanitize() {
        let err: any Error = NSError(domain: EKErrorDomain, code: 3, userInfo: nil)
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForResponse(err),
            EventKitErrorSanitizer.sanitize(err)
        )
    }

    func testSanitizeForResponseFoundationLocalizedErrorTakesFrameworkBranch() {
        // URLError conforms to LocalizedError but is NOT TrustedErrorMessage —
        // we must not echo its localizedDescription (Apple-produced text)
        // verbatim. R5 negative case.
        let err: any Error = URLError(.notConnectedToInternet)
        let result = EventKitErrorSanitizer.sanitizeForResponse(err)
        XCTAssertTrue(
            result.code.hasPrefix("error_") || result.code == "error_unknown",
            "URLError should slug or unknown, got \(result.code)"
        )
        XCTAssertNotEqual(result.code, err.localizedDescription)
    }

    func testTrustedErrorMessageMarkerIsZeroRequirementProtocol() {
        // A function generic over TrustedErrorMessage with no constraints
        // beyond the marker should compile and accept any conformer without
        // calling any method on it. If the protocol grows a requirement,
        // this fails to compile.
        func acceptsAnyConformer<T: TrustedErrorMessage>(_ x: T) -> T { x }
        let preserved = acceptsAnyConformer(ToolError.invalidParameter("x"))
        XCTAssertEqual((preserved as Error).localizedDescription, "Invalid parameter: x")
    }

    func testThreeAuthorErrorTypesConformTrustedErrorMessage() {
        let toolErr: any Error = ToolError.invalidParameter("x")
        XCTAssertTrue(toolErr is TrustedErrorMessage)

        let ekErr: any Error = EventKitError.eventNotFound(identifier: "abc")
        XCTAssertTrue(ekErr is TrustedErrorMessage)

        let cliErr: any Error = CLIRunner.CLIError.missingToolName
        XCTAssertTrue(cliErr is TrustedErrorMessage)
    }

    func testNSErrorIsNotTrustedErrorMessage() {
        // R5 negative case at runtime: a raw NSError must NOT inherit the
        // marker by accident.
        let err: any Error = NSError(domain: EKErrorDomain, code: 3, userInfo: nil)
        XCTAssertFalse(err is TrustedErrorMessage)
    }

    func testTrustedErrorMessageConformerListIsCanonical() {
        // #40: explicit conformer registry. Any new conformance to
        // TrustedErrorMessage MUST extend the positive list below AND the
        // canonical list in `TrustedErrorMessage`'s doc comment. The negative
        // blocklist captures Foundation types whose `localizedDescription`
        // sources Apple-framework strings — these MUST NOT inherit trust.
        //
        // If a maintainer writes `extension URLError: TrustedErrorMessage {}`
        // to "fix" some unrelated bug, this test fails on the URLError
        // assertion and the failure message names the offender. "Fixing" the
        // test would require deleting the negative assertion, which is a
        // visible diff requiring code-review defense.

        // Positive: known module conformers
        let toolErr: any Error = ToolError.invalidParameter("x")
        XCTAssertTrue(toolErr is TrustedErrorMessage, "ToolError must conform")

        let ekErr: any Error = EventKitError.eventNotFound(identifier: "abc")
        XCTAssertTrue(ekErr is TrustedErrorMessage, "EventKitError must conform")

        let cliErr: any Error = CLIRunner.CLIError.missingToolName
        XCTAssertTrue(cliErr is TrustedErrorMessage, "CLIRunner.CLIError must conform")

        // Negative: well-known Foundation types must NOT conform — their
        // localizedDescription sources Apple-framework strings that may
        // interpolate user-controlled content (#21 / #27 threat class).
        let urlErr: any Error = URLError(.notConnectedToInternet)
        XCTAssertFalse(urlErr is TrustedErrorMessage,
                       "URLError MUST NOT conform — Apple-framework text")

        let posixErr: any Error = POSIXError(.EINVAL)
        XCTAssertFalse(posixErr is TrustedErrorMessage,
                       "POSIXError MUST NOT conform — Apple-framework text")

        let cocoaErr: any Error = CocoaError(.fileReadNoSuchFile)
        XCTAssertFalse(cocoaErr is TrustedErrorMessage,
                       "CocoaError MUST NOT conform — Apple-framework text")

        let nsErrCustom: any Error = NSError(domain: "com.example.foo", code: 1)
        XCTAssertFalse(nsErrCustom is TrustedErrorMessage,
                       "raw NSError MUST NOT conform")

        // EKError is the highest-priority gap to pin: its localizedDescription
        // sources Apple-framework text that may interpolate EKCalendar.title
        // from CalDAV-shared calendars (#21 / #27 threat class). A maintainer
        // who adds `extension EKError: TrustedErrorMessage {}` would directly
        // expose the same surface F1 already had to fix.
        let ekDomainErr: any Error = NSError(domain: EKErrorDomain, code: 3)
        XCTAssertFalse(ekDomainErr is TrustedErrorMessage,
                       "NSError(domain: EKErrorDomain) MUST NOT conform")

        // Codable error types — also LocalizedError-conforming, also
        // Apple-controlled text (DecodingError context paths can echo JSON
        // structure including user-supplied field names).
        let decodeErr: any Error = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "x")
        )
        XCTAssertFalse(decodeErr is TrustedErrorMessage,
                       "DecodingError MUST NOT conform — Apple-framework text")

        let encodeErr: any Error = EncodingError.invalidValue(
            "x", EncodingError.Context(codingPath: [], debugDescription: "x")
        )
        XCTAssertFalse(encodeErr is TrustedErrorMessage,
                       "EncodingError MUST NOT conform — Apple-framework text")
    }

    // MARK: - F1 trust contract pin (#37 verify P1 fix)

    func testEventKitErrorCalendarNotFoundDoesNotInterpolateAvailable() {
        // F1: calendarNotFound's `available` parameter holds EKCalendar.title
        // strings sourced from CalendarStore — including shared/subscribed/
        // CalDAV calendars whose titles are set by remote publishers (#21/#27
        // threat class). The errorDescription MUST NOT include `available[]`
        // content, otherwise the TrustedErrorMessage conformance lies.
        let attackerTitle = "ATTACKER_PAYLOAD_should_not_appear"
        let err = EventKitError.calendarNotFound(
            identifier: "Personal",
            available: ["Personal Work", "Family", attackerTitle]
        )
        let result = EventKitErrorSanitizer.sanitizeForResponse(err)
        XCTAssertEqual(result.code, "Calendar not found: Personal")
        XCTAssertFalse(
            result.code.contains(attackerTitle),
            "calendarNotFound trust path must NOT include available[] content; got \(result.code)"
        )
    }

    func testEventKitErrorCalendarNotFoundWithSourceDoesNotInterpolateAvailable() {
        let attackerTitle = "ATTACKER_PAYLOAD_should_not_appear"
        let err = EventKitError.calendarNotFoundWithSource(
            name: "Personal",
            source: "iCloud",
            available: ["Personal Work", attackerTitle]
        )
        let result = EventKitErrorSanitizer.sanitizeForResponse(err)
        XCTAssertEqual(result.code, "Calendar 'Personal' not found in source 'iCloud'")
        XCTAssertFalse(result.code.contains(attackerTitle))
    }

    func testEventKitErrorCalendarNotFoundReadOnlyEchoesUserIdentifier() {
        // Codex high finding: pre-fix updateCalendar/copyEvent built the
        // error from `calendar.title` (CalendarStore-sourced). Post-fix the
        // error must echo only the caller's `identifier`, never the
        // EventKit-supplied title. Trust path is now honest for read-only
        // refusals.
        let attackerTitle = "ATTACKER_CALENDAR_TITLE_should_not_appear"
        let userIdentifier = "calendar-uuid-1234"
        // Simulate the post-fix throw: identifier is user input + author suffix
        let err = EventKitError.calendarNotFound(identifier: "\(userIdentifier) (read-only)")
        let result = EventKitErrorSanitizer.sanitizeForResponse(err)
        XCTAssertTrue(result.code.contains(userIdentifier))
        XCTAssertTrue(result.code.contains("read-only"))
        XCTAssertFalse(
            result.code.contains(attackerTitle),
            "read-only refusal must not echo CalendarStore-sourced titles; got \(result.code)"
        )
    }

    func testEventKitErrorMultipleCalendarsFoundDoesNotInterpolateSources() {
        let attackerSource = "ATTACKER_SOURCE_payload"
        let err = EventKitError.multipleCalendarsFound(
            name: "Personal",
            sources: "iCloud, exchange.evil.com, \(attackerSource)"
        )
        let result = EventKitErrorSanitizer.sanitizeForResponse(err)
        XCTAssertFalse(
            result.code.contains(attackerSource),
            "multipleCalendarsFound trust path must NOT include sources content; got \(result.code)"
        )
        XCTAssertTrue(result.code.contains("Personal"))
    }

    // MARK: - writeFailureLog (#37)

    func testWriteFailureLogReturnsSanitizedCode() {
        let err = NSError(domain: EKErrorDomain, code: 7, userInfo: nil)
        let code = EventKitErrorSanitizer.writeFailureLog(
            handler: "h",
            identifier: "i",
            error: err
        )
        XCTAssertEqual(code, "eventkit_error_7")
    }

    func testWriteFailureLogTrustedReturnsOriginalMessage() {
        let err = ToolError.invalidParameter("foo")
        let code = EventKitErrorSanitizer.writeFailureLog(
            handler: "h",
            identifier: "i",
            error: err
        )
        XCTAssertEqual(code, "Invalid parameter: foo")
    }

    func testWriteFailureLogReturnValueDoesNotEscapeControlChars() {
        // The returned `code` value is the sanitized response code, untouched.
        // For TrustedErrorMessage conformers, #41's carve-out skips stderr
        // entirely — so this test now only exercises the wire-response
        // identity invariant: trusted error → return value preserves text
        // verbatim including control chars (which is acceptable on the wire
        // since MCP `text` content is JSON-encoded, not line-oriented).
        struct WithNewline: LocalizedError, TrustedErrorMessage {
            var errorDescription: String? { "line1\nline2" }
        }
        let code = EventKitErrorSanitizer.writeFailureLog(
            handler: "h",
            identifier: "i",
            error: WithNewline()
        )
        XCTAssertEqual(code, "line1\nline2", "wire response value preserves original text verbatim for trusted errors")
    }
}
