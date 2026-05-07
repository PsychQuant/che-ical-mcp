import EventKit
import Foundation
import XCTest

@testable import CheICalMCP

/// Stderr-capture tests for `CLIRunner.handleRunError(_:toolName:)` (#80).
///
/// Pins the cluster invariants `CLIRunner` inherited when its catch was
/// migrated from inline `FileHandle.standardError.write` to
/// `EventKitErrorSanitizer.writeFailureLog`:
///
/// 1. **Trusted-branch carve-out (#41)** — `TrustedErrorMessage` conformers
///    (e.g. `CLIError`, `ToolError`) skip stderr entirely to avoid the
///    DoS-amplification window the R3/R7/R8 carve-outs close.
/// 2. **`escapeForStderr` (#37 F2)** — control chars in untrusted error
///    `localizedDescription` are neutralized (CWE-117 log-injection
///    defense) before reaching stderr.
///
/// **Migrated to shared `withCapturedStderr` helper (#83)**: previously
/// inlined the 50-line `setUp`/`tearDown`/`readCapturedStderr` dup2-pipe
/// pattern; now uses `Tests/CheICalMCPTests/Helpers/StderrCaptureHarness.swift`.
/// The dup2-deadlock fix is centralized in the helper.
final class CLIRunnerStderrTests: XCTestCase {

    // MARK: - Trusted-branch carve-out (#41 inheritance)

    func testCLIErrorCarveOutSuppressesStderr() {
        // CLIError conforms to TrustedErrorMessage (CLIRunner.swift:7).
        // The wire response (stdout JSON) carries the same string, so
        // stderr would be a duplicate — writeFailureLog skips it.
        let stderr = capturedStderr {
            CLIRunner.handleRunError(
                CLIRunner.CLIError.missingToolName,
                toolName: nil
            )
        }
        XCTAssertTrue(
            stderr.isEmpty,
            "CLIError (TrustedErrorMessage) must NOT write stderr; got: \(stderr.debugDescription)"
        )
    }

    func testToolErrorCarveOutSuppressesStderr() {
        // ToolError also conforms to TrustedErrorMessage. Same carve-out.
        let stderr = capturedStderr {
            CLIRunner.handleRunError(
                ToolError.invalidParameter("calendar_name is required"),
                toolName: "list_events"
            )
        }
        XCTAssertTrue(
            stderr.isEmpty,
            "ToolError (TrustedErrorMessage) must NOT write stderr; got: \(stderr.debugDescription)"
        )
    }

    // MARK: - escapeForStderr (#37 F2 inheritance) — CWE-117 defense

    func testUntrustedErrorEscapesControlChars() {
        // NSError from EventKit framework is the canonical untrusted source.
        // localizedDescription containing \n / \r would forge fake stderr
        // lines visible to the operator (CWE-117) — escapeForStderr converts
        // them to literal \\n / \\r before the write.
        let evilError = NSError(
            domain: EKErrorDomain,
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "evil\nlog\rline"]
        )

        let stderr = capturedStderr {
            CLIRunner.handleRunError(evilError, toolName: "list_events")
        }

        XCTAssertFalse(
            stderr.isEmpty,
            "untrusted NSError must write a single stderr line"
        )
        // Canonical writeFailureLog shape: `<handler>(<identifier>) failed: <log>\n`
        XCTAssertTrue(
            stderr.hasPrefix("CLIRunner(list_events) failed:"),
            "stderr line must use the canonical (handler)(identifier) failed: shape; got: \(stderr.debugDescription)"
        )
        // Control chars from localizedDescription must be escaped, not raw.
        XCTAssertTrue(
            stderr.contains("\\n") && stderr.contains("\\r"),
            "control chars in localizedDescription must be escaped to literal \\n / \\r; got: \(stderr.debugDescription)"
        )
        // The raw control chars must NOT appear inside the body before the
        // final terminator — i.e. the stderr line must be a single line.
        // We allow the trailing \n that writeFailureLog itself writes.
        let body = String(stderr.dropLast())  // drop final \n
        XCTAssertFalse(
            body.contains("\n") || body.contains("\r"),
            "after escaping, the body must not contain any raw \\n or \\r; got: \(body.debugDescription)"
        )
    }

    // MARK: - Nil toolName fallback

    func testNilToolNameFallback() {
        // When parsing throws before the tool name is known (e.g.
        // CLIError.missingToolName fires inside a try-block branch that
        // never assigned toolName), handleRunError receives `nil` and
        // falls back to "<no-tool>" to keep the operator-debug line
        // structurally valid.
        let untrusted = NSError(
            domain: EKErrorDomain,
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "framework error"]
        )

        let stderr = capturedStderr {
            CLIRunner.handleRunError(untrusted, toolName: nil)
        }

        XCTAssertTrue(
            stderr.hasPrefix("CLIRunner(<no-tool>) failed:"),
            "nil toolName must fall back to the literal <no-tool> identifier; got: \(stderr.debugDescription)"
        )
    }
}
