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
final class SelfDisclaimBinaryTests: XCTestCase {

    private struct Run {
        let pid: Int32
        let stdout: String
        let status: Int32
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

    private func runPrintTCCPath(extraEnvironment: [String: String] = [:]) throws -> Run {
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
        // Drain before waiting so a full pipe can never stall the child.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + 15) == .timedOut {
            kill(pid, SIGKILL)
            XCTFail("--print-tcc-path did not exit within 15s")
        }
        return Run(pid: pid, stdout: String(decoding: output, as: UTF8.self), status: process.terminationStatus)
    }

    /// The first line under the "TCC attribution" heading.
    private func attributionLine(_ stdout: String) -> String? {
        let lines = stdout.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("TCC attribution") }),
              heading + 1 < lines.count else { return nil }
        return lines[heading + 1]
    }

    func testDefault_reexecsAsItsOwnResponsibleProcessKeepingThePid() throws {
        let run = try runPrintTCCPath()
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout), "no TCC attribution block in:\n\(run.stdout)")
        XCTAssertTrue(line.hasPrefix("  \(run.pid)  "), "pid must survive the re-exec; got \(line)")
        XCTAssertTrue(line.hasSuffix("(this binary)"), "the re-exec'd image must be self-responsible; got \(line)")
    }

    func testOptOut_keepsTheHostAsTheResponsibleProcess() throws {
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"])
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "opt-out must leave the host responsible; got \(line)")
    }

    func testSentinelAlreadySet_doesNotReexecAgain() throws {
        // The loop guard: a process that believes it is the re-exec'd image must not
        // re-exec, even though (here) it is not actually self-responsible.
        let run = try runPrintTCCPath(extraEnvironment: ["CHE_ICAL_MCP_DISCLAIMED": "1"])
        XCTAssertEqual(run.status, 0)
        let line = try XCTUnwrap(attributionLine(run.stdout))
        XCTAssertFalse(line.hasSuffix("(this binary)"), "sentinel must skip the re-exec; got \(line)")
    }
}
