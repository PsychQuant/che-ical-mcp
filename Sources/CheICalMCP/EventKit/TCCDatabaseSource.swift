import Foundation

/// Test seam for reading TCC.db entries that reference this binary by name or bundle ID.
///
/// Why this exists (#122): the drift detector compares the runtime binary path against
/// the path TCC has recorded for CheICalMCP's authorization. A mismatch means TCC will
/// reject `EKEventStore.save(...)` even when `EKEventStore.authorizationStatus(for:)`
/// returns `.fullAccess` for a different path. Per CLAUDE.md "Test Seam Convention":
/// narrow `<Domain>Source` protocol, Live impl default-wired, fake injected in tests.
protocol TCCDatabaseSource: Sendable {
    /// Read TCC.db entries whose `client` column matches CheICalMCP by bundle ID or path
    /// substring. Cheap (~10–20 ms via sqlite3 CLI). Never throws — read failure returns
    /// an empty array with `failureReason` populated so the caller can surface it as a
    /// drift-check skip reason rather than an actionable signal.
    func readCheICalMCPEntries() -> TCCQueryResult
}

/// Single row from TCC.db `access` table, projected to the columns drift detection needs.
struct TCCEntry: Sendable, Equatable {
    /// Service code, e.g. `kTCCServiceCalendar` / `kTCCServiceReminders`.
    let service: String
    /// `client` column — usually an absolute binary path, but can also be a bundle ID
    /// for `.app`-bundled tools. CheICalMCP today is a command-line binary so the value
    /// is typically the executable path.
    let client: String
    /// `auth_value` column. Per the schema in `--print-tcc-path`:
    /// 0 = denied, 1 = unknown, 2 = granted, 3 = limited.
    let authValue: Int
    /// `last_modified` column (Unix epoch seconds).
    let lastModifiedUnix: Int64
}

/// Either a list of TCC entries that matched, or the reason a read attempt was skipped.
/// We don't throw because drift detection is advisory — sqlite3 unavailable / TCC.db
/// locked / future schema change must NOT abort MCP server startup. The skip reason is
/// what `TCCDriftDetector` surfaces to operators.
struct TCCQueryResult: Sendable, Equatable {
    let entries: [TCCEntry]
    let failureReason: String?

    static let empty = TCCQueryResult(entries: [], failureReason: nil)
}

/// Production implementation that shells out to `/usr/bin/sqlite3`.
///
/// Why subprocess and not a Swift SQLite3 binding: TCC.db is a user-readable SQLite
/// database whose schema is owned by Apple's privacy subsystem. Linking a Swift binding
/// adds a build dependency and surface for parse bugs against a schema we don't control;
/// shelling out is universal on macOS and isolates failures to a one-shot process that
/// can fail safely (locked db, schema drift, missing file) without affecting the host.
struct LiveTCCDatabaseSource: TCCDatabaseSource {
    /// Path to the user's TCC.db. Defaulted to the canonical location but injectable for
    /// integration tests that point at a synthetic db.
    let databasePath: String
    let sqlite3Path: String

    init(
        databasePath: String = NSString(string: "~/Library/Application Support/com.apple.TCC/TCC.db").expandingTildeInPath,
        sqlite3Path: String = "/usr/bin/sqlite3"
    ) {
        self.databasePath = databasePath
        self.sqlite3Path = sqlite3Path
    }

    func readCheICalMCPEntries() -> TCCQueryResult {
        // Probe in order: sqlite3 missing → db missing → run query → parse output.
        // Each early-exit path returns a skip reason instead of throwing.
        guard FileManager.default.isExecutableFile(atPath: sqlite3Path) else {
            return TCCQueryResult(entries: [], failureReason: "sqlite3 not at \(sqlite3Path)")
        }
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return TCCQueryResult(entries: [], failureReason: "TCC.db not at \(databasePath)")
        }

        // Restrict the SQL to CheICalMCP-related rows so we don't bring back the whole
        // table. `client LIKE '%CheICalMCP%'` catches both `/path/.../CheICalMCP` binary
        // paths and `com.checheng.CheICalMCP` bundle IDs.
        let sql = """
        SELECT service, client, auth_value, last_modified
        FROM access
        WHERE client LIKE '%CheICalMCP%';
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite3Path)
        process.arguments = ["-readonly", "-separator", "|", databasePath, sql]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return TCCQueryResult(entries: [], failureReason: "sqlite3 spawn failed: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no stderr)"
            return TCCQueryResult(entries: [], failureReason: "sqlite3 exit \(process.terminationStatus): \(errOutput)")
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else {
            return TCCQueryResult(entries: [], failureReason: "sqlite3 output not UTF-8")
        }

        let entries = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseRow(String($0)) }

        return TCCQueryResult(entries: entries, failureReason: nil)
    }

    /// Parse one pipe-separated row. Returns nil for malformed rows — better to drop one
    /// row than fail the entire query when the schema introduces an unexpected column.
    private func parseRow(_ row: String) -> TCCEntry? {
        let parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        guard let authValue = Int(parts[2]) else { return nil }
        guard let lastModified = Int64(parts[3]) else { return nil }
        return TCCEntry(
            service: parts[0],
            client: parts[1],
            authValue: authValue,
            lastModifiedUnix: lastModified
        )
    }
}
