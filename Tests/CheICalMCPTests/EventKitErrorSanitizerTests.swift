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
}
