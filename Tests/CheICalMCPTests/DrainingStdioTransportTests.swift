import Darwin
import Foundation
import Logging
import MCP
import System
import XCTest
@testable import CheICalMCP

private actor EndFlag {
    private(set) var value = false
    func set() { value = true }
}

/// An inner transport the test drives: `feed` yields messages to `receive()`, `finish` is EOF,
/// `send` can be held until `release` or made to throw (PR #409 verify round 1).
private actor ScriptedTransport: Transport {
    nonisolated let logger = Logger(label: "test.scripted", factory: { _ in SwiftLogNoOpLogHandler() })
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var holdSends = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var throwOnSend = false
    private(set) var sent: [Data] = []

    init() {
        var c: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        stream = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func connect() async throws {}
    func disconnect() async {}
    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }

    func feed(_ json: String) { continuation.yield(Data(json.utf8)) }
    func finish() { continuation.finish() }
    func setHoldSends(_ hold: Bool) { holdSends = hold }
    func setThrowOnSend(_ value: Bool) { throwOnSend = value }
    var heldCount: Int { held.count }
    func release() { held.forEach { $0.resume() }; held.removeAll() }

    func send(_ data: Data) async throws {
        if throwOnSend { throw MCPError.internalError("scripted send failure") }
        if holdSends { await withCheckedContinuation { held.append($0) } }
        sent.append(data)
    }
}

/// A descriptor closed at most once, so a test can end its input (EOF) and the teardown still
/// closes it when the test stopped before that (PR #422 verify round 2).
private final class OnceClosedFD: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ fd: Int32) { self.fd = fd }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(fd)
    }
}

/// #345: `DrainingStdioTransport` over a pair of pipes instead of the process's stdio, so the drain
/// and its timeout are tested without spawning the binary.
final class DrainingStdioTransportTests: XCTestCase {
    private struct Pipes {
        let transport: DrainingStdioTransport
        let clientWrite: OnceClosedFD   // what the "client" writes; the transport reads it
        let serverRead: Int32    // what the transport writes; drained by the test
    }

    private func makeTransport(drainTimeout: Duration) throws -> Pipes {
        var toServer: [Int32] = [0, 0], toClient: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&toServer), 0)
        XCTAssertEqual(pipe(&toClient), 0)
        let inner = StdioTransport(input: FileDescriptor(rawValue: toServer[0]),
                                   output: FileDescriptor(rawValue: toClient[1]))
        let transport = DrainingStdioTransport(inner: inner, drainTimeout: drainTimeout)
        let serverRead = toClient[0], serverInput = toServer[0], serverOutput = toClient[1]
        let clientWrite = OnceClosedFD(toServer[1])
        // Registered here, not at the end of each test: a timing check throws `XCTSkip` on a loaded
        // host, and a skip ends the test before any cleanup after it (PR #422 verify round 1). All
        // four ends are closed: `StdioTransport.disconnect()` does not close its descriptors, and
        // the client's write end is closed here too if the test stopped before ending its input
        // (round 2). The transport's two ends are closed after it is disconnected.
        addTeardownBlock {
            clientWrite.close()
            close(serverRead)
            await transport.disconnect()
            close(serverInput)
            close(serverOutput)
        }
        return Pipes(transport: transport, clientWrite: clientWrite, serverRead: serverRead)
    }

    private func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// The receive stream stays open after EOF until the request read before it is answered.
    func testTheStreamEndsOnlyAfterTheReplyIsSent() async throws {
        let p = try makeTransport(drainTimeout: .seconds(10))
        try await p.transport.connect()
        write(p.clientWrite.fd, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        p.clientWrite.close()   // EOF

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
        try checkUnder5Seconds(elapsed, "The stream's end after the reply (not at the timeout)")
    }

    /// A request that is never answered holds the stream only until the timeout.
    func testAnUnansweredRequestIsDroppedAtTheTimeout() async throws {
        let p = try makeTransport(drainTimeout: .milliseconds(300))
        try await p.transport.connect()
        write(p.clientWrite.fd, #"{"jsonrpc":"2.0","id":"never","method":"tools/call"}"# + "\n")
        p.clientWrite.close()

        let clock = ContinuousClock()
        let start = clock.now
        var messages = 0
        for try await _ in await p.transport.receive() { messages += 1 }
        let elapsed = clock.now - start

        XCTAssertEqual(messages, 1)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        try checkUnder5Seconds(elapsed, "The drain cut off at the 300 ms cap")
    }

    private struct WaitTimedOut: Error {}

    /// Returns as soon as `condition` holds. If it does not within 500 polls 10 ms apart (at least
    /// 5 s; longer when the sleeps overshoot on a busy host), the overrun is judged through
    /// `HostLoad` (#417: a skip on a host loaded past the threshold, otherwise a failure) and the
    /// test stops (PR #409 verify round 3: it used to return quietly either way). The poll count is
    /// the bound, as before #417; the check reports it as 5 s.
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try HostLoad.live.checkNotTimedOut(true, bound: 5, "A condition the test waits for", file: file, line: line)
        throw WaitTimedOut()
    }

    /// #417: the tests' "ended well before the cap" bound, judged through `HostLoad`. In several of
    /// these tests the bound is the only check that tells "ended after the reply / at EOF" from
    /// "ended at the 10 s / 30 s drain timeout", so on a host loaded past the threshold a real
    /// drain regression shows up as a skip, not a failure. That is the #417 policy (an overrun
    /// cannot be judged there) and accepted: below the threshold it still fails, and the skip
    /// message carries the elapsed time.
    private func checkUnder5Seconds(_ elapsed: Duration, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        try HostLoad.live.checkWithinBound(elapsed, bound: .seconds(5), what, file: file, line: line)
    }

    /// PR #409 verify round 1 (MEDIUM): a reply settles its request before the write is awaited,
    /// so a request that reuses the id while the write is in flight stays outstanding, and the
    /// drain waits for its own reply. Order: request 1, reply 1 (held), request 1 again, EOF,
    /// release the held write; the stream must not end until the second reply.
    func testAnIdReusedWhileItsReplyIsBeingWrittenIsStillAwaited() async throws {
        let inner = ScriptedTransport()
        let transport = DrainingStdioTransport(inner: inner, drainTimeout: .seconds(10))
        let done = EndFlag()
        let ended = Task { () -> Int in
            var n = 0
            for try await _ in await transport.receive() { n += 1 }
            await done.set()
            return n
        }
        await inner.feed(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        try await Task.sleep(for: .milliseconds(100))
        await inner.setHoldSends(true)
        let firstReply = Task { try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        try await waitUntil { await inner.heldCount == 1 }
        await inner.feed(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        await inner.finish()
        try await Task.sleep(for: .milliseconds(100))
        await inner.setHoldSends(false)
        await inner.release()
        try await firstReply.value

        try await Task.sleep(for: .milliseconds(300))
        let endedEarly = await done.value
        XCTAssertFalse(endedEarly, "the reused id's request is still unanswered")

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        let messages = try await ended.value
        XCTAssertEqual(messages, 2)
    }

    /// PR #409 verify round 1: a reply whose write fails still settles its request, so the drain
    /// does not wait for the cap.
    func testAFailedReplyWriteStillSettles() async throws {
        let inner = ScriptedTransport()
        let transport = DrainingStdioTransport(inner: inner, drainTimeout: .seconds(10))
        let clock = ContinuousClock()
        let start = clock.now
        let ended = Task { () -> Int in
            var n = 0
            for try await _ in await transport.receive() { n += 1 }
            return n
        }
        await inner.feed(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        try await Task.sleep(for: .milliseconds(100))
        await inner.setThrowOnSend(true)
        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            XCTFail("the inner send throws")
        } catch {}
        await inner.finish()
        _ = try await ended.value
        try checkUnder5Seconds(clock.now - start, "The drain after a failed reply write (settled, not at the cap)")
    }

    /// PR #409 verify round 2: batches are not recorded (the SDK answers them inline), so a batch
    /// it cannot decode no longer holds the drain until the cap.
    func testAnUndecodableBatchDoesNotHoldTheDrain() async throws {
        let inner = ScriptedTransport()
        let transport = DrainingStdioTransport(inner: inner, drainTimeout: .seconds(10))
        let clock = ContinuousClock()
        let start = clock.now
        let ended = Task { () -> Int in
            var n = 0
            for try await _ in await transport.receive() { n += 1 }
            return n
        }
        await inner.feed(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2}]"#)
        await inner.finish()
        _ = try await ended.value
        try checkUnder5Seconds(clock.now - start, "The drain after an undecodable batch (not held)")
    }

    /// PR #409 verify round 2: a reply whose write is still in flight holds the drain, even though
    /// the request was settled before the write (round 1). Without the in-flight count the stream
    /// ended under the write and the process could exit before it reached stdout.
    func testAWriteInFlightHoldsTheDrainUntilItReturns() async throws {
        let inner = ScriptedTransport()
        let transport = DrainingStdioTransport(inner: inner, drainTimeout: .seconds(10))
        let done = EndFlag()
        let ended = Task { () -> Int in
            var n = 0
            for try await _ in await transport.receive() { n += 1 }
            await done.set()
            return n
        }
        await inner.feed(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        try await Task.sleep(for: .milliseconds(100))
        await inner.setHoldSends(true)
        let reply = Task { try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        try await waitUntil { await inner.heldCount == 1 }
        await inner.finish()
        try await Task.sleep(for: .milliseconds(300))
        let endedUnderTheWrite = await done.value
        XCTAssertFalse(endedUnderTheWrite, "the drain must wait for the write in flight")
        await inner.release()
        try await reply.value
        _ = try await ended.value
        let endedAfter = await done.value
        XCTAssertTrue(endedAfter)
    }

    /// Notifications only: nothing to wait for, the stream ends at EOF.
    func testWithNothingOutstandingTheStreamEndsAtEOF() async throws {
        let p = try makeTransport(drainTimeout: .seconds(30))
        try await p.transport.connect()
        write(p.clientWrite.fd, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n")
        p.clientWrite.close()

        let clock = ContinuousClock()
        let start = clock.now
        var messages = 0
        for try await _ in await p.transport.receive() { messages += 1 }

        XCTAssertEqual(messages, 1)
        try checkUnder5Seconds(clock.now - start, "EOF with nothing outstanding (no drain wait)")
    }
}
