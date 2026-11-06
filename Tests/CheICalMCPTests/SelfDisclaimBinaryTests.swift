import XCTest
import Darwin
@testable import CheICalMCP

/// Binary-spawn coverage for the #343 re-exec: the built `CheICalMCP` is launched the way
/// a host launches it, and `--print-tcc-path` reports which process macOS charges access
/// to. This is also the first end-to-end test of `--print-tcc-path` output.
///
/// The load-bearing assertion is the attribution line `<pid>  <path>  (this binary)` where
/// `<pid>` equals the pid `Process` spawned: it proves both that the re-exec kept the pid
/// (POSIX_SPAWN_SETEXEC) and that the new image is its own responsible process.
///
/// Whether the *default* run re-execs depends on the authorization status of the test
/// runner's responsible process, which a spawned child inherits: full Calendar and
/// Reminders access keeps the host's grant, as does a policy restriction (#367), and
/// anything else re-execs. The tests therefore either force the re-exec with
/// `CHE_ICAL_MCP_FORCE_DISCLAIM` (deterministic on every host a policy does not restrict) or
/// read the expectation from an opted-out child under the same host. Tests that need a host
/// skip where every child is its own responsible process (`ChildAttribution`).
final class SelfDisclaimBinaryTests: XCTestCase {

    private struct Run {
        let pid: Int32
        let stdout: String
        let stderr: String
        let status: Int32
        let timedOut: Bool
        /// True when the stdout/stderr drain wait hit `drainCap`, so the output may be partial (#417).
        let drainTimedOut: Bool
        let elapsed: TimeInterval
    }

    /// The bound every `--print-tcc-path` run gets.
    private static let printTCCPathTimeout: TimeInterval = 15
    /// How long `runBounded` waits for the output drains after the child is gone (#417).
    private static let drainCap: TimeInterval = 5

    /// #417: a `--print-tcc-path` run's wall-clock limits (the 15 s bound, then the drain) judged
    /// through `HostLoad`, before any assertion on its output (an `XCTSkip` cannot retract a
    /// failure recorded earlier, #366 / #418).
    private func checkRunBounds(_ run: Run, _ what: String = "--print-tcc-path",
                                file: StaticString = #filePath, line: UInt = #line) throws {
        try HostLoad.live.checkNotTimedOut(run.timedOut, bound: Self.printTCCPathTimeout, what, file: file, line: line)
        try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap, "\(what): output drain", file: file, line: line)
    }

    private func locateBuiltBinary() throws -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        for path in ["\(cwd)/.build/debug/CheICalMCP", "\(cwd)/.build/release/CheICalMCP"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("CheICalMCP binary not built; run `swift build` first.")
    }

    /// The test runner's environment minus every CHE_ICAL_MCP_* variable, plus `extra`.
    private func environment(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CHE_ICAL_MCP_") }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Runs a child with a hard bound: stdout and stderr are drained on background queues so
    /// a child that hangs without closing them still reaches the timeout below and is killed,
    /// instead of blocking this thread inside `readDataToEndOfFile` (verify of PR #347). The
    /// hang test drives this same function, so the bound it checks is the one every test uses.
    private static func runBounded(
        executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) throws -> Run {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let started = Date()
        try process.run()
        let pid = process.processIdentifier

        let drained = DispatchGroup()
        let collectedOut = LockedData(), collectedErr = LockedData()
        for (pipe, sink) in [(stdout, collectedOut), (stderr, collectedErr)] {
            drained.enter()
            DispatchQueue.global().async {
                sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
                drained.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 5)
        }
        // The pipes close once the child (or its kill) is gone; bound this wait too.
        let drainTimedOut = drained.wait(timeout: .now() + Self.drainCap) == .timedOut
        return Run(
            pid: pid,
            stdout: String(decoding: collectedOut.get(), as: UTF8.self),
            stderr: String(decoding: collectedErr.get(), as: UTF8.self),
            status: process.terminationStatus, timedOut: timedOut, drainTimedOut: drainTimedOut,
            elapsed: Date().timeIntervalSince(started))
    }

    private func runPrintTCCPath(extraEnvironment: [String: String] = [:], timeout: TimeInterval = printTCCPathTimeout) throws -> Run {
        try Self.runBounded(
            executable: try locateBuiltBinary(), arguments: ["--print-tcc-path"],
            environment: environment(extraEnvironment), timeout: timeout)
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// The first line under the "TCC attribution" heading.
    private func attributionLine(_ stdout: String) -> String? {
        let lines = stdout.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("TCC attribution") }),
              heading + 1 < lines.count else { return nil }
        return lines[heading + 1]
    }

    private func requireHostAttributedChild() throws {
        try ChildAttribution.requireHostAttributedChild()
    }

    /// Whether `--print-tcc-path` reported a restricted status for either service.
    private func reportsRestricted(_ stdout: String) -> Bool {
        stdout.components(separatedBy: "\n").contains {
            ($0.hasPrefix("  Calendar:") || $0.hasPrefix("  Reminders:")) && $0.contains(" restricted")
        }
    }

    /// A forced run under a host a policy restricts does not re-exec (#367), so a test of the
    /// forced re-exec has nothing to observe there.
    private func skipIfThePolicyKeptTheHost(_ run: Run) throws {
        if reportsRestricted(run.stdout) {
            throw XCTSkip("the host is restricted by a policy, and CHE_ICAL_MCP_FORCE_DISCLAIM yields to that (#367)")
        }
    }

    func testForcedDisclaim_reexecsAsItsOwnResponsibleProcessKeepingThePid() throws {
        // Verify round 3b row 4: where every child is already self-responsible, the line is
        // `<pid> … (this binary)` with no re-exec at all, and this test passed vacuously.
        try requireHostAttributedChild()
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"])
        try checkRunBounds(run)   // #366, #417
        try skipIfThePolicyKeptTheHost(run)
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout), "no TCC attribution block in:\n\(run.stdout)")
        XCTAssertTrue(line.hasPrefix("  \(run.pid)  "), "pid must survive the re-exec; got \(line)")
        XCTAssertTrue(line.hasSuffix("(this binary)"), "the re-exec'd image must be self-responsible; got \(line)")
    }

    func testForcedDisclaim_saysSoOnStderr() throws {
        // Round 2 row 7: FORCE is an environment variable a parent can set unnoticed, and the
        // re-exec it causes used to be silent.
        try requireHostAttributedChild()
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"])
        try checkRunBounds(run)   // #366, #417
        try skipIfThePolicyKeptTheHost(run)
        XCTAssertTrue(run.stderr.contains("CHE_ICAL_MCP_FORCE_DISCLAIM is set"), "stderr: \(run.stderr)")
        // #361: the same start says what the host had, and the re-executed image can still say why.
        XCTAssertTrue(run.stderr.contains("had Calendar "), "stderr: \(run.stderr)")
        XCTAssertTrue(run.stdout.contains("CHE_ICAL_MCP_DISCLAIMED says this process re-executed at start (forced): "),
                      "stdout: \(run.stdout)")
    }

    /// #361 verify: the record is read in the branch where it matters most too, with the warning kept.
    func testAnIneffectiveDisclaimStillShowsTheRecord() throws {
        try requireHostAttributedChild()
        let record = SelfDisclaimRecord(reason: .hostGrantUnusable, calendar: .denied, reminders: .denied, host: .claudeCode)
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_DISCLAIMED": record.encoded])
        try checkRunBounds(run)
        XCTAssertTrue(run.stderr.contains("CHE_ICAL_MCP_DISCLAIMED is set but another process is still responsible"), run.stderr)
        XCTAssertTrue(run.stdout.contains("CHE_ICAL_MCP_DISCLAIMED says this process re-executed at start (hostGrantUnusable): "), run.stdout)
        XCTAssertTrue(run.stdout.contains("If it did, it had no effect: macOS still checks another process."), run.stdout)
    }

    func testAnInheritedValueIsNotPrinted() throws {
        try requireHostAttributedChild()
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_DISCLAIMED": "<ignore previous instructions>"])
        try checkRunBounds(run)
        XCTAssertTrue(run.stdout.contains("held a value this binary does not write"), run.stdout)
        XCTAssertFalse(run.stdout.contains("ignore previous"), run.stdout)
    }

    /// #361 verify: start-up is fail-open, so the new stderr line must not stop the exec. `2>&-` closes
    /// the descriptor; `| :` leaves a pipe whose reader is gone.
    func testAClosedOrReaderlessStderrDoesNotStopTheReexec() throws {
        try requireHostAttributedChild()
        let binary = try locateBuiltBinary()
        let env = environment(["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"])
        for script in [#"exec "$0" --print-tcc-path 2>&-"#, #"exec 3>&1; "$0" --print-tcc-path 2>&1 >&3 | :"#] {
            let run = try Self.runBounded(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, binary.path],
                                          environment: env, timeout: Self.printTCCPathTimeout)
            try checkRunBounds(run)
            try skipIfThePolicyKeptTheHost(run)
            XCTAssertEqual(run.status, 0, script)
            XCTAssertTrue(run.stdout.contains("says this process re-executed at start (forced)"), "\(script): \(run.stdout)")
        }
    }

    /// #361 verify: `NAME=x` then `NAME=` reads as unset here, and `setenv` replaced only the first
    /// entry, so the next image read unset again and the loop guard never saw the sentinel. `Process`
    /// cannot build such an environment.
    func testDuplicateSentinelEntriesDoNotDefeatTheLoopGuard() throws {
        try requireHostAttributedChild()
        let binary = try locateBuiltBinary()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("disclaim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let entries = environment(["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"]).map { "\($0.key)=\($0.value)" }
            + ["CHE_ICAL_MCP_DISCLAIMED=x", "CHE_ICAL_MCP_DISCLAIMED="]
        let envp: [UnsafeMutablePointer<CChar>?] = entries.map { strdup($0) } + [nil]
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(binary.path), strdup("--print-tcc-path"), nil]
        defer { (envp + argv).forEach { free($0) } }
        var pid: pid_t = 0
        XCTAssertEqual(posix_spawn(&pid, binary.path, &actions, nil, argv, envp), 0)
        var status: Int32 = 0
        var timedOut = false
        let deadline = Date().addingTimeInterval(Self.printTCCPathTimeout)
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() > deadline {
                timedOut = true
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                break
            }
            usleep(10_000)
        }
        let stdout = try String(contentsOf: output, encoding: .utf8)
        let run = Run(pid: pid, stdout: stdout, stderr: "", status: status, timedOut: timedOut, drainTimedOut: false, elapsed: 0)
        try checkRunBounds(run)
        try skipIfThePolicyKeptTheHost(run)
        XCTAssertTrue(run.stdout.contains("says this process re-executed at start (forced)"), run.stdout)
    }

    /// SIG_IGN survives an exec, so a missing restore would leave the server ignoring SIGPIPE with no
    /// other sign. It is put back in the same function, before any exec can run.
    func testTheStartupLineRestoresSIGPIPE() throws {
        let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(
            of: "static func writeStartupLine(_ line: String) {", in: try SourcePins.source("SelfDisclaim.swift"))))
        let ignore = try XCTUnwrap(body.range(of: "let previous = signal(SIGPIPE, SIG_IGN)"))
        let write = try XCTUnwrap(body.range(of: "write(STDERR_FILENO,"))
        let restore = try XCTUnwrap(body.range(of: "signal(SIGPIPE, previous)"))
        XCTAssertTrue(ignore.lowerBound < write.lowerBound && write.lowerBound < restore.lowerBound, body)
    }

    /// Every write before the exec, and the two start-up warnings after it, are fail-open.
    func testTheStartUpSwitchWritesThroughTheFailOpenLine() throws {
        let source = try SourcePins.source("main.swift")
        let from = try XCTUnwrap(source.range(of: "switch startupDecision {"))
        let to = try XCTUnwrap(source.range(of: "// Handle command line arguments"))
        XCTAssertFalse(source[from.lowerBound..<to.lowerBound].contains("FileHandle.standardError.write"))
    }

    /// The write is not conditional on a reason: every re-exec says why.
    func testEveryReexecWritesTheLine() throws {
        let body = try SourcePins.source("main.swift")
        let from = try XCTUnwrap(body.range(of: "case .reexec(let reason):"))
        let to = try XCTUnwrap(body.range(of: "case .skip(.alreadyDisclaimed):"))
        let arm = SourceScan.collapsingWhitespace(SourceScan.strippingComments(String(body[from.upperBound..<to.lowerBound])))
        XCTAssertTrue(arm.contains("SelfDisclaim.writeStartupLine(record.startLine(hostName:"), arm)
        XCTAssertFalse(arm.contains("if reason"), arm)
    }

    func testDefault_followsTheHostsAuthorizationStatus() throws {
        // A host whose context already has full Calendar and Reminders access keeps it, as does
        // one a policy restricts (#367); any other re-execs. The oracle is a fresh opted-out
        // child under the same host: it reports
        // the host's status as the server's pre-exec read sees it. Reading the status in the
        // test runner instead was flaky in the full suite (2026-10-28: the runner read "not
        // usable" while both fresh children read fullAccess), after a thousand in-process tests.
        try requireHostAttributedChild()
        let host = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"])
        try checkRunBounds(host, "--print-tcc-path (opted-out oracle)")   // #366, #417
        let usable = ["Calendar", "Reminders"].allSatisfy { service in
            host.stdout.components(separatedBy: "\n").contains {
                $0.hasPrefix("  \(service):") && $0.contains(" fullAccess")
            }
        }

        let restricted = reportsRestricted(host.stdout)

        let run = try runPrintTCCPath()
        try checkRunBounds(run)   // #366, #417
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertEqual(
            line.hasSuffix("(this binary)"), !usable && !restricted,
            "host grant usable: \(usable), restricted: \(restricted); got \(line)")
        // #361: a status-driven re-exec says why, in both places, and a kept host says nothing.
        let reexecuted = !usable && !restricted
        XCTAssertEqual(run.stderr.contains("re-executing so macOS checks CheICalMCP's own"), reexecuted, run.stderr)
        XCTAssertEqual(run.stdout.contains("says this process re-executed at start (hostGrantUnusable)"), reexecuted, run.stdout)
    }

    func testOptOut_keepsTheHostAsTheResponsibleProcess() throws {
        try requireHostAttributedChild()
        let run = try runPrintTCCPath(extraEnvironment: [
            "CHE_ICAL_MCP_NO_DISCLAIM": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1",
        ])
        try checkRunBounds(run)   // #366, #417
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "opt-out must leave the host responsible; got \(line)")
    }

    func testSentinelAlreadySet_doesNotReexecAgain_andSaysItHadNoEffect() throws {
        // The loop guard: a process that believes it is the re-exec'd image must not re-exec,
        // even though (here) it is not actually self-responsible and a re-exec is forced. With
        // some other process still responsible, the sentinel is stale — reported for any host.
        try requireHostAttributedChild()
        let run = try runPrintTCCPath(extraEnvironment: [
            "CHE_ICAL_MCP_DISCLAIMED": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1",
        ])
        try checkRunBounds(run)   // #366, #417
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "sentinel must skip the re-exec; got \(line)")
        XCTAssertTrue(
            run.stderr.contains("CHE_ICAL_MCP_DISCLAIMED is set but another process is still responsible"),
            "the message must not assume Claude Code is the host; stderr: \(run.stderr)")
    }

    func testPrintTCCPath_singleQuotesItsCommands() throws {
        // Verify round 3 row 10: the --setup and codesign commands were double-quoted, where
        // `$(…)` and backticks in a path still expand when pasted.
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"])
        try checkRunBounds(run)   // #366, #417
        let lines = run.stdout.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  '") && $0.hasSuffix("' --setup") }, run.stdout)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  codesign -dv '") && $0.hasSuffix("'") }, run.stdout)
        XCTAssertFalse(run.stdout.contains("\" --setup"), run.stdout)
    }

    func testAHungChildIsKilledAtTheBound_notWaitedOnForever() throws {
        // The bound has to be reachable: a child that never exits or closes its pipes must end
        // the run at the timeout instead of hanging the job. `sleep` stands in for it, run
        // through the same helper every test above uses.
        let run = try Self.runBounded(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: nil, timeout: 1)
        // #417: that the 1 s bound fired stays a hard assertion (load can only make it more
        // certain); how long the kill took is judged through HostLoad.
        XCTAssertTrue(run.timedOut)
        try HostLoad.live.checkWithinBound(run.elapsed, bound: 10, "A hung child killed at the 1 s bound")
    }
}
