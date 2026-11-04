import Foundation
import Logging
import MCP

/// #345: `StdioTransport` with a drain on stdin EOF. It covers requests whose line ends with a
/// newline: the SDK's `StdioTransport` ends its stream at EOF without yielding a last line that
/// has none, so such a request never reaches this wrapper (SDK framing, left as it is).
///
/// The SDK's server handles each request in a task nobody awaits, and the process ends when
/// `server.run()` returns after the receive stream ends, so a request read just before EOF was dropped unanswered. This wrapper records each
/// request it passes on (`OutstandingRequestLedger`) and settles it when the reply goes out
/// through `send`; when the inner stream ends it waits until nothing is outstanding before ending
/// its own stream. With nothing outstanding (no request at all) it ends at once, so EOF still
/// ends an idle server.
///
/// `drainTimeout` caps the wait (30 s, the #345 Diagnosis's conservative default): a request that
/// never gets a reply (a handler that hangs, or a reply under an id we did not record) must not
/// keep the process alive after the client closed stdin. On timeout one line goes to stderr and
/// the remaining requests are dropped.
actor DrainingStdioTransport: Transport {
    nonisolated let logger: Logger
    private let inner: any Transport
    private let drainTimeout: Duration
    private var ledger = OutstandingRequestLedger()
    /// Replies whose write has started and not yet returned.
    private var writesInFlight = 0

    /// `inner` is any transport (tests pass one they drive); production uses `StdioTransport()`.
    init(inner: any Transport = StdioTransport(), drainTimeout: Duration = .seconds(30)) {
        self.inner = inner
        self.logger = Logger(label: "che-ical-mcp.draining-stdio", factory: { _ in SwiftLogNoOpLogHandler() })
        self.drainTimeout = drainTimeout
    }

    func connect() async throws { try await inner.connect() }

    func disconnect() async { await inner.disconnect() }

    /// The reply settles its request **before** the write is awaited (PR #409 verify round 1):
    /// the actor can take a new incoming message during the await, and once a reply is on its way
    /// a client may reuse the id; settling after the await would remove that new request's entry
    /// and let the drain end before its reply. The write itself is counted as in flight until it
    /// returns or throws, so the drain does not end the stream (and the process) under a write
    /// that has not reached stdout yet, and a write that fails does not leave the drain waiting
    /// for the cap.
    func send(_ data: Data) async throws {
        ledger.noteOutgoing(data)
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        try await inner.send(data)
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var failure: Swift.Error?
                do {
                    for try await data in await self.inner.receive() {
                        await self.noteIncoming(data)
                        continuation.yield(data)
                    }
                } catch {
                    failure = error
                }
                await self.drain()
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func noteIncoming(_ data: Data) { ledger.noteIncoming(data) }

    /// Waits until every recorded request is answered and every reply written, or `drainTimeout`
    /// passes.
    private func drain() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: drainTimeout)
        while !ledger.isEmpty || writesInFlight > 0 {
            guard clock.now < deadline, !Task.isCancelled else {
                FileHandle.standardError.write(Data("CheICalMCP: stdin closed; \(ledger.count) request(s) still unanswered and \(writesInFlight) reply write(s) unfinished after \(drainTimeout), exiting without them\n".utf8))
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
