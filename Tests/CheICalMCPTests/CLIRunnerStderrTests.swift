import EventKit
import Foundation
import XCTest

@testable import CheICalMCP

/// Stderr-capture tests for `CLIRunner.handleRunError(_:toolName:)` (#80).
///
/// These tests pin the cluster invariants `CLIRunner` inherited when its
/// catch was migrated from inline `FileHandle.standardError.write` to
/// `EventKitErrorSanitizer.writeFailureLog`:
///
/// 1. **Trusted-branch carve-out (#41)** — `TrustedErrorMessage` conformers
///    (e.g. `CLIError`, `ToolError`) skip stderr entirely to avoid the
///    DoS-amplification window the R3/R7/R8 carve-outs close.
/// 2. **`escapeForStderr` (#37 F2)** — control chars in untrusted error
///    `localizedDescription` are neutralized (CWE-117 log injection
///    defense) before reaching stderr.
///
/// **Stderr-capture pattern** (first instance in this repo): use a
/// `Pipe` + `dup2(STDERR_FILENO, ...)` to redirect stderr writes during
/// the test, restore in `tearDown`. If #83 (cluster-wide stderr-capture
/// harness) lands later, this pattern should be extracted into a shared
/// `Tests/CheICalMCPTests/Helpers/StderrCapture.swift`.
final class CLIRunnerStderrTests: XCTestCase {

    private var savedStderrFD: Int32 = -1
    private var capturePipe: Pipe?

    override func setUp() {
        super.setUp()
        let pipe = Pipe()
        // Save current stderr so we can restore in tearDown.
        savedStderrFD = dup(STDERR_FILENO)
        // Redirect stderr writes into the pipe's write end.
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        capturePipe = pipe
    }

    override func tearDown() {
        // If a test didn't drain the pipe (e.g. assertion failure aborted
        // early), still clean up: restore stderr first (so any FD 2 dup
        // pointing at the write end is closed), then close the explicit
        // FileHandle write end too.
        if savedStderrFD >= 0 {
            dup2(savedStderrFD, STDERR_FILENO)
            close(savedStderrFD)
            savedStderrFD = -1
        }
        capturePipe?.fileHandleForWriting.closeFile()
        capturePipe = nil
        super.tearDown()
    }

    /// Read whatever has been written to stderr since `setUp`. Restores
    /// `STDERR_FILENO` *before* reading because `dup2` made FD 2 a copy
    /// of the pipe's write-end FD — closing only the explicit FileHandle
    /// would leave FD 2 still pointing at the write end, and
    /// `readDataToEndOfFile` would block waiting for EOF that never comes.
    /// Restoring stderr closes FD 2's reference to the pipe, the explicit
    /// write-end close drops the last reference, and the read gets EOF.
    private func readCapturedStderr() -> String {
        guard let pipe = capturePipe else { return "" }
        // 1. Restore real stderr — also closes FD 2's dup of the write end.
        if savedStderrFD >= 0 {
            dup2(savedStderrFD, STDERR_FILENO)
            close(savedStderrFD)
            savedStderrFD = -1
        }
        // 2. Drop the last writer reference so the reader sees EOF.
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        capturePipe = nil
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Trusted-branch carve-out (#41 inheritance)

    func testCLIErrorCarveOutSuppressesStderr() {
        // CLIError conforms to TrustedErrorMessage (CLIRunner.swift:7).
        // The wire response (stdout JSON) carries the same string, so
        // stderr would be a duplicate — writeFailureLog skips it.
        CLIRunner.handleRunError(
            CLIRunner.CLIError.missingToolName,
            toolName: nil
        )

        let stderr = readCapturedStderr()
        XCTAssertTrue(
            stderr.isEmpty,
            "CLIError (TrustedErrorMessage) must NOT write stderr; got: \(stderr.debugDescription)"
        )
    }

    func testToolErrorCarveOutSuppressesStderr() {
        // ToolError also conforms to TrustedErrorMessage. Same carve-out.
        CLIRunner.handleRunError(
            ToolError.invalidParameter("calendar_name is required"),
            toolName: "list_events"
        )

        let stderr = readCapturedStderr()
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

        CLIRunner.handleRunError(evilError, toolName: "list_events")

        let stderr = readCapturedStderr()
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

        CLIRunner.handleRunError(untrusted, toolName: nil)

        let stderr = readCapturedStderr()
        XCTAssertTrue(
            stderr.hasPrefix("CLIRunner(<no-tool>) failed:"),
            "nil toolName must fall back to the literal <no-tool> identifier; got: \(stderr.debugDescription)"
        )
    }
}
