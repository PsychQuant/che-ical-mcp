import Foundation

// MARK: - Stderr Capture Harness (#83)

/// Run `body` while capturing anything written to `STDERR_FILENO`.
/// Returns the captured bytes as `String`, plus the closure's return value.
///
/// **Audience**: tests that need to assert stderr behavior of code that
/// writes via `FileHandle.standardError.write` — particularly the sanitizer
/// cluster's trusted-branch carve-out invariant
/// (`TrustedErrorMessage` → no stderr write; non-trusted → exactly one
/// escaped stderr line). Centralizes the dup2-restore-then-close pattern
/// across all sanitizer-cluster sites.
///
/// **dup2 deadlock detail**: `dup2(pipe.write.fd, STDERR_FILENO)` makes
/// FD 2 a *copy* of the pipe's write-end FD. Both must be closed before
/// the pipe reader sees EOF — otherwise `readDataToEndOfFile()` blocks
/// forever. We restore stderr (via `dup2(savedFD, STDERR_FILENO)` —
/// closes FD 2's pointer to the pipe write end) BEFORE `closeFile()` on
/// the explicit FileHandle (drops the last writer reference). Discovered
/// during #80 CLIRunnerStderrTests; centralized here per #83.
///
/// **Usage**:
/// ```swift
/// let (_, captured) = withCapturedStderr {
///     EventKitErrorSanitizer.writeFailureLog(handler: "h", identifier: "i", error: someError)
/// }
/// XCTAssertTrue(captured.contains("h(i) failed:"))
/// ```
///
/// `rethrows` — closure may throw; the captured stderr up to the throw
/// point is still returned via the rethrown error path is NOT supported
/// (you'd need a do/catch around the helper for that). For the common
/// "drive a non-throwing call and assert stderr" case, this is a 1-liner.
///
/// **Test isolation**: each call allocates a fresh `Pipe`. After the
/// helper returns, `STDERR_FILENO` is fully restored — subsequent tests
/// see the test runner's normal stderr. Process FD count is unchanged.
@discardableResult
func withCapturedStderr<R>(_ body: () throws -> R) rethrows -> (result: R, stderr: String) {
    let pipe = Pipe()
    let savedFD = dup(STDERR_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

    let r: R
    do {
        r = try body()
    } catch {
        // Restore stderr + close pipe write end before rethrowing so
        // the test runner's stderr is safe even on assertion failure.
        dup2(savedFD, STDERR_FILENO)
        close(savedFD)
        pipe.fileHandleForWriting.closeFile()
        throw error
    }

    // 1. Restore real stderr — also closes FD 2's dup of pipe write end.
    dup2(savedFD, STDERR_FILENO)
    close(savedFD)
    // 2. Drop the last writer reference so the reader sees EOF.
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (r, String(data: data, encoding: .utf8) ?? "")
}

/// Convenience: discards the closure return value and returns just the
/// captured stderr. Use when the closure is `() -> Void` (the typical
/// "drive a function that writes stderr" case).
@discardableResult
func capturedStderr(of body: () throws -> Void) rethrows -> String {
    let (_, captured) = try withCapturedStderr(body)
    return captured
}
