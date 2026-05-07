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
// **Why atomic replace via rm -f + mv**: matches the #62 upgrade-trap
// fix — copying over an existing inode while old MCP processes still
// hold it causes macOS 26 kernel to kill the new binary with a stale
// code-signature cache (`load code signature error 2 / SIGKILL`).
// `rm -f` first guarantees a fresh inode for the new binary; `mv`
// (rename(2)) is atomic on the same filesystem.

enum SelfUpdate {

    /// Errors surfaced from `--self-update` invocation. Conform to
    /// `LocalizedError` so the printed message is user-friendly.
    enum SelfUpdateError: LocalizedError, TrustedErrorMessage {
        case networkUnavailable(String)
        case parseError(String)
        case downloadFailed(String)
        case installFailed(String)
        case binaryPathUnresolvable

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
            }
        }
    }

    /// GitHub Releases API URL for the latest tag of this repo.
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
        print("Downloading \(assetName) from \(downloadURL.absoluteString) ...")

        let tempPath = try await downloadBinary(from: downloadURL)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        try installBinary(from: tempPath, to: currentBinaryPath)
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
    private static func resolveCurrentBinaryPath() throws -> String {
        guard let argv0 = CommandLine.arguments.first else {
            throw SelfUpdateError.binaryPathUnresolvable
        }
        if let resolved = realpath(argv0, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // realpath can fail if argv[0] is a bare name relying on PATH —
        // try resolving via `which`-style PATH walk by trusting argv[0]
        // as-is if it contains a slash, else giving up.
        if argv0.contains("/") {
            return argv0
        }
        throw SelfUpdateError.binaryPathUnresolvable
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

    /// Download the binary asset to a temp file. Returns the temp path
    /// on success; caller is responsible for cleanup via `defer`.
    private static func downloadBinary(from url: URL) async throws -> String {
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

        let temp = NSTemporaryDirectory() + "CheICalMCP.update-\(UUID().uuidString)"
        do {
            try data.write(to: URL(fileURLWithPath: temp))
        } catch {
            throw SelfUpdateError.downloadFailed("could not write temp file: \(error.localizedDescription)")
        }
        return temp
    }

    /// Install the downloaded binary at `targetPath`:
    /// 1. `chmod +x` the temp file
    /// 2. `rm -f` the existing target (per #62 upgrade trap fix —
    ///    forces fresh inode so macOS 26 kernel doesn't kill new binary
    ///    with stale code-signature cache from the old inode)
    /// 3. `mv` (rename) the temp file into place atomically
    private static func installBinary(from tempPath: String, to targetPath: String) throws {
        let fm = FileManager.default

        // chmod +x on temp file (NSData.write(to:) doesn't preserve exec bit)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
        } catch {
            throw SelfUpdateError.installFailed("chmod +x on temp file: \(error.localizedDescription)")
        }

        // rm -f the existing target. fm.removeItem throws if file doesn't
        // exist — we want best-effort here, so check first.
        if fm.fileExists(atPath: targetPath) {
            do {
                try fm.removeItem(atPath: targetPath)
            } catch {
                throw SelfUpdateError.installFailed(
                    "could not remove existing binary at \(targetPath): \(error.localizedDescription). " +
                    "If you don't have write permission, re-run with sudo or install to ~/bin first."
                )
            }
        }

        // mv (atomic same-filesystem rename) — safer than copy+delete
        // because it leaves no partially-written file. NSTemporaryDirectory
        // is on the same filesystem as ~/bin in normal user installs;
        // if not, fm.moveItem falls back to copy+delete which is fine.
        do {
            try fm.moveItem(atPath: tempPath, toPath: targetPath)
        } catch {
            throw SelfUpdateError.installFailed("could not move temp to \(targetPath): \(error.localizedDescription)")
        }
    }
}
