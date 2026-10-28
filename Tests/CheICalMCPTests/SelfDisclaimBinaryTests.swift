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
/// Reminders access keeps the host's grant, anything else re-execs. The tests therefore
/// either force the re-exec with `CHE_ICAL_MCP_FORCE_DISCLAIM` (deterministic on every host)
/// or read the expectation from an opted-out child under the same host.
final class SelfDisclaimBinaryTests: XCTestCase {

    struct Run {
        let pid: Int32
        let stdout: String
        let stderr: String
        let status: Int32
        let timedOut: Bool
        let elapsed: TimeInterval
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
    static func runBounded(
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
        _ = drained.wait(timeout: .now() + 5)
        return Run(
            pid: pid,
            stdout: String(decoding: collectedOut.get(), as: UTF8.self),
            stderr: String(decoding: collectedErr.get(), as: UTF8.self),
            status: process.terminationStatus, timedOut: timedOut,
            elapsed: Date().timeIntervalSince(started))
    }

    private func runPrintTCCPath(extraEnvironment: [String: String] = [:], timeout: TimeInterval = 15) throws -> Run {
        try Self.runBounded(
            executable: try locateBuiltBinary(), arguments: ["--print-tcc-path"],
            environment: environment(extraEnvironment), timeout: timeout)
    }

    final class LockedData: @unchecked Sendable {
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

    /// The runner's responsible process, or a skip when the runner is its own (then a child
    /// cannot show the difference between the host's grant and CheICalMCP's).
    private func runnersHost() throws -> ResponsibleProcess {
        guard case .resolved(let process) = LiveResponsibleProcessSource().responsibleProcess(for: getpid()) else {
            throw XCTSkip("responsibility SPI unavailable here")
        }
        if process.isSelf { throw XCTSkip("the test runner is its own responsible process") }
        return process
    }

    func testForcedDisclaim_reexecsAsItsOwnResponsibleProcessKeepingThePid() throws {
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"])
        XCTAssertFalse(run.timedOut, "--print-tcc-path did not exit within the bound")
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout), "no TCC attribution block in:\n\(run.stdout)")
        XCTAssertTrue(line.hasPrefix("  \(run.pid)  "), "pid must survive the re-exec; got \(line)")
        XCTAssertTrue(line.hasSuffix("(this binary)"), "the re-exec'd image must be self-responsible; got \(line)")
    }

    func testForcedDisclaim_saysSoOnStderr() throws {
        // Round 2 row 7: FORCE is an environment variable a parent can set unnoticed, and the
        // re-exec it causes used to be silent.
        _ = try runnersHost()
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"])
        XCTAssertFalse(run.timedOut)
        XCTAssertTrue(run.stderr.contains("CHE_ICAL_MCP_FORCE_DISCLAIM is set"), "stderr: \(run.stderr)")
    }

    func testDefault_followsTheHostsAuthorizationStatus() throws {
        // A host whose context already has full Calendar and Reminders access keeps it; any
        // other re-execs. The oracle is a fresh opted-out child under the same host: it reports
        // the host's status as the server's pre-exec read sees it. Reading the status in the
        // test runner instead was flaky in the full suite (2026-10-28: the runner read "not
        // usable" while both fresh children read fullAccess), after a thousand in-process tests.
        _ = try runnersHost()
        let host = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"])
        XCTAssertFalse(host.timedOut)
        let usable = ["Calendar", "Reminders"].allSatisfy { service in
            host.stdout.components(separatedBy: "\n").contains {
                $0.hasPrefix("  \(service):") && $0.contains(" fullAccess")
            }
        }

        let run = try runPrintTCCPath()
        XCTAssertFalse(run.timedOut)
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertEqual(
            line.hasSuffix("(this binary)"), !usable,
            "host grant usable: \(usable); got \(line)")
    }

    func testOptOut_keepsTheHostAsTheResponsibleProcess() throws {
        let run = try runPrintTCCPath(extraEnvironment: [
            "CHE_ICAL_MCP_NO_DISCLAIM": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1",
        ])
        XCTAssertFalse(run.timedOut)
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "opt-out must leave the host responsible; got \(line)")
    }

    func testSentinelAlreadySet_doesNotReexecAgain_andSaysItHadNoEffect() throws {
        // The loop guard: a process that believes it is the re-exec'd image must not re-exec,
        // even though (here) it is not actually self-responsible and a re-exec is forced. With
        // some other process still responsible, the sentinel is stale — reported for any host.
        _ = try runnersHost()
        let run = try runPrintTCCPath(extraEnvironment: [
            "CHE_ICAL_MCP_DISCLAIMED": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1",
        ])
        XCTAssertFalse(run.timedOut)
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "sentinel must skip the re-exec; got \(line)")
        XCTAssertTrue(
            run.stderr.contains("CHE_ICAL_MCP_DISCLAIMED is set but another process is still responsible"),
            "the message must not assume Claude Code is the host; stderr: \(run.stderr)")
    }

    func testAHungChildIsKilledAtTheBound_notWaitedOnForever() throws {
        // The bound has to be reachable: a child that never exits or closes its pipes must end
        // the run at the timeout instead of hanging the job. `sleep` stands in for it, run
        // through the same helper every test above uses.
        let run = try Self.runBounded(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: nil, timeout: 1)
        XCTAssertTrue(run.timedOut)
        XCTAssertLessThan(run.elapsed, 10)
    }
}
