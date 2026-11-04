import Darwin
import Foundation
import XCTest

/// #345: the stdio server exited on stdin EOF before replying to a request it had already read
/// (the SDK's per-request task was not awaited, and the process ended when `server.run()`
/// returned). These spawn the built binary, write requests, close stdin at once, and read
/// stdout to EOF. Measured before the fix (v1.20/1.21): `initialize` then EOF got a reply 0 of 5
/// times. The no-request case must still exit by itself (`TCCDriftDetectorBannerTests` relies on
/// it).
final class StdioEOFDrainTests: XCTestCase {
    private func locateBuiltBinary() throws -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = ["\(cwd)/.build/debug/CheICalMCP", "\(cwd)/.build/release/CheICalMCP"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("CheICalMCP binary not found at \(candidates). Run `swift build` first.")
    }

    private struct Run {
        let stdoutLines: [String]
        let terminationStatus: Int32
        let exitedBySelf: Bool
        let seconds: TimeInterval
    }

    /// Spawn the binary, write `input`, close stdin at once, and wait for the child to exit by
    /// itself (capped at `maxWait`, then SIGKILL). stdout and stderr are drained off-thread.
    private func run(_ input: String, maxWait: TimeInterval = 20) throws -> Run {
        let process = Process()
        process.executableURL = try locateBuiltBinary()
        var env = ProcessInfo.processInfo.environment
        env["CHE_ICAL_MCP_NO_BANNER"] = "1"
        env["CHE_ICAL_MCP_NO_DISCLAIM"] = "1"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let lock = NSLock()
        var out = Data()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let outHandle = stdout.fileHandleForReading, errHandle = stderr.fileHandleForReading
        DispatchQueue(label: "StdioEOFDrainTests.out").async {
            while true {
                let chunk = outHandle.availableData
                if chunk.isEmpty { break }
                lock.lock(); out.append(chunk); lock.unlock()
            }
            outDone.signal()
        }
        DispatchQueue(label: "StdioEOFDrainTests.err").async {
            while !errHandle.availableData.isEmpty {}
            errDone.signal()
        }

        let start = Date()
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(maxWait)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let exitedBySelf = !process.isRunning
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let seconds = Date().timeIntervalSince(start)
        _ = outDone.wait(timeout: .now() + 3)
        _ = errDone.wait(timeout: .now() + 3)
        lock.lock(); let text = String(decoding: out, as: UTF8.self); lock.unlock()
        return Run(stdoutLines: text.split(separator: "\n").map(String.init),
                   terminationStatus: process.terminationStatus, exitedBySelf: exitedBySelf, seconds: seconds)
    }

    /// The ids answered on stdout, from single replies and batch replies.
    private func ids(_ lines: [String]) -> Set<String> {
        Set(lines.flatMap { line -> [String] in
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return [] }
            let objects = (parsed as? [[String: Any]]) ?? [(parsed as? [String: Any]) ?? [:]]
            return objects.compactMap { object in
                guard object["result"] != nil || object["error"] != nil, let id = object["id"] else { return nil }
                return "\(id)"
            }
        })
    }

    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"eof-test","version":"0"}}}"#

    func testARequestReadBeforeEOFIsAnswered() throws {
        let run = try run(initialize + "\n")
        XCTAssertTrue(run.exitedBySelf, "the server must still exit by itself after replying")
        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertEqual(ids(run.stdoutLines), ["1"], "stdout: \(run.stdoutLines)")
    }

    /// The issue's second shape: three requests and a notification, then EOF. Before the fix two
    /// replies came back instead of three.
    func testEveryRequestReadBeforeEOFIsAnswered() throws {
        let input = [
            initialize,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
        ].joined(separator: "\n") + "\n"
        let run = try run(input)
        XCTAssertTrue(run.exitedBySelf)
        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertEqual(ids(run.stdoutLines), ["1", "2", "3"], "stdout: \(run.stdoutLines.map { String($0.prefix(80)) })")
    }

    /// PR #409 verify round 2 (MEDIUM): an id the SDK decodes as `Int` above 9e15 was not recorded,
    /// so its reply was lost on EOF.
    func testALargeIntegerIdReadBeforeEOFIsAnswered() throws {
        let run = try run(#"{"jsonrpc":"2.0","id":10000000000000000,"method":"ping"}"# + "\n")
        XCTAssertTrue(run.exitedBySelf)
        XCTAssertEqual(ids(run.stdoutLines), ["10000000000000000"], "stdout: \(run.stdoutLines)")
    }

    /// A batch read before EOF is answered (the SDK handles it inline).
    func testABatchReadBeforeEOFIsAnswered() throws {
        let run = try run(#"[{"jsonrpc":"2.0","id":5,"method":"ping"},{"jsonrpc":"2.0","id":6,"method":"tools/list"}]"# + "\n")
        XCTAssertTrue(run.exitedBySelf)
        XCTAssertEqual(ids(run.stdoutLines), ["5", "6"], "stdout: \(run.stdoutLines.map { String($0.prefix(80)) })")
    }

    /// No request: EOF still ends the server at once, without waiting for the drain timeout.
    func testWithNoRequestEOFStillEndsTheServer() throws {
        let run = try run("")
        XCTAssertTrue(run.exitedBySelf)
        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertTrue(run.stdoutLines.isEmpty, "stdout: \(run.stdoutLines)")
        XCTAssertLessThan(run.seconds, 10, "it must not wait for the drain timeout")
    }
}
