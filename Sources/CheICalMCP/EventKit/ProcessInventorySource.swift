import Foundation

/// Test seam for enumerating CheICalMCP processes currently running on this host.
///
/// Why this exists (#122): plugin updates replace the binary on disk but cannot recycle
/// long-lived MCP server processes already running for other Claude Code / Desktop
/// sessions. Those stale processes hold cached EventKit auth state from older code; the
/// fresh fix is in v1.9.0 but the stale processes never picked it up. The drift detector
/// surfaces these PIDs so the operator can `pkill` and restart their host. Per
/// CLAUDE.md "Test Seam Convention": narrow `<Domain>Source` protocol, Live impl
/// default-wired, fake injected in tests.
protocol ProcessInventorySource: Sendable {
    /// Enumerate CheICalMCP-name processes running on this host. Cheap (~20–30 ms via
    /// `ps -A` + filter). Never throws — failure returns an empty list plus a skip reason
    /// so the caller can surface it without blocking startup.
    func enumerateCheICalMCPProcesses() -> ProcessInventoryResult
}

/// A single running CheICalMCP process the inventory found.
struct RunningProcess: Sendable, Equatable {
    let pid: Int32
    /// Executable path (`ps -o comm`) — used to distinguish `~/bin/CheICalMCP` from
    /// the Claude Desktop `.mcpb` install path. Both may legitimately co-exist.
    let executablePath: String
    /// Start time (`ps -o lstart`). Compared against disk binary mtime to decide
    /// whether the process is stale.
    let startedAt: Date
}

/// Either the running-process list, or a skip reason.
struct ProcessInventoryResult: Sendable, Equatable {
    let processes: [RunningProcess]
    let failureReason: String?

    static let empty = ProcessInventoryResult(processes: [], failureReason: nil)
}

/// Production implementation that shells out to `/bin/ps`.
///
/// Why subprocess and not `sysctl` / `libproc`: `ps` is universally available, output is
/// stable across macOS versions, and filtering by command-name substring is trivial.
/// `libproc` requires `proc_pidinfo` with privilege checks and per-PID iteration that
/// adds complexity for marginal latency wins.
struct LiveProcessInventorySource: ProcessInventorySource {
    let psPath: String
    let processNameSubstring: String

    init(
        psPath: String = "/bin/ps",
        processNameSubstring: String = "CheICalMCP"
    ) {
        self.psPath = psPath
        self.processNameSubstring = processNameSubstring
    }

    func enumerateCheICalMCPProcesses() -> ProcessInventoryResult {
        guard FileManager.default.isExecutableFile(atPath: psPath) else {
            return ProcessInventoryResult(processes: [], failureReason: "ps not at \(psPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: psPath)
        // -A all users, -o columns: pid lstart comm. `comm` is the executable path
        // (truncated by macOS to argv[0] basename in some paths; for our case the
        // command line is always the binary so we get the path back).
        process.arguments = ["-A", "-o", "pid=,lstart=,comm="]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ProcessInventoryResult(
                processes: [],
                failureReason: "ps spawn failed: \(error.localizedDescription)"
            )
        }

        // Read pipes BEFORE waitUntilExit: `ps -A` output is large (one line per process
        // on the host, often >64KB), and the OS pipe buffer is ~64KB. If we wait for the
        // child first, it blocks on stdout write once the buffer fills, and waitUntilExit
        // deadlocks. readDataToEndOfFile reads until EOF (child closes its stdout on
        // exit), so the child can drain naturally as we read.
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errOutput = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no stderr)"
            return ProcessInventoryResult(
                processes: [],
                failureReason: "ps exit \(process.terminationStatus): \(errOutput)"
            )
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            return ProcessInventoryResult(processes: [], failureReason: "ps output not UTF-8")
        }

        let formatter = LiveProcessInventorySource.lstartFormatter
        let processes = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { ProcessInventoryParser.parseRow(String($0), nameSubstring: processNameSubstring, lstartFormatter: formatter) }

        return ProcessInventoryResult(processes: processes, failureReason: nil)
    }

    /// `lstart` format on macOS is e.g. `Mon May 11 22:36:52 2026` (POSIX C locale).
    /// We pin a formatter with that locale so we don't pick up the user's regional
    /// override. Timezone is explicitly pinned to `TimeZone.current` (verify finding
    /// F8): without an explicit pin, the formatter falls back to the system default
    /// which is normally `TimeZone.current` but can be affected by mid-process
    /// time-zone changes (e.g. DST transitions); we want the comparison against
    /// `attrs[.modificationDate]` (which is wall-clock `Date`) to be on the same
    /// reference frame as the wall-clock `ps lstart` output that produced it.
    static let lstartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
}

/// Pulled out as a free function so tests can exercise row parsing without spawning ps.
enum ProcessInventoryParser {
    static func parseRow(
        _ row: String,
        nameSubstring: String,
        lstartFormatter: DateFormatter
    ) -> RunningProcess? {
        // ps -o pid=,lstart=,comm= produces: "  PID Day Mon DD HH:MM:SS YYYY  /path/to/comm"
        // We want PID (1 field), lstart (5 fields), comm (rest joined by spaces).
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 7 else { return nil }

        guard let pid = Int32(parts[0]) else { return nil }
        // lstart occupies indices 1...5 (5 tokens)
        let lstartString = parts[1...5].joined(separator: " ")
        guard let startedAt = lstartFormatter.date(from: lstartString) else { return nil }
        // Remainder is the command (preserve internal spaces)
        let commPath = parts[6...].joined(separator: " ")

        // Defensive: an empty/whitespace-only commPath would slip past the
        // substring test and produce a `RunningProcess` with no executable path
        // (verify finding F6). The token count is already `>= 7` but pathological
        // ps rows (e.g. zombie / kernel-thread with stripped comm) can yield 6
        // valid lstart tokens plus an empty 7th.
        guard !commPath.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard commPath.contains(nameSubstring) else { return nil }

        return RunningProcess(pid: pid, executablePath: commPath, startedAt: startedAt)
    }
}
