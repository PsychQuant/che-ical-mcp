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

import CheMCPKit
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

    /// Spawn the binary, close its stdin, and wait for it to exit, terminating it if it is
    /// still running after `maxWait` seconds. Returns (stderr_text, exit_status). With stdin
    /// at EOF the MCP server loop has no JSON-RPC to read and exits by itself right after
    /// the banner, so a normal run returns in well under a second.
    ///
    /// `maxWait` is a cap for a hung child, not the time a child gets to emit its output
    /// (#233). The banner is a single write at the end of `emitStartupBanner()`, after up
    /// to three 500 ms subprocess caps (#126); under host CPU contention it lands after
    /// 1 s, and the former 1.0 s default SIGTERM'd the child before that write (no SIGTERM
    /// handler, so the default action kills it), which read as "no banner". The 10 s
    /// default sits well above the slowest arrival measured under contention (~1.5 s).
    ///
    /// `until`, when given, is checked against the drained stderr after every chunk. The
    /// helper stops waiting as soon as it matches (then terminates the child if it is still
    /// running), and returns `untilMatchedAfter`: seconds from spawn to the chunk that
    /// matched, or `nil` if it never did. Tests that time an output use this rather than the
    /// helper's whole run, which also includes teardown.
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
        maxWait: TimeInterval = 10.0,
        sigtermGrace: TimeInterval = 0.5,
        until: ((String) -> Bool)? = nil
    ) throws -> (stderr: String, terminationStatus: Int32, untilMatchedAfter: TimeInterval?) {
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
        var untilMatchedAfter: TimeInterval?
        let drainDone = DispatchSemaphore(value: 0)
        // Arrival clock for `until`, spawn included (as #127's latency budget specified).
        let spawnStart = Date()
        stderrQueue.async {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }  // EOF
                stderrLock.lock()
                stderrBuffer.append(chunk)
                if let until, untilMatchedAfter == nil,
                   until(String(decoding: stderrBuffer, as: UTF8.self)) {
                    untilMatchedAfter = Date().timeIntervalSince(spawnStart)
                }
                stderrLock.unlock()
            }
            drainDone.signal()
        }
        func untilMatched() -> Bool {
            stderrLock.lock()
            defer { stderrLock.unlock() }
            return untilMatchedAfter != nil
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

        // Close stdin so the MCP loop reads EOF and exits by itself after the banner
        // (--version / --help exit even sooner). Wait for that exit, for `until` to
        // match, or for the `maxWait` cap, whichever comes first.
        try stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(maxWait)
        while process.isRunning, Date() < deadline, !untilMatched() {
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
        let matchedAfter = untilMatchedAfter
        stderrLock.unlock()
        return (stderrText, process.terminationStatus, matchedAfter)
    }

    // MARK: - Helper contract (#233)

    /// A child that is slow to start must not be reported as silent. #233: under host CPU
    /// contention the banner can land after 1 s, and a fixed 1.0 s wait killed the child
    /// before its single banner write, so the test read "no banner". With the default
    /// arguments the helper must wait for the child, not for a fixed interval.
    func testSpawnHelperCapturesChildThatWritesAfterOneSecond() throws {
        let (stderr, status, _) = try spawnAndCaptureStderr(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 1.2; printf '[late] written after 1.2s\\n' >&2"]
        )

        XCTAssertTrue(
            stderr.contains("[late] written after 1.2s"),
            "A child that writes after 1.2 s must be captured with the default wait. Got stderr: \(stderr)"
        )
        XCTAssertEqual(status, 0, "The child should exit by itself, not by the helper's SIGTERM")
    }

    /// `until:` releases the helper as soon as the drained stderr satisfies it, so a child
    /// that keeps running after its output costs well under the 10 s cap, and the helper
    /// reports when the output arrived (spawn → match) separately from teardown.
    func testSpawnHelperReturnsOnceUntilPredicateMatches() throws {
        let start = Date()
        let (stderr, _, untilMatchedAfter) = try spawnAndCaptureStderr(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '[ready] up\\n' >&2; exec sleep 30"],
            until: { $0.contains("[ready] up") }
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(stderr.contains("[ready] up"), "Got stderr: \(stderr)")
        let matchedAfter = try XCTUnwrap(untilMatchedAfter, "The predicate matched, so the arrival time must be reported")
        XCTAssertLessThanOrEqual(matchedAfter, elapsed)
        XCTAssertLessThan(
            elapsed, 5.0,
            "The helper should return once `until` matches, not wait out the 10 s cap. Elapsed: \(String(format: "%.3f", elapsed))s"
        )
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
    /// **Latency tripwire** (#127, #233): the Plan tier for #122 specified `< 200ms
    /// integration including spawn`. A wall-clock assertion on a shared host cannot hold a
    /// bound that tight, so this test keeps a coarse tripwire for the "banner now takes 10
    /// seconds" class of regression (#127 closing summary). It times the banner's arrival
    /// (spawn → the `until` match), not the helper's whole run including teardown. The
    /// bound is 5.0 s because the production path's own worst case is process startup plus
    /// three 500 ms subprocess caps (`ps`, `sqlite3`, the parent-chain `ps`; #126), and
    /// under host CPU contention the banner was measured arriving at up to ~1.5 s (#233),
    /// right at the former 1.5 s bound.
    func testBannerAppearsInDefaultMCPServerMode() throws {
        let binary = try locateBuiltBinary()
        let resolvedBinaryPath = BinaryPathResolver.resolveArgv0(binary.path)

        let (stderr, _, bannerArrival) = try spawnAndCaptureStderr(
            binary: binary,
            until: { $0.contains("[banner] che-ical-mcp") && $0.contains(resolvedBinaryPath) }
        )

        XCTAssertTrue(
            stderr.contains("[banner] che-ical-mcp"),
            "Default startup should emit banner. Got stderr: \(stderr.prefix(200))"
        )
        XCTAssertTrue(
            stderr.contains(resolvedBinaryPath),
            "Banner should include the realpath-resolved binary path (#129 — banner uses BinaryPathResolver). Got stderr: \(stderr.prefix(300)), resolved: \(resolvedBinaryPath)"
        )
        let arrival = try XCTUnwrap(
            bannerArrival,
            "The banner header and the resolved binary path never both reached stderr, so there is no arrival time to check"
        )
        XCTAssertLessThan(
            arrival, 5.0,
            "Banner must arrive within the latency tripwire (#127 target 200ms; bound 5.0s, above the production path's own worst case, #233). Arrived after: \(String(format: "%.3f", arrival))s"
        )
    }

    /// Setting `CHE_ICAL_MCP_NO_BANNER=1` must completely suppress banner output.
    func testBannerSuppressedByEnvironmentVariable() throws {
        let binary = try locateBuiltBinary()
        var env = ProcessInfo.processInfo.environment
        env["CHE_ICAL_MCP_NO_BANNER"] = "1"

        let (stderr, _, _) = try spawnAndCaptureStderr(binary: binary, environment: env)

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
        let (stderr, status, _) = try spawnAndCaptureStderr(
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
        let (stderr, status, _) = try spawnAndCaptureStderr(
            binary: binary,
            arguments: ["--help"]
        )

        XCTAssertEqual(status, 0)
        XCTAssertFalse(
            stderr.contains("[banner]"),
            "--help path should not emit banner. Got stderr: \(stderr)"
        )
    }

    /// #163 / #122 skip-list: `--setup` exits before `emitStartupBanner()` is reached, so it
    /// must emit no banner. Exit status is intentionally NOT asserted — `--setup` exits
    /// non-zero when access is denied/skipped (host-TCC-state dependent), and under this
    /// non-interactive spawn `.notDetermined` is skipped (never calls the blocking request,
    /// so no hang).
    ///
    /// `maxWait: 1.0` is explicit (#233): in a GUI session `--setup` runs the interactive
    /// SetupWindow `NSApplication`, which never exits by itself (#249), so the 10 s default
    /// cap would keep that window on screen for 10 s on every run.
    func testNoBannerForSetupFlag() throws {
        let binary = try locateBuiltBinary()
        let (stderr, _, _) = try spawnAndCaptureStderr(
            binary: binary,
            arguments: ["--setup"],
            maxWait: 1.0
        )

        XCTAssertFalse(
            stderr.contains("[banner]"),
            "--setup path should not emit banner. Got stderr: \(stderr)"
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

        // A freshly-copied binary at a never-seen path incurs a one-time macOS Gatekeeper
        // first-exec assessment before `main` runs — measured ~3.7s cold here (vs ~0.3s once
        // assessed). The banner only emits after that, so the default 1.0s maxWait would
        // SIGTERM the child before it ever prints. The continuous stderr drain captures the
        // banner the moment it lands, so we just need a wait budget that comfortably exceeds
        // cold-exec assessment; 10s gives margin for slower/CI hosts without risking a job hang
        // (the post-kill waitUntilExit is independently capped at 3s).
        let (stderr, _, _) = try spawnAndCaptureStderr(binary: tempBinary, maxWait: 10.0)

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
