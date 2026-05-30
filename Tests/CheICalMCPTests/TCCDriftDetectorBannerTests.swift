// MARK: - CI handling (#131 — RESOLVED)
//
// #131 root cause (the GHA hang) was `AuthorizationGate.ensureAccess` blocking on
// `requestFullAccess` for `.notDetermined` in a non-interactive session — now fixed
// in the production gate (fast-fail). The earlier "hang sits before any test method /
// xctest load" theory was a pre-R6 guess that the R6 verbose+PTY log disproved (the
// hang was inside DispatchRoundTripTests' real EventKit call, now fast-failing).
//
// Both the compile-time `#if !CI_BUILD` exclusion AND the runtime `skipIfCI()` guard
// are now removed: these binary-spawn tests run on CI. The precaution is no longer
// load-bearing because `spawnAndCaptureStderr` bounds every wait — `maxWait` poll,
// SIGTERM→SIGKILL escalation, and a 3s hard `waitUntilExit` cap with a force-reap
// SIGKILL — so a stuck child fails fast (~6s/test worst case) instead of wedging the
// 20m job timeout. The spawned binary also inherits the same EventKit fast-fail under
// CI=1, so the banner path (which only reads `authorizationStatus`, never
// `requestFullAccess`) has no blocking primitive left to hang on.

import XCTest
import Darwin  // SIGKILL + kill(_:_:) for the SIGTERM→SIGKILL escalation in spawnAndCaptureStderr
@testable import CheICalMCP

/// Subprocess-based integration tests for the startup banner emitted by `emitStartupBanner()`
/// in `main.swift`. These tests spawn the built `CheICalMCP` binary, read its stderr, and
/// assert banner-format invariants. They are intentionally tolerant of host-specific state:
/// TCC.db / ps output vary between machines, so we only check banner-shape contracts here.
/// Pure drift-detection logic lives in `TCCDriftDetectorTests.swift`.
final class TCCDriftDetectorBannerTests: XCTestCase {

    // MARK: - Setup

    /// Locate the built binary. SwiftPM tests run from the package root, so debug
    /// builds live at `.build/debug/CheICalMCP`. Release builds at `.build/release/`.
    /// We prefer debug since `swift test` always builds debug.
    private func locateBuiltBinary() throws -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/.build/debug/CheICalMCP",
            "\(cwd)/.build/release/CheICalMCP"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("CheICalMCP binary not found at \(candidates). Run `swift build` first.")
    }

    /// Spawn the binary, give it up to `maxWait` seconds to emit a banner, then terminate.
    /// Returns (stderr_text, exit_status). Stdin is wired to `/dev/null` so the MCP server
    /// loop has no JSON-RPC to read; we don't expect graceful shutdown, just the banner
    /// to land on stderr before we kill.
    ///
    /// CI hang note (#122 R3): the GitHub Actions macos-latest runner can leave the MCP
    /// loop in a state where SIGTERM is ignored (ad-hoc-signed binary + TCC sandbox quirks),
    /// causing `waitUntilExit()` to block past the 20m job timeout. We therefore escalate
    /// SIGTERM → SIGKILL after a short grace window, and read stderr off a background queue
    /// so the read can't deadlock on a child that hasn't closed its fds yet.
    private func spawnAndCaptureStderr(
        binary: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        maxWait: TimeInterval = 1.0,
        sigtermGrace: TimeInterval = 0.5
    ) throws -> (stderr: String, terminationStatus: Int32) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let env = environment {
            process.environment = env
        }

        let stderr = Pipe()
        let stdin = Pipe()
        let stdout = Pipe()  // discard stdout — JSON-RPC noise, but parent must close write end
        process.standardError = stderr
        process.standardInput = stdin
        process.standardOutput = stdout

        // Drain stderr off a background queue. `readDataToEndOfFile()` on the calling
        // thread can deadlock if the child fills the pipe buffer (>64KB on macOS) before
        // we read, and waiting for EOF post-terminate requires the child to actually
        // release its fds. The async drain decouples both concerns.
        let stderrHandle = stderr.fileHandleForReading
        let stderrQueue = DispatchQueue(label: "spawnAndCaptureStderr.drain")
        let stderrLock = NSLock()
        var stderrBuffer = Data()
        let drainDone = DispatchSemaphore(value: 0)
        stderrQueue.async {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }  // EOF
                stderrLock.lock()
                stderrBuffer.append(chunk)
                stderrLock.unlock()
            }
            drainDone.signal()
        }

        // Same drain pattern for stdout — without this, the child writing >64KB of
        // JSON-RPC noise (or startup logs) fills the pipe and blocks on `write(2)`,
        // which deadlocks the MCP loop before it reaches its stdin-EOF exit path.
        // CI macOS runners exhibit this; dev hosts appear to size pipe buffers larger
        // or schedule differently, masking the issue locally.
        let stdoutHandle = stdout.fileHandleForReading
        let stdoutQueue = DispatchQueue(label: "spawnAndCaptureStderr.stdoutDrain")
        let stdoutDrainDone = DispatchSemaphore(value: 0)
        stdoutQueue.async {
            while true {
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty { break }
            }
            stdoutDrainDone.signal()
        }

        try process.run()

        // Close parent's copies of the child's pipe ends. Required for EOF semantics
        // to fire on the read side once the child exits: a pipe only signals EOF when
        // *every* write-end fd is closed, and `Process` retains parent-side write-end
        // handles after `run()` until the `Pipe` is deallocated. Without these closes,
        // the stderr/stdout drain queues block indefinitely on `availableData` even
        // after SIGKILL, causing `drainDone.wait` to time out and `waitUntilExit()` to
        // never see the child release its fds.
        try? stderr.fileHandleForWriting.close()
        try? stdout.fileHandleForWriting.close()

        // Close stdin so the MCP loop reads EOF, then wait briefly for the banner to
        // flush. If the process exits on its own (--version / --help), we drop out of
        // the polling loop early via isRunning check.
        try stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(maxWait)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Two-stage shutdown: SIGTERM first, then escalate to SIGKILL if the child
        // ignores it. POSIX `kill(_:_:)` from Darwin is uncatchable on SIGKILL, so this
        // is a guaranteed exit path even when the MCP loop has a misbehaving signal
        // handler (or no handler at all).
        if process.isRunning {
            process.terminate()  // SIGTERM
            let killDeadline = Date().addingTimeInterval(sigtermGrace)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        // Bounded `waitUntilExit`. Even SIGKILL'd processes can briefly remain in
        // uninterruptible kernel states (TCC sandbox checks, NFS, etc.); we don't
        // want a stuck child to wedge the whole test job for 20 minutes. After a
        // 3-second hard cap we abandon the wait and force-reap via a second SIGKILL
        // (idempotent — sending SIGKILL to a zombie is a no-op).
        let waitQueue = DispatchQueue(label: "spawnAndCaptureStderr.wait")
        let waitDone = DispatchSemaphore(value: 0)
        waitQueue.async {
            process.waitUntilExit()
            waitDone.signal()
        }
        if waitDone.wait(timeout: .now() + 3.0) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = waitDone.wait(timeout: .now() + 1.0)
        }

        // Bound the drain waits too — if EOF still hasn't arrived (extremely unlikely
        // after explicit pipe-write-end close + SIGKILL), partial output is fine.
        _ = drainDone.wait(timeout: .now() + 1.0)
        _ = stdoutDrainDone.wait(timeout: .now() + 1.0)
        try? stderrHandle.close()
        try? stdoutHandle.close()

        stderrLock.lock()
        let stderrText = String(data: stderrBuffer, encoding: .utf8) ?? ""
        stderrLock.unlock()
        return (stderrText, process.terminationStatus)
    }

    // MARK: - Tests

    /// In default MCP server mode (no flags), the banner header line must appear on
    /// stderr within the wait window. We don't assert specific drift signals because
    /// host state varies.
    ///
    /// **Path comparison nuance** (#129): the banner now uses `BinaryPathResolver` which
    /// runs `realpath(3)`. `.build/debug/CheICalMCP` is a per-architecture symlink (e.g.
    /// to `.build/arm64-apple-macosx/debug/CheICalMCP`), so the banner's emitted path
    /// is the symlink target, not the symlink itself. We compare against the resolved
    /// path so the assertion matches the post-#129 canonical-path behavior.
    ///
    /// **Latency budget enforcement** (#127): the Plan tier for #122 specified
    /// `< 200ms integration including spawn`. This test now encodes that budget as
    /// `XCTAssertLessThan` so future regressions in banner emission speed are caught
    /// rather than discovered through user reports. Empirical baseline ~50-100ms on
    /// healthy local macOS; we use 1.5s as the assertion bound to absorb local-machine
    /// noise (Spotlight indexing / brew autoupdate / etc.) while still catching the
    /// "banner now takes 10 seconds" class of regression that would actually matter.
    func testBannerAppearsInDefaultMCPServerMode() throws {
        let binary = try locateBuiltBinary()
        let resolvedBinaryPath = BinaryPathResolver.resolveArgv0(binary.path)

        let start = Date()
        let (stderr, _) = try spawnAndCaptureStderr(binary: binary)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(
            stderr.contains("[banner] che-ical-mcp"),
            "Default startup should emit banner. Got stderr: \(stderr.prefix(200))"
        )
        XCTAssertTrue(
            stderr.contains(resolvedBinaryPath),
            "Banner should include the realpath-resolved binary path (#129 — banner uses BinaryPathResolver). Got stderr: \(stderr.prefix(300)), resolved: \(resolvedBinaryPath)"
        )
        XCTAssertLessThan(
            elapsed, 1.5,
            "Banner must emit within Plan tier latency budget (#127, target 200ms; assertion bound at 1.5s to absorb local-host noise). Elapsed: \(String(format: "%.3f", elapsed))s"
        )
    }

    /// Setting `CHE_ICAL_MCP_NO_BANNER=1` must completely suppress banner output.
    func testBannerSuppressedByEnvironmentVariable() throws {
        let binary = try locateBuiltBinary()
        var env = ProcessInfo.processInfo.environment
        env["CHE_ICAL_MCP_NO_BANNER"] = "1"

        let (stderr, _) = try spawnAndCaptureStderr(binary: binary, environment: env)

        XCTAssertFalse(
            stderr.contains("[banner]"),
            "Env-var should fully suppress banner. Got stderr: \(stderr)"
        )
        XCTAssertFalse(
            stderr.contains("[drift]"),
            "Env-var should also suppress drift signals. Got stderr: \(stderr)"
        )
    }

    /// `--version` exits before the MCP-server-mode code path, so no banner.
    func testNoBannerForVersionFlag() throws {
        let binary = try locateBuiltBinary()
        let (stderr, status) = try spawnAndCaptureStderr(
            binary: binary,
            arguments: ["--version"]
        )

        XCTAssertEqual(status, 0)
        XCTAssertFalse(
            stderr.contains("[banner]"),
            "--version path should not emit banner. Got stderr: \(stderr)"
        )
    }

    /// `--help` exits before banner too. Same path as `--version`, separate test to
    /// document the contract explicitly.
    func testNoBannerForHelpFlag() throws {
        let binary = try locateBuiltBinary()
        let (stderr, status) = try spawnAndCaptureStderr(
            binary: binary,
            arguments: ["--help"]
        )

        XCTAssertEqual(status, 0)
        XCTAssertFalse(
            stderr.contains("[banner]"),
            "--help path should not emit banner. Got stderr: \(stderr)"
        )
    }

    /// Spawn the binary from a path not present in TCC.db — typically forces a
    /// path-mismatch drift signal (or skip-reason if sqlite3 unavailable). This is the
    /// "mcpb 怎麼 test" answer per the Plan tier discussion: we don't actually install
    /// to the mcpb path, we just run from any arbitrary path and assert the banner
    /// recognizes the alternate path.
    func testBannerHandlesArbitraryBinaryPath() throws {
        let builtBinary = try locateBuiltBinary()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CheICalMCP-banner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempBinary = tempDir.appendingPathComponent("CheICalMCP")
        try FileManager.default.copyItem(at: builtBinary, to: tempBinary)

        let (stderr, _) = try spawnAndCaptureStderr(binary: tempBinary)

        XCTAssertTrue(
            stderr.contains("[banner] che-ical-mcp"),
            "Banner should appear even from arbitrary path. Got stderr: \(stderr.prefix(200))"
        )
        XCTAssertTrue(
            stderr.contains(tempBinary.path),
            "Banner should print the temp path we spawned from. Got: \(stderr.prefix(400))"
        )
    }
}
