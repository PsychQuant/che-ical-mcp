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
// load-bearing because `spawnAndCaptureStderr` bounds every wait — the `maxWait` cap
// (10s by default; since #233 it caps a hung child instead of giving the child a fixed
// 1s window to write), SIGTERM→SIGKILL escalation, and a 3s hard `waitUntilExit` cap
// with a force-reap SIGKILL — so a stuck child costs at most ~16.5s per helper call (10 +
// 0.5s SIGTERM grace + 3 + 1s force-reap + two 1s drain bounds) instead of wedging the 20m
// job timeout. Most tests make one call; the warmed default-mode test makes two (warm-up +
// timed spawn), so its worst case is ~33s. A healthy child exits on stdin EOF right after the banner: roughly 0.4-1.0s
// from spawn to exit on the hosts measured for #233, about 0.02s with the banner
// suppressed. The spawned binary also inherits the same EventKit fast-fail under CI=1, so
// the banner path (which only reads `authorizationStatus`, never `requestFullAccess`) has
// no blocking primitive left to hang on.

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

    /// What `spawnAndCaptureStderr` observed.
    private struct SpawnResult {
        let stderr: String
        let terminationStatus: Int32
        /// Seconds from spawn to the stderr chunk that satisfied `until`, or `nil` if it never did.
        let untilMatchedAfter: TimeInterval?
        /// True when the `maxWait` cap ended the wait: the child was still running and `until`
        /// had not matched, so the helper had to terminate it. A child that is expected to exit
        /// by itself should leave this false; otherwise a hung child only shows up as slow.
        let timedOut: Bool
        /// The cap this spawn ran with, so its check names the bound that was used (#417).
        let maxWait: TimeInterval
        /// True when a stderr or stdout drain wait hit `drainCap`, so the output may be partial
        /// (#417). Judged through `checkSpawnBounds` before the output is read.
        let drainTimedOut: Bool
    }

    /// How long the helper waits for each output drain after the child is gone (#417).
    private static let drainCap: TimeInterval = 1.0

    /// #417: the spawn's wall-clock limits judged through `HostLoad`, before any assertion on the
    /// child's output (an `XCTSkip` cannot retract a failure recorded earlier, #366 / #418). With
    /// `exitsBySelf` the child must exit by itself within the cap it ran with (`run.maxWait`): on a
    /// host loaded past the threshold a timeout cannot tell "did not exit" from "too slow", and
    /// below it the timeout is still a failure. The drain is judged in every case.
    private func checkSpawnBounds(_ run: SpawnResult, exitsBySelf: Bool = true,
                                  _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        if exitsBySelf {
            try HostLoad.live.checkNotTimedOut(run.timedOut, bound: run.maxWait, what, file: file, line: line)
        }
        try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap, "\(what): output drain", file: file, line: line)
    }

    /// Spawn the binary, close its stdin, and wait for it to exit, terminating it if it is
    /// still running after `maxWait` seconds. With stdin at EOF the MCP server loop has no
    /// JSON-RPC to read and exits by itself right after the banner, roughly 0.4-1.0 s after
    /// spawn on the hosts measured for #233.
    ///
    /// `maxWait` is a cap for a hung child, not the time a child gets to emit its output
    /// (#233). The banner is a single write at the end of `emitStartupBanner()`, after up
    /// to three 500 ms subprocess caps (#126). The former 1.0 s default SIGTERM'd the child
    /// whenever that write came later than 1 s (no SIGTERM handler, so the default action
    /// kills it), which read as "no banner". A healthy run already takes up to ~1 s, so
    /// that window had little margin even before host CPU contention pushed the banner
    /// later. The 10 s default sits well above the slowest arrival measured under
    /// contention (1.67 s).
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
    ) throws -> SpawnResult {
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
        let timedOut = process.isRunning && !untilMatched()

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

        // Bound the drain waits too. EOF should have arrived by now (the write ends are closed and
        // the child is gone); a wait that reaches `drainCap` means the output may be partial, and
        // the result says so (`drainTimedOut`) so `checkSpawnBounds` reports it before the output
        // is read (#417).
        let stderrDrainTimedOut = drainDone.wait(timeout: .now() + Self.drainCap) == .timedOut
        let stdoutDrainTimedOut = stdoutDrainDone.wait(timeout: .now() + Self.drainCap) == .timedOut
        try? stderrHandle.close()
        try? stdoutHandle.close()

        stderrLock.lock()
        let stderrText = String(data: stderrBuffer, encoding: .utf8) ?? ""
        let matchedAfter = untilMatchedAfter
        stderrLock.unlock()
        return SpawnResult(
            stderr: stderrText,
            terminationStatus: process.terminationStatus,
            untilMatchedAfter: matchedAfter,
            timedOut: timedOut,
            maxWait: maxWait,
            drainTimedOut: stderrDrainTimedOut || stdoutDrainTimedOut
        )
    }

    // MARK: - Helper contract (#233)

    /// A child that is slow to start must not be reported as silent. #233: under host CPU
    /// contention the banner can land after 1 s, and a fixed 1.0 s wait killed the child
    /// before its single banner write, so the test read "no banner". With the default
    /// arguments the helper must wait for the child, not for a fixed interval.
    ///
    /// One process does both the wait and the write, so if the cap ever fired, the helper's
    /// signal would reach the process that is still waiting. With `sh -c "sleep 1.2; printf …"`
    /// the shell forks `sleep`, and that grandchild would outlive the signalled shell.
    func testSpawnHelperCapturesChildThatWritesAfterOneSecond() throws {
        let perl = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: perl) else {
            throw XCTSkip("\(perl) is not available on this host; the late-writer child needs it")
        }
        let run = try spawnAndCaptureStderr(
            binary: URL(fileURLWithPath: perl),
            arguments: ["-e", "select(undef, undef, undef, 1.2); print STDERR qq([late] written after 1.2s\\n)"]
        )

        try checkSpawnBounds(run, "The late-writing child (it should exit by itself, not hit the cap)")   // #417
        XCTAssertTrue(
            run.stderr.contains("[late] written after 1.2s"),
            "A child that writes after 1.2 s must be captured with the default wait. Got stderr: \(run.stderr)"
        )
        XCTAssertEqual(run.terminationStatus, 0, "The child should exit by itself, not by the helper's SIGTERM")
    }

    /// `until:` releases the helper as soon as the drained stderr satisfies it, so a child
    /// that keeps running after its output costs well under the 10 s cap, and the helper
    /// reports when the output arrived (spawn → match) separately from teardown.
    func testSpawnHelperReturnsOnceUntilPredicateMatches() throws {
        let start = Date()
        let run = try spawnAndCaptureStderr(
            binary: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '[ready] up\\n' >&2; exec sleep 30"],
            until: { $0.contains("[ready] up") }
        )
        let elapsed = Date().timeIntervalSince(start)

        // #417: the cap and the drain are judged before the output is read. Once they pass, the
        // output is complete, so it is asserted on before the duration check, which a skip would
        // otherwise keep from running.
        try checkSpawnBounds(run, "The `until` spawn (`until` matched, so the cap should not end the wait)")
        XCTAssertTrue(run.stderr.contains("[ready] up"), "Got stderr: \(run.stderr)")
        let matchedAfter = try XCTUnwrap(run.untilMatchedAfter, "The predicate matched, so the arrival time must be reported")
        XCTAssertLessThanOrEqual(matchedAfter, elapsed)
        try HostLoad.live.checkWithinBound(elapsed, bound: 5.0,
            "The helper's return once `until` matches (not the 10 s cap)")
    }

    /// A child that ignores stdin EOF is stopped at the `maxWait` cap and reported as
    /// `timedOut`, in about `maxWait` + the SIGTERM it dies on, not left to run on.
    func testSpawnHelperReportsTimeoutWhenChildOutlivesTheCap() throws {
        let start = Date()
        let run = try spawnAndCaptureStderr(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            maxWait: 0.3
        )
        let elapsed = Date().timeIntervalSince(start)

        // That the cap fired stays a hard assertion, made first: load can only make it more
        // certain, and it reads nothing the child wrote. The capped child is not expected to exit;
        // the drain and the path's duration are judged after it, through `HostLoad` (#417).
        XCTAssertTrue(run.timedOut, "`sleep 30` ignores stdin EOF, so the 0.3 s cap must end the wait")
        XCTAssertNil(run.untilMatchedAfter)
        try checkSpawnBounds(run, exitsBySelf: false, "The capped `sleep 30` spawn")
        try HostLoad.live.checkWithinBound(elapsed, bound: 3.0, "The cap path (about maxWait plus the SIGTERM)")
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
    /// (spawn → the `until` match), not the helper's whole run including teardown, and an
    /// untimed warm-up exec keeps a first-exec Gatekeeper assessment out of it. The bound
    /// is 5.0 s because the production path's own worst case is process startup plus three
    /// 500 ms subprocess caps (`ps`, `sqlite3`, the parent-chain `ps`; #126), and under host
    /// CPU contention the banner was measured arriving at up to 1.67 s (#233), past the
    /// former 1.5 s bound. 5.0 s is deliberately a looser #127 guard than that 1.5 s: the
    /// tighter bound fell inside the range of real arrival times on a busy host and so
    /// produced false reds, while 5.0 s still catches the 10-second class of regression
    /// #127 is about.
    func testBannerAppearsInDefaultMCPServerMode() throws {
        let binary = try locateBuiltBinary()
        let resolvedBinaryPath = BinaryPathResolver.resolveArgv0(binary.path)

        // Untimed warm-up exec. The first exec of a freshly linked or copied binary can include
        // a one-time Gatekeeper assessment (up to 2.4 s measured for a fresh copy on the #233
        // host; ~3.7 s per `testBannerHandlesArbitraryBinaryPath`), and this is the first test
        // in the class to spawn the binary. Running `--version` once, to exit, keeps that cost
        // out of the arrival clock below, which is meant to time the banner path only.
        let warmUp = try spawnAndCaptureStderr(binary: binary, arguments: ["--version"])
        // #366: an overrun on a host loaded past 4 per core is a skip, otherwise a failure naming the load.
        try HostLoad.live.checkNotTimedOut(
            warmUp.timedOut, bound: 10,
            "The untimed `--version` warm-up (this failure is in the warm-up, not the timed banner spawn)")
        try checkSpawnBounds(warmUp, exitsBySelf: false, "The untimed `--version` warm-up")   // #417
        XCTAssertEqual(
            warmUp.terminationStatus, 0,
            "The untimed `--version` warm-up exited non-zero; this failure is in the warm-up, not the timed banner spawn"
        )

        let run = try spawnAndCaptureStderr(
            binary: binary,
            until: { $0.contains("[banner] che-ical-mcp") && $0.contains(resolvedBinaryPath) }
        )

        // The banner is one stderr write, so a header without the resolved path is a wrong path
        // whatever the timing (#129). Asserted before the load-aware timeout check, so that a skip
        // under load cannot hide it.
        XCTAssertTrue(
            !run.stderr.contains("[banner] che-ical-mcp") || run.stderr.contains(resolvedBinaryPath),
            "The banner header arrived without the realpath-resolved binary path (#129). Got stderr: \(run.stderr.prefix(300)), resolved: \(resolvedBinaryPath)"
        )
        // Judged next: a timeout means the `until` predicate (header && path) never matched, so the
        // presence assertions below would record a failure that a later XCTSkip cannot retract (#366).
        try HostLoad.live.checkNotTimedOut(run.timedOut, bound: 10, "The banner spawn (the banner should arrive before the cap)")
        try checkSpawnBounds(run, exitsBySelf: false, "The banner spawn")   // #417
        XCTAssertTrue(
            run.stderr.contains("[banner] che-ical-mcp"),
            "Default startup should emit banner. Got stderr: \(run.stderr.prefix(200))"
        )
        XCTAssertTrue(
            run.stderr.contains(resolvedBinaryPath),
            "Banner should include the realpath-resolved binary path (#129 — banner uses BinaryPathResolver). Got stderr: \(run.stderr.prefix(300)), resolved: \(resolvedBinaryPath)"
        )
        let arrival = try XCTUnwrap(
            run.untilMatchedAfter,
            "The banner header and the resolved binary path never both reached stderr, so there is no arrival time to check"
        )
        try HostLoad.live.checkWithinBound(
            arrival, bound: 5.0,
            "Banner arrival, latency tripwire (#127 target 200ms; bound above the production path's own worst case, #233)")
    }

    /// #343: server mode re-execs itself (POSIX_SPAWN_SETEXEC + disclaim) before any
    /// dispatch, so the banner is written by the re-exec'd image only. Guards against a
    /// future change that moves the banner, or the re-exec, and prints it from both images.
    func testBannerIsEmittedExactlyOnceAfterTheReexec() throws {
        // Without the responsibility SPI nothing re-execs, and no FORCE notice is printed.
        // Under a launcher that makes every child its own responsible process, the child is
        // already self-responsible, decides `alreadySelfResponsible`, and never re-execs.
        try ChildAttribution.requireHostAttributedChild()
        let binary = try locateBuiltBinary()
        // FORCE, so the re-exec happens on every host: whether a plain run re-execs depends on
        // the runner's own grant (status-aware rule), and Terminal / Xcode / CI may have one.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CHE_ICAL_MCP_") }
        env["CHE_ICAL_MCP_FORCE_DISCLAIM"] = "1"

        let run = try spawnAndCaptureStderr(binary: binary, environment: env)

        try checkSpawnBounds(run, "The server under FORCE (it should exit by itself on stdin EOF)")   // #417
        if run.stderr.contains("restricted by a policy") {
            throw XCTSkip("the host is restricted by a policy, and CHE_ICAL_MCP_FORCE_DISCLAIM yields to that (#367)")
        }
        // The run must actually go through the re-exec, or this test checks a single image
        // and proves nothing (verify round 2 row 6).
        XCTAssertTrue(run.stderr.contains("CHE_ICAL_MCP_FORCE_DISCLAIM is set"),
                      "the spawn did not re-exec. Got stderr: \(run.stderr.prefix(400))")
        // The notice is printed before the exec is attempted, so it shows the decision, not
        // that the exec happened; a failed exec says so on the next line (verify round 3 row 5).
        XCTAssertFalse(run.stderr.contains("could not re-exec"),
                       "the re-exec failed. Got stderr: \(run.stderr.prefix(400))")
        let headers = run.stderr.components(separatedBy: "[banner] che-ical-mcp ").count - 1
        XCTAssertEqual(headers, 1, "Expected exactly one banner header. Got stderr: \(run.stderr.prefix(400))")
    }

    /// Setting `CHE_ICAL_MCP_NO_BANNER=1` must completely suppress banner output.
    func testBannerSuppressedByEnvironmentVariable() throws {
        let binary = try locateBuiltBinary()
        var env = ProcessInfo.processInfo.environment
        env["CHE_ICAL_MCP_NO_BANNER"] = "1"

        let run = try spawnAndCaptureStderr(binary: binary, environment: env)

        try checkSpawnBounds(run, "The server with the banner suppressed (it should still exit by itself on stdin EOF)")   // #417
        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertFalse(
            run.stderr.contains("[banner]"),
            "Env-var should fully suppress banner. Got stderr: \(run.stderr)"
        )
        XCTAssertFalse(
            run.stderr.contains("[drift]"),
            "Env-var should also suppress drift signals. Got stderr: \(run.stderr)"
        )
    }

    /// `--version` exits before the MCP-server-mode code path, so no banner.
    func testNoBannerForVersionFlag() throws {
        let binary = try locateBuiltBinary()
        let run = try spawnAndCaptureStderr(
            binary: binary,
            arguments: ["--version"]
        )

        try checkSpawnBounds(run, "--version (it should exit by itself)")   // #417
        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertFalse(
            run.stderr.contains("[banner]"),
            "--version path should not emit banner. Got stderr: \(run.stderr)"
        )
    }

    /// `--help` exits before banner too. Same path as `--version`, separate test to
    /// document the contract explicitly.
    func testNoBannerForHelpFlag() throws {
        let binary = try locateBuiltBinary()
        let run = try spawnAndCaptureStderr(
            binary: binary,
            arguments: ["--help"]
        )

        try checkSpawnBounds(run, "--help (it should exit by itself)")   // #417
        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertFalse(
            run.stderr.contains("[banner]"),
            "--help path should not emit banner. Got stderr: \(run.stderr)"
        )
    }

    /// #163 / #122 skip-list: `--setup` must emit no banner. Checked structurally over the source,
    /// not by spawning the binary (#249): in a GUI session `--setup` runs the interactive
    /// SetupWindow `NSApplication` (#143 keeps `CI` from making it non-interactive), which takes
    /// focus and never exits by itself, and a test cannot make the child non-interactive from
    /// outside. The contract holds by control flow, so the test pins that control flow:
    /// (a) the `--setup` block sits above the top-level `emitStartupBanner()` call; (b) inside it
    /// the non-interactive branch ends in `exit(` and the interactive branch calls
    /// `SetupRunner.runInteractive()`; (c) `runInteractive()` is declared `-> Never`. The block
    /// itself must not mention `emitStartupBanner`. Matched on code only (comments and string
    /// contents blanked) and on the call token, not the whole line (#249 verify).
    func testNoBannerForSetupFlag() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP")
        let main = try String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8)
        // Code only: line comments and string literals are blanked, so a comment or a message that
        // mentions `exit(` or `emitStartupBanner` does not count, and a trailing comment or a
        // wrapped line does not break the match (#249 verify).
        let code = main.components(separatedBy: "\n").map(Self.codeOnly)

        let raw = main.components(separatedBy: "\n")
        let setupStart = try XCTUnwrap(
            code.indices.first { code[$0].contains("if CommandLine.arguments.contains(") && raw[$0].contains(#""--setup""#) },
            "main.swift must have a --setup block")
        let setupEnd = try XCTUnwrap(Self.closingLine(of: setupStart, in: code),
                                     "the --setup block must close")
        let bannerCall = try XCTUnwrap(
            code.firstIndex { $0.contains("emitStartupBanner(") && !$0.contains("func emitStartupBanner") },
            "main.swift must call emitStartupBanner()")
        XCTAssertLessThan(setupEnd, bannerCall, "(a) the --setup block must come before the banner call")

        let block = code[setupStart...setupEnd].joined(separator: "\n")
        XCTAssertFalse(block.contains("emitStartupBanner"), "(a) the --setup block must not emit the banner itself")
        let headless = try XCTUnwrap(block.range(of: "SetupRunner.requestBoth(nonInteractive: true)"),
                                     "(b) the non-interactive branch must request headlessly")
        let elseBranch = try XCTUnwrap(block.range(of: #"\}\s*else\s*\{"#, options: .regularExpression,
                                                   range: headless.upperBound..<block.endIndex),
                                       "(b) the --setup block must have an interactive branch")
        XCTAssertNotNil(block.range(of: #"\bexit\("#, options: .regularExpression,
                                    range: headless.upperBound..<elseBranch.lowerBound),
                        "(b) the non-interactive branch must end in exit(")
        XCTAssertNotNil(block.range(of: "SetupRunner.runInteractive()", range: elseBranch.upperBound..<block.endIndex),
                        "(b) the interactive branch must call SetupRunner.runInteractive()")

        let runner = try String(contentsOf: sources.appendingPathComponent("SetupRunner.swift"), encoding: .utf8)
            .components(separatedBy: "\n").map(Self.codeOnly).joined(separator: "\n")
        XCTAssertNotNil(runner.range(of: #"static\s+func\s+runInteractive\(\)\s*->\s*Never"#, options: .regularExpression),
                        "(c) runInteractive() must never return, or the banner could follow it")
    }

    /// A source line with its string literals emptied (`"..."` becomes `""`) and its line comment removed.
    private static func codeOnly(_ line: String) -> String {
        var out = "", inString = false, escaped = false
        var chars = Array(line)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false; out.append(c) }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "/", chars.first == "/" {
                break
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// The index of the line that closes the brace opened on `start`, counting braces in code only.
    private static func closingLine(of start: Int, in code: [String]) -> Int? {
        var depth = 0, opened = false
        for i in start..<code.count {
            for c in code[i] {
                if c == "{" { depth += 1; opened = true }
                if c == "}" { depth -= 1 }
            }
            if opened, depth == 0 { return i }
        }
        return nil
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
        // assessed). The banner only emits after that. The helper waits for the child to exit
        // (it exits on stdin EOF right after the banner), so the cap only has to comfortably
        // exceed cold-exec assessment; 10s gives margin for slower/CI hosts without risking a
        // job hang (the post-kill waitUntilExit is independently capped at 3s). 10s has also
        // been the helper's default since #233; it stays explicit so this test keeps its
        // budget if the default changes.
        let run = try spawnAndCaptureStderr(binary: tempBinary, maxWait: 10.0)

        try checkSpawnBounds(run, "The server from an arbitrary path (it should exit by itself on stdin EOF after the banner)")   // #417
        XCTAssertTrue(
            run.stderr.contains("[banner] che-ical-mcp"),
            "Banner should appear even from arbitrary path. Got stderr: \(run.stderr.prefix(200))"
        )
        XCTAssertTrue(
            run.stderr.contains(tempBinary.path),
            "Banner should print the temp path we spawned from. Got: \(run.stderr.prefix(400))"
        )
    }
}
