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

    // MARK: - Length cap on rawLog (#86)

    /// Pin the cap at `EventKitErrorSanitizer.maxRawLogChars`. A framework
    /// `NSError.localizedDescription` of arbitrary length must not write the
    /// full text to stderr — the cap fires before `escapeForStderr` (escape
    /// inflation can't expand the budget) and a `…[truncated N chars]` suffix
    /// tells operators the original size. DoS-amplification residual closure
    /// for batch handlers (Server.swift sites) per #86.
    func testWriteFailureLogTruncatesLongRawLog() {
        let cap = EventKitErrorSanitizer.maxRawLogChars
        // Build a payload well above the cap. Use a non-special-char repeating
        // body so escape doesn't change the length and the assertion stays
        // comparable to the cap value itself.
        let oversize = String(repeating: "A", count: cap + 1000)
        let evilError = NSError(
            domain: EKErrorDomain,
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: oversize]
        )

        // #83 — migrated to shared withCapturedStderr helper.
        let captured = capturedStderr {
            _ = EventKitErrorSanitizer.writeFailureLog(
                handler: "TestHandler",
                identifier: "id",
                error: evilError
            )
        }

        XCTAssertFalse(captured.isEmpty, "untrusted NSError must write a stderr line")
        XCTAssertTrue(
            captured.hasPrefix("TestHandler(id) failed:"),
            "stderr line must use canonical (handler)(identifier) failed: shape; got: \(captured.debugDescription)"
        )
        // Cap fires: the full oversize text must NOT appear; instead we see
        // the truncation marker.
        XCTAssertTrue(
            captured.contains("[truncated"),
            "captured stderr must contain '[truncated N chars]' suffix when rawLog exceeds cap; got: \(captured.debugDescription)"
        )
        // The line itself should be cap + a small fixed overhead (handler
        // prefix + suffix annotation + terminator). Cap of 1024 → line ≤ ~1100.
        XCTAssertLessThanOrEqual(
            captured.count,
            cap + 200,
            "captured stderr line length \(captured.count) exceeds expected envelope (cap=\(cap) + ~200 char overhead for prefix/suffix)"
        )
    }

    /// Pin the off-by-one boundary: `count == cap` must NOT trigger
    /// truncation; `count == cap + 1` MUST trigger it. Existing tests
    /// (long: cap+1000, short: ~11) prove the operator works "somewhere
    /// between"; this test pins the equality boundary so a future refactor
    /// flipping `>` → `>=` (or vice versa) gets caught (#86 verify DA2).
    func testWriteFailureLogTruncationBoundary() {
        let cap = EventKitErrorSanitizer.maxRawLogChars

        // Case 1: count == cap → no truncation. #83 — migrated to harness.
        let exactCap = String(repeating: "B", count: cap)
        let exactCapError = NSError(
            domain: EKErrorDomain,
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: exactCap]
        )
        let cap1 = capturedStderr {
            _ = EventKitErrorSanitizer.writeFailureLog(handler: "h", identifier: "i", error: exactCapError)
        }
        XCTAssertFalse(
            cap1.contains("[truncated"),
            "rawLog of exactly cap chars must NOT trigger truncation; got: \(cap1.prefix(80))..."
        )

        // Case 2: count == cap + 1 → truncation by exactly 1 char.
        let capPlusOne = String(repeating: "C", count: cap + 1)
        let capPlusOneError = NSError(
            domain: EKErrorDomain,
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: capPlusOne]
        )
        let cap2 = capturedStderr {
            _ = EventKitErrorSanitizer.writeFailureLog(handler: "h", identifier: "i", error: capPlusOneError)
        }
        XCTAssertTrue(
            cap2.contains("[truncated 1 chars]"),
            "rawLog of cap+1 chars must trigger truncation by exactly 1 char; got: \(cap2.prefix(80))..."
        )
    }

    func testWriteFailureLogDoesNotTruncateShortRawLog() {
        // Sanity: short rawLog passes through unchanged (no spurious truncation).
        // #83 — migrated to harness.
        let shortError = NSError(
            domain: EKErrorDomain,
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "small error"]
        )

        let captured = capturedStderr {
            _ = EventKitErrorSanitizer.writeFailureLog(
                handler: "TestHandler",
                identifier: "id",
                error: shortError
            )
        }

        XCTAssertFalse(
            captured.contains("[truncated"),
            "short rawLog must not trigger truncation marker; got: \(captured.debugDescription)"
        )
        XCTAssertTrue(
            captured.contains("small error"),
            "short rawLog should appear verbatim (after escape); got: \(captured.debugDescription)"
        )
    }

    // MARK: - escapeForStderr full C0+DEL coverage (#73)

    /// Pin ESC `\x1b` (ANSI escape introducer) → `\x1b` literal.
    /// Pre-#73 escape only handled `\\` `\n` `\r`; ESC passed verbatim,
    /// allowing terminal-control injection via `\x1b[2J\x1b[H` (clear screen
    /// + home cursor) when an attacker controls `localizedDescription`
    /// (e.g. via event title surfacing in EKError text).
    func testEscapeForStderrEscapesEscapeChar() {
        XCTAssertEqual(
            EventKitErrorSanitizer.escapeForStderr("\u{001B}"),
            "\\x1b",
            "ESC must escape to literal \\x1b"
        )
    }

    /// Pin NUL `\x00` → `\x00`. NUL truncates C-string log readers
    /// (e.g. `tail` writing to `syslog`), so unescaped NUL hides
    /// subsequent legit output even before reaching a terminal.
    func testEscapeForStderrEscapesNull() {
        XCTAssertEqual(
            EventKitErrorSanitizer.escapeForStderr("foo\u{0000}bar"),
            "foo\\x00bar"
        )
    }

    /// Pin BS `\x08` (backspace), DEL `\x7f`, BEL `\x07` — all C0
    /// controls + DEL must be hex-escaped.
    func testEscapeForStderrEscapesC0AndDEL() {
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{0008}"), "\\x08")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{0007}"), "\\x07")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{007F}"), "\\x7f")
        // VT, FF, SO, SI — sample mid-range C0
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{000B}"), "\\x0b")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{000C}"), "\\x0c")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{000E}"), "\\x0e")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{001F}"), "\\x1f")
    }

    /// Pin the C1 control band (`\x80..\x9F`) — must be hex-escaped (#150).
    /// The 8-bit CSI introducer `\x9B` is the alternate form of `ESC [` and
    /// can drive the same terminal-hijack sequences as 7-bit ESC, so it must
    /// not reach the terminal verbatim. Printable scalars start at `\xA0`
    /// (NBSP), so the whole `\x80..\x9F` range is control-only.
    func testEscapeForStderrEscapesC1Controls() {
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{0080}"), "\\x80")  // PAD — band start
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{009B}"), "\\x9b")  // CSI (8-bit ≡ ESC [)
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{009F}"), "\\x9f")  // APC — band end
        // 8-bit CSI clear-screen attack must be fully neutralized.
        let attack = "foo\u{009B}2J\u{009B}Hbar"
        let safe = EventKitErrorSanitizer.escapeForStderr(attack)
        XCTAssertFalse(safe.unicodeScalars.contains { (0x80...0x9F).contains($0.value) },
            "no raw C1 control may survive escape; got: \(safe.debugDescription)")
        XCTAssertEqual(safe, "foo\\x9b2J\\x9bHbar")
        // Boundary: NBSP (\xA0, first printable above C1) must pass through unchanged.
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\u{00A0}"), "\u{00A0}")
    }

    /// Pin the canonical ANSI clear-screen + home-cursor attack:
    /// `"foo\x1b[2J\x1b[Hbar"` must escape to `"foo\x1b[2J\x1b[Hbar"`
    /// (literal ESC bytes neutralized; `[2J` etc. are printable ASCII
    /// and pass through unchanged — only the leading `\x1b` neutralizes
    /// the sequence).
    func testEscapeForStderrNeutralizesAnsiClearScreen() {
        let attack = "foo\u{001B}[2J\u{001B}[Hbar"
        let safe = EventKitErrorSanitizer.escapeForStderr(attack)
        XCTAssertFalse(safe.contains("\u{001B}"),
            "no raw ESC bytes may survive escape; got: \(safe.debugDescription)")
        XCTAssertEqual(safe, "foo\\x1b[2J\\x1b[Hbar")
    }

    /// Pin Unicode passthrough: CJK, accents, emoji must traverse
    /// `escapeForStderr` unchanged. Boundary check at `0x20` — anything
    /// `>= 0x20` that's not DEL or backslash passes through as-is.
    func testEscapeForStderrPreservesUnicodeAndPrintableAscii() {
        XCTAssertEqual(
            EventKitErrorSanitizer.escapeForStderr("café 中文 日本語 🎉"),
            "café 中文 日本語 🎉",
            "all Unicode scalars >= 0x20 must pass through unchanged"
        )
        // Printable ASCII boundary
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr(" "), " ")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("~"), "~")
    }

    /// Pin pre-#73 invariants still hold: backslash, LF, CR escape to
    /// the SAME multi-char escape sequences as before (no semantic break).
    func testEscapeForStderrPreservesLegacyBackslashLFCREscapes() {
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\\"), "\\\\")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\n"), "\\n")
        XCTAssertEqual(EventKitErrorSanitizer.escapeForStderr("\r"), "\\r")
        XCTAssertEqual(
            EventKitErrorSanitizer.escapeForStderr("a\\b\nc\rd"),
            "a\\\\b\\nc\\rd",
            "mixed legacy chars preserve order and individual escapes"
        )
    }

    // MARK: - sanitizeForInterpolation (#74) — strip C0 + DEL

    /// Pin LF/CR strip (the canonical CWE-117 attack vector — newline-injection
    /// into log lines). `"foo\n[ERROR] FORGED"` becomes `"foo[ERROR] FORGED"`
    /// — still readable, but the host's plain-text log writer can no longer
    /// be tricked into a forged log entry.
    func testSanitizeForInterpolationStripsLFAndCR() {
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("foo\nbar"),
            "foobar"
        )
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("foo\rbar"),
            "foobar"
        )
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("foo\n[ERROR] FORGED"),
            "foo[ERROR] FORGED",
            "newline-injection attack neutralized via strip"
        )
    }

    /// Pin NUL strip — important for downstream log writers using
    /// C-string termination semantics (e.g. some syslog backends).
    func testSanitizeForInterpolationStripsNull() {
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("foo\u{0000}bar"),
            "foobar"
        )
    }

    /// Pin full C0 + DEL strip. All bytes `0x00..0x1F` and `0x7F`
    /// must be removed (no visible artifact). Other ASCII passes through.
    func testSanitizeForInterpolationStripsAllC0AndDEL() {
        // Sample across the C0 range
        for v: UInt32 in 0x00...0x1F {
            let s = "a\(Unicode.Scalar(v)!)b"
            XCTAssertEqual(
                EventKitErrorSanitizer.sanitizeForInterpolation(s),
                "ab",
                "C0 byte 0x\(String(v, radix: 16, uppercase: false)) must strip"
            )
        }
        // DEL
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("a\u{007F}b"),
            "ab"
        )
    }

    /// Pin Unicode passthrough: CJK, accents, emoji, printable ASCII
    /// boundary scalars must NOT be stripped. `0x20` (space) and `~`
    /// (last printable ASCII) survive; `0x80+` always survives.
    func testSanitizeForInterpolationPreservesUnicodeAndPrintableAscii() {
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("café 中文 日本語 🎉"),
            "café 中文 日本語 🎉"
        )
        XCTAssertEqual(EventKitErrorSanitizer.sanitizeForInterpolation(" "), " ")
        XCTAssertEqual(EventKitErrorSanitizer.sanitizeForInterpolation("~"), "~")
        // C1 (0x80..0x9F) explicitly NOT stripped — out of scope per #74
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("a\u{0080}b"),
            "a\u{0080}b",
            "C1 controls are out of #74 scope; NOT stripped"
        )
    }

    /// Pin empty + already-clean inputs (idempotence-like guarantee).
    func testSanitizeForInterpolationHandlesEmptyAndCleanInputs() {
        XCTAssertEqual(EventKitErrorSanitizer.sanitizeForInterpolation(""), "")
        XCTAssertEqual(
            EventKitErrorSanitizer.sanitizeForInterpolation("hello world"),
            "hello world"
        )
        // Idempotent: sanitize(sanitize(x)) == sanitize(x)
        let dirty = "evil\n\rtitle\u{0000}"
        let once = EventKitErrorSanitizer.sanitizeForInterpolation(dirty)
        let twice = EventKitErrorSanitizer.sanitizeForInterpolation(once)
        XCTAssertEqual(once, twice, "sanitize must be idempotent")
        XCTAssertEqual(once, "eviltitle")
    }
}
