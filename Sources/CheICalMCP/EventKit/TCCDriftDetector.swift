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

        // --- TCC path mismatch signal (per-service, per #122 verify B2) ---
        //
        // Each service (Calendar / Reminders / ...) is checked independently. If the
        // running binary path doesn't appear in *that* service's TCC entries, we emit
        // a mismatch signal for *that* service — regardless of whether another service
        // happens to be granted against the runtime path. Without per-service
        // granularity, a Calendar-mismatch could be silently suppressed by a
        // Reminders-match (verify finding B2). Bundle-ID-only entries (e.g.
        // `com.checheng.CheICalMCP`) bypass the path comparison entirely because TCC
        // resolves bundle IDs at request time — they cannot mismatch a CLI binary's
        // resolved path. They also can't constitute a runtime match for a path-style
        // mismatch question, so we skip them entirely here.
        let tccResult = tcc.readCheICalMCPEntries()
        if let reason = tccResult.failureReason {
            skipReasons.append("TCC check skipped: \(reason)")
        } else if !tccResult.entries.isEmpty {
            let pathEntriesByService = Dictionary(
                grouping: tccResult.entries.filter { $0.client.hasPrefix("/") },
                by: { $0.service }
            )
            for (service, rows) in pathEntriesByService.sorted(by: { $0.key < $1.key }) {
                let hasMatchForService = rows.contains { $0.client == runningBinaryPath }
                if hasMatchForService { continue }
                // Surface the most recent mismatched entry for this service.
                if let recent = rows.max(by: { $0.lastModifiedUnix < $1.lastModifiedUnix }) {
                    signals.append(.tccPathMismatch(
                        service: service,
                        runningBinaryPath: runningBinaryPath,
                        recordedClient: recent.client
                    ))
                }
            }
        }

        // --- Stale process signal ---
        let processesResult = processes.enumerateCheICalMCPProcesses()
        if let reason = processesResult.failureReason {
            skipReasons.append("process check skipped: \(reason)")
        } else if let cutoff = diskBinaryMtime {
            // A process is "stale" iff it started before the current on-disk binary
            // was written AND its PID is not our own.
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
        // CWE-117 / stderr-injection defense (verify finding B1, three-reviewer
        // consensus): every interpolated value reaching stderr passes through
        // `EventKitErrorSanitizer.escapeForStderr` so control chars in untrusted
        // sources (argv[0], TCC.db `client`, sqlite3/ps stderr propagated through
        // skipReasons) cannot forge banner lines or hijack the operator's terminal.
        // `bundleID`, `version`, and numeric values are author-controlled — they
        // would not normally carry control chars, but we escape consistently to
        // make the "all stderr writes go through the sanitizer" rule mechanical.
        let safePath = EventKitErrorSanitizer.escapeForStderr(runningBinaryPath)
        let safeBundle = EventKitErrorSanitizer.escapeForStderr(bundleID)
        let safeVersion = EventKitErrorSanitizer.escapeForStderr(version)

        var lines: [String] = []

        let status: String
        if report.signals.isEmpty {
            status = "TCC OK, no stale processes"
        } else {
            let count = report.signals.count
            let plural = count == 1 ? "" : "s"
            status = "drift detected (\(count) signal\(plural))"
        }
        lines.append("[banner] che-ical-mcp \(safeVersion) — \(status) — PID \(pid)")
        lines.append("[banner] binary: \(safePath)")

        for signal in report.signals {
            switch signal {
            case .tccPathMismatch(let service, let runningPath, let recordedClient):
                let safeService = EventKitErrorSanitizer.escapeForStderr(service)
                let safeRecorded = EventKitErrorSanitizer.escapeForStderr(recordedClient)
                let serviceLabel = humanReadableService(service)
                // Display label (sanitized — `serviceLabel` from a known whitelist is
                // already safe, but raw fallback service codes are user-influenced via
                // TCC.db).
                let safeLabel = EventKitErrorSanitizer.escapeForStderr(serviceLabel)
                lines.append("[drift] TCC.db \(safeLabel) entry path mismatch:")
                lines.append("[drift]   this binary: \(safePath)")
                lines.append("[drift]   TCC entry:   \(safeRecorded)")
                if let tccutilName = tccutilShortName(forService: service) {
                    // Whitelist hit — emit the copy-pasteable command. Path is single-quote
                    // escaped to survive any shell-special chars (`"`, `$`, `` ` ``, `\`,
                    // newline, etc.) per B3 finding. Bundle ID is author-controlled; we
                    // still escape it but it shouldn't need shell-quoting.
                    let quoted = shellSingleQuote(runningPath)
                    lines.append("[drift]   → tccutil reset \(tccutilName) \(safeBundle) && \(quoted) --setup")
                } else {
                    // Unknown service: don't emit a copy-pasteable command (avoid
                    // `tccutil: bad service name` for the operator and avoid being a
                    // social-engineering vector via TCC.db `service`-column poisoning,
                    // per verify findings B3 / DA F3).
                    lines.append("[drift]   → (unrecognized TCC service '\(safeService)' — manual remediation required: System Settings → Privacy & Security)")
                }

            case .staleProcesses(let count, let oldestStartedAt, let samplePIDs):
                let mtimeStr = TCCDriftDetector.iso8601Formatter.string(from: oldestStartedAt)
                let pidList = samplePIDs.map(String.init).joined(separator: ", ")
                let suffix = count > samplePIDs.count ? " (+ \(count - samplePIDs.count) more)" : ""
                lines.append("[drift] \(count) stale CheICalMCP process\(count == 1 ? "" : "es") running")
                lines.append("[drift]   oldest started: \(mtimeStr)")
                lines.append("[drift]   sample PIDs: \(pidList)\(suffix)")
                let quoted = shellSingleQuote(runningBinaryPath)
                lines.append("[drift]   → pkill -f \(quoted) && fully restart your Claude Code / Desktop host")
            }
        }

        for reason in report.skipReasons {
            // skipReason embeds sqlite3 / ps stderr verbatim plus Foundation
            // `localizedDescription` — exactly the channel `escapeForStderr` was
            // built to defend (verify finding B1 / Codex H1).
            let safeReason = EventKitErrorSanitizer.escapeForStderr(reason)
            lines.append("[banner] \(safeReason)")
        }

        // Trailing newline so stderr-tailing tools don't smush the next log line.
        return lines.joined(separator: "\n") + "\n"
    }

    /// Display label for a service (used in banner text). Falls back to the raw service
    /// code when unknown so the operator still sees what TCC.db actually recorded —
    /// but for copy-pasteable `tccutil` commands we use `tccutilShortName` which returns
    /// nil for unknown services so we don't emit a bad command.
    private static func humanReadableService(_ raw: String) -> String {
        switch raw {
        case "kTCCServiceCalendar":  return "Calendar"
        case "kTCCServiceReminders": return "Reminders"
        default:                     return raw
        }
    }

    /// Strict whitelist for `tccutil reset` — returns the short service name only when
    /// it is one of the names `tccutil` actually accepts. Unknown services return nil
    /// so the caller drops the actionable command line. Prevents both the
    /// `tccutil: bad service name` UX bug (DA F3) and the TCC.db `service`-column
    /// poisoning vector (security M2 / DA C2).
    private static func tccutilShortName(forService raw: String) -> String? {
        switch raw {
        case "kTCCServiceCalendar":  return "Calendar"
        case "kTCCServiceReminders": return "Reminders"
        default:                     return nil
        }
    }

    /// POSIX shell single-quote escape. Wraps the input in `'…'` and replaces every
    /// internal `'` with `'\''` (close, escaped-quote, open). The result is safe to
    /// paste inside a shell command line without further escaping (`"`, `$`, `` ` ``,
    /// `\`, newline, semicolon, etc. are all literal inside single quotes).
    ///
    /// Verify finding B3 (logic L3 + security M2 + DA F4): the prior `"\(path)"`
    /// pattern broke on paths containing `"`, `\`, `$`, `` ` ``. Single-quote escaping
    /// is the standard POSIX-shell-safe quoting and works for all printable bytes;
    /// the only special case is `'` itself which we splice with `'\''`.
    static func shellSingleQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Process-wide cached ISO-8601 formatter for banner timestamps (verify finding
    /// F9). Banner emits once per startup so cost is negligible, but the pattern is
    /// consistent with `LiveProcessInventorySource.lstartFormatter` static caching.
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
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
