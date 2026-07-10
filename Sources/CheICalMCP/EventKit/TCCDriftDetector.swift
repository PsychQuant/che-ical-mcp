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
    /// Self-code-signing checks for the csreq-mismatch signal (#155). Default-wired to
    /// the Security-framework Live impl; a fake is injected in tests.
    let codeSignature: CodeSignatureSource
    /// Resolved absolute path of the currently running binary (typically `argv[0]`
    /// resolved through `realpath`).
    let runningBinaryPath: String
    /// On-disk mtime of the running binary, used as the cutoff for "stale" processes.
    /// Anything started before this clearly cannot be running the current code.
    let diskBinaryMtime: Date?
    /// Maximum stale process PIDs to list verbatim in the banner; the rest are
    /// summarized as a count.
    let stalePIDListLimit: Int
    /// Parent-chain capture for the #175 versioned-host signal. Default-wired to the
    /// `ps`-backed Live impl (#169); a fake is injected in tests.
    let parentChain: ParentChainSource
    /// Whether Calendar is granted in the CURRENT attribution context (#168). Read once
    /// by `main.swift` before construction; gates the #175 versioned-host check so the
    /// extra `ps` spawn only happens when something is actually wrong.
    let calendarAccessGranted: Bool

    /// The path fragment that identifies a Claude Code native-install versioned binary
    /// (`~/.local/share/claude/versions/<version>`). TCC keys the host-side grant to
    /// this rotating path, so every auto-update silently invalidates it (#170).
    static let claudeVersionedPathFragment = "/.local/share/claude/versions/"

    init(
        tcc: TCCDatabaseSource,
        processes: ProcessInventorySource,
        runningBinaryPath: String,
        diskBinaryMtime: Date? = nil,
        stalePIDListLimit: Int = 5,
        codeSignature: CodeSignatureSource = LiveCodeSignatureSource(),
        parentChain: ParentChainSource = LiveParentChainSource(),
        calendarAccessGranted: Bool = true
    ) {
        self.tcc = tcc
        self.processes = processes
        self.codeSignature = codeSignature
        self.runningBinaryPath = runningBinaryPath
        self.diskBinaryMtime = diskBinaryMtime
        self.stalePIDListLimit = stalePIDListLimit
        self.parentChain = parentChain
        self.calendarAccessGranted = calendarAccessGranted
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

            // --- csreq mismatch signal (#155 — the #154 silent-denial class) ---
            //
            // For each service row that pins a csreq, ask the Security framework whether
            // the running binary still satisfies it. A `.mismatch` (errSecCSReqFailed) is
            // the silent-denial class: TCC denies at access time while every status API
            // reports green, so this banner line is the only surface that catches it.
            // `.undecidable` → skip (never cry wolf on an install we can't read). Emitted
            // per-service, most-recent row wins. `hasEntitlement` (read once) annotates
            // whether a re-prompt would also be policy-blocked (the second half of #154).
            let hasEntitlement = codeSignature.runningBinaryHasPersonalInfoEntitlement()
            let csreqByService = Dictionary(
                grouping: tccResult.entries.filter { $0.csreqHex != nil },
                by: { $0.service }
            )
            for (service, rows) in csreqByService.sorted(by: { $0.key < $1.key }) {
                guard let recent = rows.max(by: { $0.lastModifiedUnix < $1.lastModifiedUnix }),
                      let hex = recent.csreqHex,
                      let blob = TCCDriftDetector.dataFromHex(hex) else { continue }
                switch codeSignature.evaluateRunningBinary(againstRequirementBlob: blob) {
                case .mismatch:
                    signals.append(.csreqMismatch(service: service, hasEntitlement: hasEntitlement))
                case .undecidable(let reason):
                    skipReasons.append("csreq check skipped for \(service): \(reason)")
                case .satisfies:
                    break
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

        // --- Versioned-host ungranted signal (#175 / #170) ---
        //
        // Only checked when Calendar is NOT granted in this context: the extra `ps`
        // spawn (500ms-capped) is spent exclusively on the broken path, and granted
        // users see zero added noise. In MCP-server mode the parent chain IS the host
        // chain, and `authorizationStatus` follows that attribution context (#168) —
        // so "chain contains a versioned claude binary + ungranted" pinpoints the
        // #170 rotation as the likely cause.
        if !calendarAccessGranted {
            let chainResult = parentChain.captureChain(from: getppid())
            if let reason = chainResult.failureReason {
                skipReasons.append("versioned-host check skipped: \(reason)")
            } else if let hostHop = chainResult.hops.first(
                where: { $0.command.contains(Self.claudeVersionedPathFragment) }
            ) {
                signals.append(.versionedClaudeHostUngranted(hostPath: hostHop.command))
            }
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
        bundleID: String,
        calendarAccessGranted: Bool = true
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

        // #163: when Calendar access is not granted for THIS binary, surface the exact
        // foreground `--setup` command so the user can grant the dialog that only presents
        // from a foreground app context. Same control-char branching as the drift lines:
        // emit a copy-paste command only when the path is clean, else a safe-display hint.
        if !calendarAccessGranted {
            if pathHasControlChars(runningBinaryPath) {
                lines.append("[banner] Calendar access not granted — binary path has control chars; grant via System Settings → Privacy & Security → Calendar for binary at \(safePath)")
            } else {
                lines.append("[banner] Calendar access not granted — grant via: \(shellSingleQuote(runningBinaryPath)) --setup")
            }
        }

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
                    // Whitelist hit. Two cases:
                    //   (a) path has no control chars → emit a copy-paste-ready POSIX
                    //       command via `shellSingleQuote` (B3). The result is safe on
                    //       both stderr (no newlines/CR can split the banner) and shell
                    //       (single quotes neutralise `"`, `$`, `` ` ``, `\`).
                    //   (b) path has control chars → DO NOT emit a copy-paste command.
                    //       Stderr-safety requires escaping which would invalidate the
                    //       shell quoting (`\` inside `'\''` would double — round-2 R1).
                    //       Surface the path safely via `safePath` (already escaped) and
                    //       a manual-remediation hint instead.
                    if pathHasControlChars(runningPath) {
                        lines.append("[drift]   → (binary path contains control chars; manual remediation required: tccutil reset \(tccutilName) \(safeBundle) for binary at \(safePath))")
                    } else {
                        lines.append("[drift]   → tccutil reset \(tccutilName) \(safeBundle) && \(shellSingleQuote(runningPath)) --setup")
                    }
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
                // Same branching as tccutil case above: emit copy-paste command only
                // when path has no control chars; otherwise emit safe-display hint.
                if pathHasControlChars(runningBinaryPath) {
                    lines.append("[drift]   → (binary path contains control chars; manual remediation: pkill the stale processes for binary at \(safePath), then fully restart your Claude Code / Desktop host)")
                } else {
                    lines.append("[drift]   → pkill -f \(shellSingleQuote(runningBinaryPath)) && fully restart your Claude Code / Desktop host")
                }

            case .csreqMismatch(let service, let hasEntitlement):
                let safeLabel = EventKitErrorSanitizer.escapeForStderr(humanReadableService(service))
                lines.append("[drift] TCC.db \(safeLabel) entry pins a code requirement this binary no longer satisfies")
                lines.append("[drift]   (silent denial — access refused at use time while every status API reports green; #154/#155)")
                if hasEntitlement == false {
                    lines.append("[drift]   this binary also lacks the personal-information entitlement — hardened-runtime re-prompts are policy-blocked")
                }
                // Same control-char / whitelist gating as the tccPathMismatch case: emit a
                // copy-paste command only for a recognized service and a clean path.
                if let tccutilName = tccutilShortName(forService: service) {
                    if pathHasControlChars(runningBinaryPath) {
                        lines.append("[drift]   → (binary path contains control chars; manual remediation: tccutil reset \(tccutilName) \(safeBundle), then re-grant from a Developer-ID / notarized build)")
                    } else {
                        lines.append("[drift]   → tccutil reset \(tccutilName) \(safeBundle) && \(shellSingleQuote(runningBinaryPath)) --setup   (re-grant from a Developer-ID / notarized build, #154)")
                    }
                } else {
                    let safeService = EventKitErrorSanitizer.escapeForStderr(service)
                    lines.append("[drift]   → (unrecognized TCC service '\(safeService)' — manual remediation: System Settings → Privacy & Security)")
                }

            case .versionedClaudeHostUngranted(let hostPath):
                // hostPath comes from `ps` comm (ancestor-controlled) — same CWE-117
                // stderr discipline as every other interpolated banner field.
                let safeHost = EventKitErrorSanitizer.escapeForStderr(hostPath)
                lines.append("[drift] EventKit not granted under a Claude Code versioned host")
                lines.append("[drift]   host binary: \(safeHost)")
                lines.append("[drift]   (this path rotates on every Claude Code update, staling the host-side TCC grant — #170)")
                lines.append("[drift]   → toggle the NEWEST version-number entry ON in System Settings → Privacy & Security → Calendars / Reminders, or trigger any calendar tool call to re-prompt; full checklist: the troubleshoot-tcc skill")
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
    /// `\`, semicolon, etc. are all literal inside single quotes).
    ///
    /// Verify finding B3 (logic L3 + security M2 + DA F4): the prior `"\(path)"`
    /// pattern broke on paths containing `"`, `\`, `$`, `` ` ``. Single-quote escaping
    /// is the standard POSIX-shell-safe quoting and works for all printable bytes;
    /// the only special case is `'` itself which we splice with `'\''`.
    ///
    /// **Pre-condition**: caller MUST verify the input contains no control characters
    /// (LF/CR/etc.) via `pathHasControlChars` before passing here. Single-quoted
    /// strings preserve newlines verbatim, which would split the banner line on stderr
    /// (verify round-2 R1). The caller branches on `pathHasControlChars` and emits
    /// a manual-remediation hint instead of a copy-paste command when control chars
    /// are present.
    static func shellSingleQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Returns true if the input contains any control character: C0 (`\x00..\x1F`),
    /// DEL (`\x7F`), or the C1 band (`\x80..\x9F`). Used to gate the copy-paste
    /// actionable command (verify round-2 R1) — control chars inside single-quoted
    /// shell strings would split the banner line on stderr, regardless of POSIX
    /// shell quoting semantics.
    ///
    /// The C1 band matches `EventKitErrorSanitizer.escapeForStderr`'s control-char
    /// definition (#150 / #152) so the gate and the escaper cannot diverge: a C1
    /// char (e.g. 8-bit CSI `\x9B`) in the running binary's path must NOT slip
    /// unescaped into the `shellSingleQuote` command branch. Printable scalars
    /// resume at `\xA0` (NBSP), so the C1 range is control-only.
    static func pathHasControlChars(_ s: String) -> Bool {
        for scalar in s.unicodeScalars
        where scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
            return true
        }
        return false
    }

    /// Decode a hex string (from SQL `hex(csreq)`, uppercase) into raw bytes for the
    /// Security-framework requirement check (#155). Returns nil for odd-length or
    /// non-hex input so a malformed blob degrades to "no signal", not a crash.
    static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
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

    /// The TCC row for this service pins a code requirement (`csreq`) that the running
    /// binary no longer satisfies (#155 — the #154 silent-denial class). macOS denies at
    /// access time while every status API reports green, so this is the only surface that
    /// catches it. `hasEntitlement` annotates whether the running binary carries the
    /// personal-information entitlement: `false`/`nil` means a hardened-runtime re-prompt
    /// would also be policy-blocked (the second half of the #154 signature).
    case csreqMismatch(service: String, hasEntitlement: Bool?)

    /// The MCP server is starting under a Claude Code **versioned** host binary
    /// (`~/.local/share/claude/versions/<v>`) and EventKit is NOT granted in this
    /// context. TCC keys the host-side grant to that rotating path, so every Claude
    /// Code auto-update silently invalidates it (#170) — this signal turns the
    /// "worked yesterday, broken after an update" mystery into an actionable line
    /// (#175). `hostPath` is the versioned binary observed on the parent chain.
    case versionedClaudeHostUngranted(hostPath: String)
}
