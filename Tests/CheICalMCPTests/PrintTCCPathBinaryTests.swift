import XCTest
import Darwin
import CheMCPKit
@testable import CheICalMCP

/// Binary-spawn coverage for #360: `--print-tcc-path` started through `PATH` (bare argv[0])
/// from a directory that holds another file named `CheICalMCP` must name the binary the
/// kernel ran, not the planted file. This is the reproduction from the issue body.
final class PrintTCCPathBinaryTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintTCCPathBinaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func locateBuiltBinary() throws -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        for path in ["\(cwd)/.build/debug/CheICalMCP", "\(cwd)/.build/release/CheICalMCP"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("CheICalMCP binary not built; run `swift build` first.")
    }

    func testBareArgv0ThroughPATH_namesTheBinaryTheKernelRan_notAFileInTheCurrentDirectory() throws {
        let binary = try locateBuiltBinary()
        let planted = workDir.appendingPathComponent("CheICalMCP")
        try Data().write(to: planted)

        // `env` execs `CheICalMCP` found on PATH and passes the bare name as argv[0].
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["CheICalMCP", "--print-tcc-path"]
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CHE_ICAL_MCP_") }
        env["PATH"] = binary.deletingLastPathComponent().path + ":/usr/bin:/bin"
        env["CHE_ICAL_MCP_NO_DISCLAIM"] = "1"  // keep the run to one image; the re-exec is not under test
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = Pipe()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var output = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let timedOut = exited.wait(timeout: .now() + 20) == .timedOut
        if timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 5)
        }
        let drainTimedOut = drained.wait(timeout: .now() + 3) == .timedOut
        // #417: both limits judged through HostLoad before the output is read (an XCTSkip cannot
        // retract a failure recorded earlier, #366 / #418).
        try HostLoad.live.checkNotTimedOut(timedOut, bound: 20, "--print-tcc-path through PATH (it should exit by itself)")
        try HostLoad.live.checkNotTimedOut(drainTimedOut, bound: 3, "--print-tcc-path through PATH: output drain")
        // A regression above is recorded without throwing. Stop there, as the test did before #417:
        // the output is partial, and after a drain timeout `output` may still be written by the
        // reader (it is not locked), so reading it would race (PR #422 verify round 1).
        guard !timedOut, !drainTimedOut else { return }
        let text = String(decoding: output, as: UTF8.self)

        let lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(of: "Binary path:"), header + 1 < lines.count else {
            return XCTFail("no Binary path section in:\n\(text)")
        }
        let shown = lines[header + 1].trimmingCharacters(in: .whitespaces)
        let plantedPath = BinaryPathResolver.resolveArgv0(planted.path)
        XCTAssertEqual(shown, BinaryPathResolver.resolveArgv0(binary.path))
        XCTAssertNotEqual(shown, plantedPath)
        XCTAssertFalse(text.contains("'\(plantedPath)' --setup"), "the --setup command must not name the planted file")
        // #357 round 4 (R4): agents read this output, so it carries no reset of any kind.
        TCCRemedyAssertions.assertNoReset(text)
    }
}
