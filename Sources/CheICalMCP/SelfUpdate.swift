import CommonCrypto
import Foundation

// MARK: - Self-update (#49 Option 3)
//
// User-invoked upgrade path: `CheICalMCP --self-update` queries
// GitHub Releases API for the latest tag, compares against
// `AppVersion.current`, and (if newer) atomically replaces the
// running binary at its own path.
//
// **Why discoverable + explicit, not auto**: per #49 design
// discussion, automatic upgrades risk swapping a binary mid-MCP-call
// and break running sessions. Explicit `--self-update` flag is
// listed in `--help` and README so users find it on demand.
//
// **Why atomic replace via POSIX `rename(2)` (#49 verify Finding 2)**:
// the temp file is staged in the target's PARENT directory so that
// `rename(targetPath_temp → targetPath)` is guaranteed same-filesystem
// and atomic. POSIX rename(2) semantics: target either points at the
// new file or the old file at all times — never absent. This fixes
// the original (rm -f + mv) approach which had a window where the
// target didn't exist and could brick the install if mv failed.
//
// Per #62 upgrade-trap discovery: rename(2) ALSO swaps the directory
// entry (not the inode), so running MCP processes that hold the old
// inode keep their reference until exit; the new binary gets a fresh
// inode by construction (the temp file's). No stale code-signature
// cache hazard.

enum SelfUpdate {

    /// Errors surfaced from `--self-update` invocation. Conform to
    /// `LocalizedError` so the printed message is user-friendly.
    /// Errors surfaced from `--self-update` invocation. **NOT** conforming
    /// to `TrustedErrorMessage` (#49 verify Finding 4): the `detail`
    /// strings come from URLSession / FileManager `localizedDescription`
    /// which is framework-controlled, not author-controlled. Per #85's
    /// `CLIError.invalidJSON` doc-comment guidance, `TrustedErrorMessage`
    /// is for messages whose entire content is author-written and safe
    /// to forward verbatim. Self-update errors interpolate framework
    /// text → must go through the standard `escapeForStderr` path on
    /// stderr write to defend against CWE-117 control-char injection.
    /// `sanitizeForInterpolation` is still applied here as defense-in-depth
    /// for the JSON wire path; stderr path is escape-handled at the
    /// caller (see `main.swift` for the escape-on-write pattern).
    enum SelfUpdateError: LocalizedError {
        case networkUnavailable(String)
        case parseError(String)
        case downloadFailed(String)
        case installFailed(String)
        case binaryPathUnresolvable
        case checksumUnavailable(String)
        case checksumMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .networkUnavailable(let detail):
                return "Network error querying GitHub Releases: \(EventKitErrorSanitizer.sanitizeForInterpolation(detail))"
            case .parseError(let detail):
                return "Could not parse GitHub release metadata: \(EventKitErrorSanitizer.sanitizeForInterpolation(detail))"
            case .downloadFailed(let detail):
                return "Binary download failed: \(EventKitErrorSanitizer.sanitizeForInterpolation(detail))"
            case .installFailed(let detail):
                return "Could not install new binary: \(EventKitErrorSanitizer.sanitizeForInterpolation(detail))"
            case .binaryPathUnresolvable:
                return "Could not resolve current binary path. Run as `~/bin/CheICalMCP --self-update` so the binary path is unambiguous."
            case .checksumUnavailable(let detail):
                return "Could not fetch SHA-256 checksum companion file: \(EventKitErrorSanitizer.sanitizeForInterpolation(detail)). " +
                       "If this release predates the SHA-256 publication policy (post-#98), the asset may legitimately lack a .sha256 file. " +
                       "Falling back is unsafe — refusing install. Verify manually via codesign + spctl, or re-run --self-update against a newer release."
            case .checksumMismatch(let expected, let actual):
                return "SHA-256 verification FAILED. Refusing to install. " +
                       "Expected: \(expected)  Actual: \(actual). " +
                       "This indicates the downloaded binary does not match the maintainer-published hash. Possible causes: in-flight tampering, " +
                       "corrupted download, or compromised mirror. Do NOT install. If reproducible against a fresh release, file an issue."
            }
        }
    }

    /// GitHub Releases API URL for the latest tag of this repo.
    /// **Hardcoded to the upstream PsychQuant repo by design** (#49 verify
    /// Finding 5). For fork builds that want self-update against the fork's
    /// own releases, derive owner/repo from build metadata at compile time
    /// (separate enhancement; not pursued here because forks are rare for
    /// this MCP and the maintenance cost of dual-binding outweighs the
    /// benefit at current scale).
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/PsychQuant/che-ical-mcp/releases/latest")!

    /// Asset name on the GitHub release that holds the standalone binary.
    /// Matches the asset created by `make release-signed` + `gh release create`.
    static let assetName = "CheICalMCP"

    /// Run the self-update flow. Prints user-facing progress to stdout.
    /// Throws on any failure mode (network, parse, download, install).
    /// Returns silently on success — caller exits 0.
    static func run() async throws {
        print("CheICalMCP self-update")
        print("Current version: \(AppVersion.current)")
        print("Querying GitHub Releases for latest...")

        let latestTag = try await fetchLatestTag()
        let latestVersion = stripTagPrefix(latestTag)
        print("Latest version:  \(latestVersion)")

        if latestVersion == AppVersion.current {
            print("✓ Already on latest version. No update needed.")
            return
        }

        // Compare semver-ish to make sure we're not "downgrading".
        if !isNewer(candidate: latestVersion, than: AppVersion.current) {
            print("ℹ Latest tag (\(latestVersion)) is not newer than current (\(AppVersion.current)).")
            print("  No update needed. (If you intended to downgrade, do it manually via curl + rm -f.)")
            return
        }

        let currentBinaryPath = try resolveCurrentBinaryPath()
        print("Will install to: \(currentBinaryPath)")

        let downloadURL = makeAssetDownloadURL(tag: latestTag, assetName: assetName)
        let sha256URL = makeAssetDownloadURL(tag: latestTag, assetName: assetName + ".sha256")
        print("Fetching SHA-256 companion (#98 verification): \(sha256URL.absoluteString)")
        let expectedHash = try await fetchExpectedSHA256(from: sha256URL)
        print("Expected SHA-256: \(expectedHash)")

        print("Downloading \(assetName) from \(downloadURL.absoluteString) ...")
        // Stage temp in target's parent directory so installBinary's
        // POSIX rename(2) is guaranteed same-FS atomic (#49 verify F2).
        let tempPath = try await downloadBinary(from: downloadURL, targetPath: currentBinaryPath)

        // After installBinary success, the temp path no longer exists —
        // it WAS the file that became the target. Cleanup defer below
        // covers the failure path where temp survives.
        var installSucceeded = false
        defer {
            if !installSucceeded {
                try? FileManager.default.removeItem(atPath: tempPath)
            }
        }

        // Verify SHA-256 BEFORE install (#98). Refuses install on mismatch.
        let actualHash = try sha256OfFile(at: tempPath)
        print("Actual SHA-256:   \(actualHash)")
        guard actualHash.lowercased() == expectedHash.lowercased() else {
            throw SelfUpdateError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }
        print("✓ SHA-256 verification passed")

        try installBinary(from: tempPath, to: currentBinaryPath)
        installSucceeded = true
        print("✓ Installed \(latestVersion) to \(currentBinaryPath)")
        print("ℹ If this binary is currently running as an MCP server, restart your")
        print("  MCP host (Claude Desktop / Claude Code) to pick up the new version.")
    }

    // MARK: - Internals

    /// Strip leading `v` from tags like `v1.7.1` → `1.7.1`.
    /// Internal so `--self-update` and tests can share the same parser.
    static func stripTagPrefix(_ tag: String) -> String {
        if tag.hasPrefix("v") {
            return String(tag.dropFirst())
        }
        return tag
    }

    /// Best-effort semver-ish comparison. Splits on `.`, compares each
    /// component as Int when possible, falling back to lexicographic.
    /// Returns true iff `candidate` is strictly newer than `current`.
    /// Internal so tests can pin the comparison boundary.
    static func isNewer(candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map(String.init)
        let b = current.split(separator: ".").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let aPart = i < a.count ? a[i] : "0"
            let bPart = i < b.count ? b[i] : "0"
            if let aInt = Int(aPart), let bInt = Int(bPart) {
                if aInt > bInt { return true }
                if aInt < bInt { return false }
            } else {
                if aPart > bPart { return true }
                if aPart < bPart { return false }
            }
        }
        return false  // identical
    }

    /// Build the download URL for a given release tag + asset name.
    /// Internal so tests can pin the URL shape.
    static func makeAssetDownloadURL(tag: String, assetName: String) -> URL {
        let url = "https://github.com/PsychQuant/che-ical-mcp/releases/download/\(tag)/\(assetName)"
        return URL(string: url)!
    }

    /// Resolve the current binary's path on disk. Uses `realpath(3)`
    /// to follow symlinks — important because `~/bin/CheICalMCP` is
    /// often a symlink in dev installs and the user's `argv[0]` may
    /// be a relative path or a symlink target.
    ///
    /// **PATH-resolved invocations** (#49 verify Finding 3): if the
    /// user runs `CheICalMCP --self-update` (no slash in argv[0],
    /// shell-PATH-resolved), `argv[0]` is just `CheICalMCP`. We then
    /// walk `$PATH` to find the executable, then `realpath` that
    /// candidate. Without this, PATH-invoked self-update would throw
    /// `binaryPathUnresolvable` for the most common invocation style.
    private static func resolveCurrentBinaryPath() throws -> String {
        guard let argv0 = CommandLine.arguments.first else {
            throw SelfUpdateError.binaryPathUnresolvable
        }
        // If argv[0] contains a slash, it's a path (absolute or relative).
        // realpath resolves it directly.
        if argv0.contains("/") {
            if let resolved = realpath(argv0, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            // realpath failed but argv0 has a slash — return as-is.
            return argv0
        }

        // PATH-resolved invocation: walk $PATH to find the executable.
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            throw SelfUpdateError.binaryPathUnresolvable
        }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(argv0)"
            if fm.isExecutableFile(atPath: candidate) {
                if let resolved = realpath(candidate, nil) {
                    defer { free(resolved) }
                    return String(cString: resolved)
                }
                return candidate
            }
        }
        throw SelfUpdateError.binaryPathUnresolvable
    }

    /// Fetch the SHA-256 companion file from a release asset URL (#98).
    /// Companion file format: single-line lowercase hex digest (matching
    /// `shasum -a 256` / `sha256sum` standard output, first column).
    /// Returns the parsed hex string. Throws `checksumUnavailable` on
    /// network failure or file-format issues.
    private static func fetchExpectedSHA256(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("CheICalMCP/\(AppVersion.current) (self-update)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SelfUpdateError.checksumUnavailable("network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SelfUpdateError.checksumUnavailable("HTTP \(code) from \(url.absoluteString)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SelfUpdateError.checksumUnavailable("companion file is not UTF-8 text")
        }
        return try parseSHA256CompanionFile(text)
    }

    /// Parse the SHA-256 companion file content. Accepts:
    /// - bare hex hash on its own line: `abc123...`
    /// - `shasum -a 256` style with filename: `abc123  binary-path`
    /// First valid 64-char hex token wins; trims whitespace; returns lowercase.
    /// Internal so tests can pin the parser without network mocking.
    static func parseSHA256CompanionFile(_ raw: String) throws -> String {
        // Strip BOM + whitespace; split into tokens.
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        for line in normalized.split(separator: "\n") {
            for token in line.split(whereSeparator: { $0.isWhitespace }) {
                let lower = token.lowercased()
                if lower.count == 64 && lower.allSatisfy({ "0123456789abcdef".contains($0) }) {
                    return lower
                }
            }
        }
        throw SelfUpdateError.checksumUnavailable("no 64-char hex SHA-256 token found in companion file content")
    }

    /// Compute SHA-256 of a file on disk. Uses CommonCrypto via a manual
    /// streamed hash so we don't pull CryptoKit into the test target's
    /// transitive surface.
    /// Internal so tests can pin the implementation against known fixtures.
    static func sha256OfFile(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SelfUpdateError.installFailed("file does not exist at \(path) — cannot hash")
        }
        guard let stream = InputStream(fileAtPath: path) else {
            throw SelfUpdateError.installFailed("could not open \(path) for hashing")
        }
        stream.open()
        defer { stream.close() }
        if let openError = stream.streamError {
            throw SelfUpdateError.installFailed("could not open \(path) for hashing: \(openError.localizedDescription)")
        }

        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)

        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { bufPtr -> Int in
                guard let baseAddr = bufPtr.baseAddress else { return 0 }
                return stream.read(baseAddr, maxLength: bufferSize)
            }
            if bytesRead < 0 {
                throw SelfUpdateError.installFailed("error reading \(path) for hashing: \(stream.streamError?.localizedDescription ?? "unknown")")
            }
            if bytesRead == 0 { break }
            _ = buffer.withUnsafeBufferPointer { bufPtr in
                CC_SHA256_Update(&ctx, bufPtr.baseAddress, CC_LONG(bytesRead))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBufferPointer { _ = CC_SHA256_Final($0.baseAddress, &ctx) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Fetch the `tag_name` field from GitHub Releases API.
    private static func fetchLatestTag() async throws -> String {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CheICalMCP/\(AppVersion.current) (self-update)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SelfUpdateError.networkUnavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SelfUpdateError.networkUnavailable("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw SelfUpdateError.networkUnavailable("HTTP \(http.statusCode) from GitHub Releases API")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelfUpdateError.parseError("response is not a JSON object")
        }
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else {
            throw SelfUpdateError.parseError("response missing 'tag_name' field")
        }
        return tag
    }

    /// Download the binary asset to a target-directory-adjacent temp
    /// file. Returns the temp path on success; caller is responsible
    /// for cleanup via `defer`.
    ///
    /// **#49 verify Finding 2**: temp file is staged in the SAME directory
    /// as the eventual target (not `NSTemporaryDirectory()`) so that the
    /// final `rename(2)` is guaranteed same-filesystem and atomic. This
    /// means the upgrade is either complete or unchanged — no window
    /// where the target path doesn't exist.
    private static func downloadBinary(from url: URL, targetPath: String) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("CheICalMCP/\(AppVersion.current) (self-update)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SelfUpdateError.downloadFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SelfUpdateError.downloadFailed("HTTP \(code) from release download URL")
        }
        guard data.count > 0 else {
            throw SelfUpdateError.downloadFailed("downloaded asset is empty (0 bytes)")
        }

        // Stage in target's parent directory so the final rename is atomic.
        let targetURL = URL(fileURLWithPath: targetPath)
        let parent = targetURL.deletingLastPathComponent().path
        let temp = "\(parent)/.\(targetURL.lastPathComponent).update-\(UUID().uuidString)"
        do {
            try data.write(to: URL(fileURLWithPath: temp))
        } catch {
            throw SelfUpdateError.downloadFailed("could not write temp file at \(temp): \(error.localizedDescription)")
        }
        return temp
    }

    /// Install the downloaded binary at `targetPath` using POSIX
    /// `rename(2)` for true atomic replacement.
    ///
    /// **#49 verify Finding 2 (atomic-replace correctness)**: previous
    /// implementation did `rm -f` THEN `mv`, leaving a window where
    /// the target path didn't exist. If `mv` failed mid-install, the
    /// system was bricked. Fixed by:
    /// 1. `chmod 0755` on the staged temp file (in target's parent dir)
    /// 2. POSIX `rename(2)` — atomically replaces the target IF same FS.
    ///    Same FS is guaranteed because Step 1 staged the temp in the
    ///    target's parent directory.
    /// `rename(2)` semantics: target either points at the new file or
    /// the old file at all times — never absent. Stale inode caches
    /// (#62 trap) are irrelevant here because rename swaps the directory
    /// entry, not the inode the running process holds.
    private static func installBinary(from tempPath: String, to targetPath: String) throws {
        let fm = FileManager.default

        // chmod +x on temp file (NSData.write(to:) doesn't preserve exec bit)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
        } catch {
            // Best-effort cleanup of the staged temp on failure.
            try? fm.removeItem(atPath: tempPath)
            throw SelfUpdateError.installFailed("chmod +x on temp file: \(error.localizedDescription)")
        }

        // POSIX rename(2): atomic same-filesystem replacement. Either
        // succeeds (target points at new) or fails leaving target alone.
        let result = rename(tempPath, targetPath)
        if result != 0 {
            let errnoCode = errno
            // Best-effort cleanup of the staged temp on failure.
            try? fm.removeItem(atPath: tempPath)
            let errString = String(cString: strerror(errnoCode))
            throw SelfUpdateError.installFailed(
                "rename(2) \(tempPath) → \(targetPath) failed: \(errString) (errno=\(errnoCode)). " +
                "If permission denied, re-run with sudo or install to a user-writable location first."
            )
        }
    }
}
