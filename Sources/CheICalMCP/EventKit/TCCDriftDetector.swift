import Foundation

/// Detects TCC + process state drift relative to the binary currently starting up and
/// formats a stderr banner with version + actionable signals.
///
/// Lifecycle (per #122 plan):
///   1. Called from `main.swift` once at startup, before the MCP server loop starts.
///   2. Reads TCC.db rows and the host process list through narrow protocol seams.
///   3. Returns a `DriftReport` (pure data, no IO) that callers convert to a stderr
///      string via `formatBanner(...)`.
///
/// Non-goals: it does NOT auto-`tccutil reset`, auto-`pkill`, or change MCP behavior on
/// drift. It is strictly advisory. User explicitly rejected auto-actions in design
/// discussion (audit trail in issue #122 strategy lock comment).
struct TCCDriftDetector {
    let tcc: TCCDatabaseSource
    let processes: ProcessInventorySource
    /// Resolved absolute path of the currently running binary (typically `argv[0]`
    /// resolved through `realpath`).
    let runningBinaryPath: String
    /// On-disk mtime of the running binary, used as the cutoff for "stale" processes.
    /// Anything started before this clearly cannot be running the current code.
    let diskBinaryMtime: Date?
    /// Maximum stale process PIDs to list verbatim in the banner; the rest are
    /// summarized as a count.
    let stalePIDListLimit: Int

    init(
        tcc: TCCDatabaseSource,
        processes: ProcessInventorySource,
        runningBinaryPath: String,
        diskBinaryMtime: Date? = nil,
        stalePIDListLimit: Int = 5
    ) {
        self.tcc = tcc
        self.processes = processes
        self.runningBinaryPath = runningBinaryPath
        self.diskBinaryMtime = diskBinaryMtime
        self.stalePIDListLimit = stalePIDListLimit
    }

    // MARK: - Detect

    func detect() -> DriftReport {
        var signals: [DriftSignal] = []
        var skipReasons: [String] = []

        // --- TCC path mismatch signal ---
        let tccResult = tcc.readCheICalMCPEntries()
        if let reason = tccResult.failureReason {
            skipReasons.append("TCC check skipped: \(reason)")
        } else if !tccResult.entries.isEmpty {
            // Group entries by service so we can warn per-service. An entry is "matching"
            // when its `client` either equals the runtime path or points at a bundle ID
            // (anything without a leading "/"). Path-style entries that do NOT match the
            // runtime path produce a mismatch signal.
            let pathEntries = tccResult.entries.filter { $0.client.hasPrefix("/") }
            let nonMatching = pathEntries.filter { $0.client != runningBinaryPath }
            let mismatchedByService = Dictionary(grouping: nonMatching, by: { $0.service })
            let runtimeHasMatch = pathEntries.contains { $0.client == runningBinaryPath }

            if !runtimeHasMatch {
                for (service, rows) in mismatchedByService.sorted(by: { $0.key < $1.key }) {
                    // Surface the most recent mismatched entry per service.
                    if let recent = rows.max(by: { $0.lastModifiedUnix < $1.lastModifiedUnix }) {
                        signals.append(.tccPathMismatch(
                            service: service,
                            runningBinaryPath: runningBinaryPath,
                            recordedClient: recent.client
                        ))
                    }
                }
            }
        }

        // --- Stale process signal ---
        let processesResult = processes.enumerateCheICalMCPProcesses()
        if let reason = processesResult.failureReason {
            skipReasons.append("process check skipped: \(reason)")
        } else if let cutoff = diskBinaryMtime {
            // A process is "stale" iff it started before the current on-disk binary
            // was written AND its PID is not our own (we can't be stale relative to
            // ourselves). PID 0 sentinel means "skip the self-exclusion check".
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let stale = processesResult.processes.filter {
                $0.pid != ownPID && $0.startedAt < cutoff
            }

            if !stale.isEmpty {
                let sorted = stale.sorted { $0.startedAt < $1.startedAt }
                signals.append(.staleProcesses(
                    count: sorted.count,
                    oldestStartedAt: sorted.first?.startedAt ?? cutoff,
                    samplePIDs: Array(sorted.prefix(stalePIDListLimit).map { $0.pid })
                ))
            }
        } else {
            skipReasons.append("process check skipped: disk binary mtime unavailable")
        }

        return DriftReport(signals: signals, skipReasons: skipReasons)
    }

    // MARK: - Format banner

    /// Render the banner that the caller writes to stderr. Pure — no IO.
    ///
    /// Shape:
    /// ```
    /// [banner] che-ical-mcp <version> — <ok|drift detected (N signals)> — PID <pid>
    /// [banner] binary: <runningBinaryPath>
    /// [drift] <signal 1>
    /// [drift]   → <actionable command 1>
    /// [drift] <signal 2>
    /// [drift]   → <actionable command 2>
    /// [banner] check skipped: <skip reason>     (per skip reason)
    /// ```
    static func formatBanner(
        report: DriftReport,
        version: String,
        runningBinaryPath: String,
        pid: Int32,
        bundleID: String
    ) -> String {
        var lines: [String] = []

        let status: String
        if report.signals.isEmpty {
            status = "TCC OK, no stale processes"
        } else {
            let count = report.signals.count
            let plural = count == 1 ? "" : "s"
            status = "drift detected (\(count) signal\(plural))"
        }
        lines.append("[banner] che-ical-mcp \(version) — \(status) — PID \(pid)")
        lines.append("[banner] binary: \(runningBinaryPath)")

        for signal in report.signals {
            switch signal {
            case .tccPathMismatch(let service, let runningPath, let recordedClient):
                let serviceLabel = humanReadableService(service)
                lines.append("[drift] TCC.db \(serviceLabel) entry path mismatch:")
                lines.append("[drift]   this binary: \(runningPath)")
                lines.append("[drift]   TCC entry:   \(recordedClient)")
                lines.append("[drift]   → tccutil reset \(serviceLabel) \(bundleID) && \"\(runningPath)\" --setup")

            case .staleProcesses(let count, let oldestStartedAt, let samplePIDs):
                let mtimeStr = ISO8601DateFormatter().string(from: oldestStartedAt)
                let pidList = samplePIDs.map(String.init).joined(separator: ", ")
                let suffix = count > samplePIDs.count ? " (+ \(count - samplePIDs.count) more)" : ""
                lines.append("[drift] \(count) stale CheICalMCP process\(count == 1 ? "" : "es") running")
                lines.append("[drift]   oldest started: \(mtimeStr)")
                lines.append("[drift]   sample PIDs: \(pidList)\(suffix)")
                lines.append("[drift]   → pkill -f \"\(runningBinaryPath)\" && fully restart your Claude Code / Desktop host")
            }
        }

        for reason in report.skipReasons {
            lines.append("[banner] \(reason)")
        }

        // Trailing newline so stderr-tailing tools don't smush the next log line.
        return lines.joined(separator: "\n") + "\n"
    }

    /// Translate `kTCCServiceCalendar` → `Calendar` for the `tccutil reset` actionable
    /// suggestion. Anything we don't recognize falls back to the raw service code so the
    /// operator still has something to type.
    private static func humanReadableService(_ raw: String) -> String {
        switch raw {
        case "kTCCServiceCalendar":  return "Calendar"
        case "kTCCServiceReminders": return "Reminders"
        default:                     return raw
        }
    }
}

// MARK: - Pure value types

struct DriftReport: Sendable, Equatable {
    let signals: [DriftSignal]
    let skipReasons: [String]
}

enum DriftSignal: Sendable, Equatable {
    /// TCC.db has an entry for this bundle/binary, but its `client` path doesn't match
    /// the binary that's currently starting. macOS TCC binds permission to the recorded
    /// path; the runtime binary will get `.notDetermined` for permission checks.
    case tccPathMismatch(service: String, runningBinaryPath: String, recordedClient: String)

    /// One or more CheICalMCP processes are running with a start time earlier than the
    /// on-disk binary mtime. They cannot be running the current code; their cached auth
    /// state may differ from what TCC currently grants.
    case staleProcesses(count: Int, oldestStartedAt: Date, samplePIDs: [Int32])
}
