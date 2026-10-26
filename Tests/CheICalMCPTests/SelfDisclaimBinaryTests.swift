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
/// Whether the *default* run re-execs depends on who the test runner's own responsible
/// process is (Claude Code: yes; Terminal, Xcode, CI: no, by design), and a spawned child
/// inherits it. The tests therefore either force the re-exec with
/// `CHE_ICAL_MCP_FORCE_DISCLAIM` (deterministic on every host) or compute the expectation
/// from the runner's own responsible process.
final class SelfDisclaimBinaryTests: XCTestCase {

    private struct Run {
        let pid: Int32
        let stdout: String
        let status: Int32
        let timedOut: Bool
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

    /// Runs `--print-tcc-path` with a hard bound: stdout is drained on a background queue so a
    /// child that hangs without closing it still reaches the timeout below and is killed,
    /// instead of blocking this thread inside `readDataToEndOfFile` (verify of PR #347).
    private func runPrintTCCPath(extraEnvironment: [String: String] = [:], timeout: TimeInterval = 15) throws -> Run {
        let process = Process()
        process.executableURL = try locateBuiltBinary()
        process.arguments = ["--print-tcc-path"]
        process.environment = environment(extraEnvironment)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = Pipe()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let pid = process.processIdentifier

        let drained = DispatchSemaphore(value: 0)
        let collected = LockedData()
        DispatchQueue.global().async {
            collected.set(stdout.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 5)
        }
        // The pipe closes once the child (or its kill) is gone; bound this wait too.
        _ = drained.wait(timeout: .now() + 5)
        return Run(
            pid: pid, stdout: String(decoding: collected.get(), as: UTF8.self),
            status: process.terminationStatus, timedOut: timedOut)
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

    func testForcedDisclaim_reexecsAsItsOwnResponsibleProcessKeepingThePid() throws {
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"])
        XCTAssertFalse(run.timedOut, "--print-tcc-path did not exit within the bound")
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout), "no TCC attribution block in:\n\(run.stdout)")
        XCTAssertTrue(line.hasPrefix("  \(run.pid)  "), "pid must survive the re-exec; got \(line)")
        XCTAssertTrue(line.hasSuffix("(this binary)"), "the re-exec'd image must be self-responsible; got \(line)")
    }

    func testDefault_followsTheKindOfTheRunnersResponsibleProcess() throws {
        // Claude Code can never be prompted, so a child of it re-execs; any other host keeps
        // its own grant and is left alone. The child inherits the runner's responsible
        // process, so the runner's own kind is the expectation.
        let runner = LiveResponsibleProcessSource().responsibleProcess(for: getpid())
        guard case .resolved(let process) = runner else { throw XCTSkip("responsibility SPI unavailable here") }
        var expectsReexec = false
        if case .claudeCode = process.kind { expectsReexec = true }
        if process.isSelf { throw XCTSkip("the test runner is its own responsible process") }

        let run = try runPrintTCCPath()
        XCTAssertFalse(run.timedOut)
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertEqual(
            line.hasSuffix("(this binary)"), expectsReexec,
            "runner's responsible process is \(process.kind); got \(line)")
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

    func testSentinelAlreadySet_doesNotReexecAgain() throws {
        // The loop guard: a process that believes it is the re-exec'd image must not
        // re-exec, even though (here) it is not actually self-responsible and a re-exec is forced.
        let run = try runPrintTCCPath(extraEnvironment: [
            "CHE_ICAL_MCP_DISCLAIMED": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1",
        ])
        XCTAssertFalse(run.timedOut)
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "sentinel must skip the re-exec; got \(line)")
    }

    func testAHungChildIsKilledAtTheBound_notWaitedOnForever() throws {
        // The bound has to be reachable: a child that never closes stdout must fail the
        // test within the timeout instead of hanging the job. `sleep` stands in for it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let stdout = Pipe()
        process.standardOutput = stdout
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let pid = process.processIdentifier

        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let started = Date()
        XCTAssertEqual(exited.wait(timeout: .now() + 1), .timedOut)
        kill(pid, SIGKILL)
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
