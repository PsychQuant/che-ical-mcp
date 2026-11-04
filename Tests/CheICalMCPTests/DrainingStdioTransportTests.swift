import Darwin
import Foundation
import MCP
import System
import XCTest
@testable import CheICalMCP

/// #345: `DrainingStdioTransport` over a pair of pipes instead of the process's stdio, so the drain
/// and its timeout are tested without spawning the binary.
final class DrainingStdioTransportTests: XCTestCase {
    private struct Pipes {
        let transport: DrainingStdioTransport
        let clientWrite: Int32   // what the "client" writes; the transport reads it
        let serverRead: Int32    // what the transport writes; drained by the test
    }

    private func makeTransport(drainTimeout: Duration) throws -> Pipes {
        var toServer: [Int32] = [0, 0], toClient: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toServer), 0)
        XCTAssertEqual(pipe(&toClient), 0)
        let inner = StdioTransport(input: FileDescriptor(rawValue: toServer[0]),
                                   output: FileDescriptor(rawValue: toClient[1]))
        return Pipes(transport: DrainingStdioTransport(inner: inner, drainTimeout: drainTimeout),
                     clientWrite: toServer[1], serverRead: toClient[0])
    }

    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// The receive stream stays open after EOF until the request read before it is answered.
    func testTheStreamEndsOnlyAfterTheReplyIsSent() async throws {
        let p = try makeTransport(drainTimeout: .seconds(10))
        try await p.transport.connect()
        write(p.clientWrite, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        close(p.clientWrite)   // EOF

        let clock = ContinuousClock()
        let start = clock.now
        let reader = Task { () -> Int in
            var messages = 0
            for try await _ in await p.transport.receive() { messages += 1 }
            return messages
        }
        try await Task.sleep(for: .milliseconds(300))
        try await p.transport.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        let messages = try await reader.value
        let elapsed = clock.now - start

        XCTAssertEqual(messages, 1)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300), "the stream must wait for the reply")
        XCTAssertLessThan(elapsed, .seconds(5), "and end soon after it, not at the timeout")
        close(p.serverRead)
        await p.transport.disconnect()
    }

    /// A request that is never answered holds the stream only until the timeout.
    func testAnUnansweredRequestIsDroppedAtTheTimeout() async throws {
        let p = try makeTransport(drainTimeout: .milliseconds(300))
        try await p.transport.connect()
        write(p.clientWrite, #"{"jsonrpc":"2.0","id":"never","method":"tools/call"}"# + "\n")
        close(p.clientWrite)

        let clock = ContinuousClock()
        let start = clock.now
        var messages = 0
        for try await _ in await p.transport.receive() { messages += 1 }
        let elapsed = clock.now - start

        XCTAssertEqual(messages, 1)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        XCTAssertLessThan(elapsed, .seconds(5))
        close(p.serverRead)
        await p.transport.disconnect()
    }

    /// Notifications only: nothing to wait for, the stream ends at EOF.
    func testWithNothingOutstandingTheStreamEndsAtEOF() async throws {
        let p = try makeTransport(drainTimeout: .seconds(30))
        try await p.transport.connect()
        write(p.clientWrite, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n")
        close(p.clientWrite)

        let clock = ContinuousClock()
        let start = clock.now
        var messages = 0
        for try await _ in await p.transport.receive() { messages += 1 }

        XCTAssertEqual(messages, 1)
        XCTAssertLessThan(clock.now - start, .seconds(5), "no drain wait without an outstanding request")
        close(p.serverRead)
        await p.transport.disconnect()
    }
}
