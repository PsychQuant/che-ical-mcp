import Foundation

/// Shared subprocess runner for the TCC drift detector's `sqlite3` + `ps` invocations
/// (#126). Hard-cap timeout via `DispatchSourceTimer` + `process.terminate()` so a hung
/// child never blocks MCP server startup.
///
/// Background: `LiveTCCDatabaseSource` and `LiveProcessInventorySource` (introduced in
/// #122) both spawn subprocesses and block on `readDataToEndOfFile()` + `waitUntilExit()`
/// during the synchronous startup banner. With no timeout, a hung `sqlite3` (TCC.db
/// locked by another process) or `ps` (sandbox edge case) blocks the MCP server forever.
/// The banner is opt-out via `CHE_ICAL_MCP_NO_BANNER`, but a first-hit user has no escape.
/// This helper guarantees worst-case bounded blocking.
enum SubprocessRunner {
    /// Run `process` and return its captured stdout/stderr + exit status, or surface a
    /// timeout. Closes parent write-end fds (mirrors the existing fix for the GHA-
    /// reproducible deadlock) before reading.
    ///
    /// - Parameters:
    ///   - process: pre-configured `Process` (executableURL + arguments + env). Caller must
    ///     not have already set `standardOutput` / `standardError` — this helper attaches
    ///     pipes itself.
    ///   - timeoutMilliseconds: hard-cap wall-clock budget. On expiry, the child receives
    ///     `SIGTERM` via `process.terminate()` and the `timedOut` flag is set.
    /// - Throws: the underlying `Process.run()` error if spawn fails (e.g. ENOENT).
    static func run(process: Process, timeoutMilliseconds: Int) throws -> SubprocessRunResult {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Close parent's write-end fds. Required for `readDataToEndOfFile` to actually see
        // EOF on macOS — see ProcessInventorySource / TCCDatabaseSource history.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        // Arm the timeout. DispatchSourceTimer runs on a background queue so it can fire
        // SIGTERM while the main thread blocks in readDataToEndOfFile.
        let timeoutQueue = DispatchQueue(label: "che-ical-mcp.subprocess-timeout")
        let timer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        // `Sendable`-safe flag for whether the timer fired before the child exited.
        // We use an `os_unfair_lock`-wrapped Bool via NSLock for simplicity — the
        // critical section is tiny (read or set a Bool) and contention is at most
        // 1 reader + 1 writer per subprocess run.
        let timedOutFlag = TimeoutFlag()
        timer.schedule(deadline: .now() + .milliseconds(timeoutMilliseconds))
        timer.setEventHandler { [weak process] in
            timedOutFlag.set(true)
            process?.terminate()
        }
        timer.resume()

        // Read pipes BEFORE waitUntilExit. If the timer fires and we terminate(), the
        // child exits, its fds close, EOF arrives, reads complete.
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        return SubprocessRunResult(
            stdoutData: outputData,
            stderrData: errData,
            exitStatus: process.terminationStatus,
            timedOut: timedOutFlag.get()
        )
    }
}

/// Captured outcome of a `SubprocessRunner.run` invocation.
struct SubprocessRunResult {
    let stdoutData: Data
    let stderrData: Data
    /// Process exit status. When `timedOut == true`, this typically reflects the SIGTERM
    /// disposition (e.g. negative on macOS) and callers should prefer `timedOut` over
    /// `exitStatus` for error attribution.
    let exitStatus: Int32
    /// `true` if the wall-clock budget expired before the child exited naturally and the
    /// runner sent SIGTERM to force completion.
    let timedOut: Bool
}

/// Tiny lock-wrapped Bool. Doesn't need OSAllocatedUnfairLock (which would force iOS 16+
/// in a way that interacts awkwardly with our existing deploy floor); NSLock is fine for
/// the one-writer (timer) / one-reader (main thread post-wait) usage pattern here.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
