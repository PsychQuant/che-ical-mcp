import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// Pins #37 spec R8: the outer `handleToolCall` catch must route through
/// `EventKitErrorSanitizer.sanitizeForResponse(_:)` — `ToolError` lands in
/// `CallTool.Result` verbatim (trust path), `EKErrorDomain` NSError lands
/// as a sanitized code (framework path).
final class OuterCatchDispatchTests: XCTestCase {

    func testOuterCatchToolErrorReturnsTrustedMessage() async throws {
        let server = try await CheICalMCPServer()

        let result = await server.handleToolCallForTesting(
            name: "definitely_not_a_real_tool",
            arguments: [:]
        )

        XCTAssertTrue(result.isError ?? false, "expected isError = true")
        guard case let .text(text, _, _) = result.content.first else {
            XCTFail("expected .text content; got \(String(describing: result.content.first))")
            return
        }
        XCTAssertEqual(text, "Error: Unknown tool: definitely_not_a_real_tool")
    }

    func testOuterCatchSanitizesEventKitError() async throws {
        // Drive the path via `cleanup_completed_reminders` filter mode; script
        // the fake to throw an `NSError(domain: EKErrorDomain, ...)`. The
        // outer catch should sanitize, not echo the Apple-produced
        // localizedDescription.
        let fake = FakeEventKitManager()
        await fake.scriptListError(
            NSError(
                domain: EKErrorDomain,
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Apple-produced text that must not leak"]
            )
        )
        let server = try await CheICalMCPServer(reminderCleanupSource: fake)

        let result = await server.handleToolCallForTesting(
            name: "cleanup_completed_reminders",
            arguments: [:]
        )

        XCTAssertTrue(result.isError ?? false)
        guard case let .text(text, _, _) = result.content.first else {
            XCTFail("expected .text content")
            return
        }
        XCTAssertEqual(text, "Error: eventkit_error_4")
        XCTAssertFalse(
            text.contains("Apple-produced"),
            "outer catch must not leak Apple text; got \(text)"
        )
    }

    /// #37 F3: tighter pin for the trust dispatch — proves
    /// `sanitizeForResponse` actually inspects the marker, not just falls
    /// through to `localizedDescription`. Two errors with IDENTICAL
    /// localizedDescription, only one trusted: response must differ.
    func testSanitizeForResponseDistinguishesTrustVsNonTrust() {
        struct TwinTrusted: LocalizedError, TrustedErrorMessage {
            var errorDescription: String? { "TWIN_PASSTHROUGH_PAYLOAD" }
        }
        struct TwinUntrusted: LocalizedError {
            var errorDescription: String? { "TWIN_PASSTHROUGH_PAYLOAD" }
        }

        let trustedResult = EventKitErrorSanitizer.sanitizeForResponse(TwinTrusted())
        let untrustedResult = EventKitErrorSanitizer.sanitizeForResponse(TwinUntrusted())

        XCTAssertEqual(trustedResult.code, "TWIN_PASSTHROUGH_PAYLOAD")
        XCTAssertNotEqual(
            untrustedResult.code,
            "TWIN_PASSTHROUGH_PAYLOAD",
            "untrusted twin must NOT pass through; got \(untrustedResult.code)"
        )
        XCTAssertNotEqual(
            trustedResult.code,
            untrustedResult.code,
            "dispatch must produce different codes for trust vs framework branch"
        )
    }
}
