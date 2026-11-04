import Foundation
import Logging
import MCP

/// #345: `StdioTransport` with a drain on stdin EOF. The SDK's server handles each request in a
/// task nobody awaits, and the process ends when `server.run()` returns after the receive stream
/// ends, so a request read just before EOF was dropped unanswered. This wrapper records each
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
    private let inner: StdioTransport
    private let drainTimeout: Duration
    private var ledger = OutstandingRequestLedger()

    init(inner: StdioTransport = StdioTransport(), drainTimeout: Duration = .seconds(30)) {
        self.inner = inner
        self.logger = inner.logger
        self.drainTimeout = drainTimeout
    }

    func connect() async throws { try await inner.connect() }

    func disconnect() async { await inner.disconnect() }

    func send(_ data: Data) async throws {
        try await inner.send(data)
        ledger.noteOutgoing(data)
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

    /// Waits until every recorded request is answered, or `drainTimeout` passes.
    private func drain() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: drainTimeout)
        while !ledger.isEmpty {
            guard clock.now < deadline, !Task.isCancelled else {
                FileHandle.standardError.write(Data("CheICalMCP: stdin closed; \(ledger.count) request(s) still unanswered after \(drainTimeout), exiting without them\n".utf8))
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
