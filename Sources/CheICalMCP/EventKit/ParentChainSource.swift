import Foundation

/// Test seam for capturing the parent process chain shown by `--print-tcc-path` (#169).
///
/// Why this exists: `EKEventStore.authorizationStatus(for:)` reflects the authorization of
/// the current attribution context (the responsible process — Terminal.app, Claude Code's
/// versioned binary, VS Code, …), not an absolute property of this binary (#168). The
/// diagnostic output must therefore show *which* context the query ran under, or users
/// misread the status as universal. Per CLAUDE.md "Test Seam Convention": narrow
/// `<Domain>Source` protocol, Live impl default-wired, fake injected in tests.
protocol ParentChainSource: Sendable {
    /// Capture the chain from `startPid` up toward launchd. Never throws — failure returns
    /// an empty chain plus a reason so the caller can surface it without hiding the rest
    /// of the diagnostic output.
    func captureChain(from startPid: Int32) -> ParentChainResult
}

/// Either the walked chain, or the reason it could not be captured.
struct ParentChainResult: Sendable, Equatable {
    let hops: [ParentChainWalker.ChainHop]
    let failureReason: String?
}

/// Pure parse + walk logic, separated from the `ps` subprocess so the adversarial table
/// shapes (cycle, orphan ppid, oversized chain) are unit-testable without spawning anything.
enum ParentChainWalker {
    /// One row of the `ps -A -o pid=,ppid=,comm=` table.
    struct ProcessEntry: Sendable, Equatable {
        let ppid: Int32
        let command: String
    }

    /// One hop of the walked chain, ready for display.
    struct ChainHop: Sendable, Equatable {
        let pid: Int32
        let command: String
    }

    /// Parse `ps -A -o pid=,ppid=,comm=` output into a pid → entry table. Lines that don't
    /// start with two integer columns are skipped (headers, truncation artifacts). The
    /// command column keeps embedded spaces (`.app` bundle paths).
    static func parseProcessTable(_ psOutput: String) -> [Int32: ProcessEntry] {
        var table: [Int32: ProcessEntry] = [:]
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Split into at most 3 columns: pid, ppid, command-with-possible-spaces.
            let columns = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count >= 2,
                  let pid = Int32(columns[0]),
                  let ppid = Int32(columns[1])
            else { continue }
            // Empty comm (#173): keep the row with a visible placeholder — dropping it
            // would sever the ppid linkage and end the walk one hop early.
            let command = columns.count == 3 ? String(columns[2]) : "(unknown)"
            table[pid] = ProcessEntry(ppid: ppid, command: command)
        }
        return table
    }

    /// Walk from `startPid` toward launchd (pid 1). Termination is guaranteed by three
    /// guards: a seen-set (kills cycles), a hop cap (kills oversized/corrupt chains), and
    /// the unknown-pid stop (a pid missing from the table renders as `(unknown)` and ends
    /// the walk — its ppid is unknowable). Cycle and hop-cap stops append a synthetic
    /// marker hop (#173) — a silently-ended chain reads as complete, which for a
    /// diagnostic that exists to show the real context is misinformation. The marker's
    /// pid is the pid the walk stopped at, so a triager can resume by hand.
    static func walk(
        table: [Int32: ProcessEntry],
        from startPid: Int32,
        maxHops: Int = 15
    ) -> [ChainHop] {
        guard startPid > 0 else { return [] }
        var hops: [ChainHop] = []
        var seen: Set<Int32> = []
        var pid = startPid
        while pid > 0 {
            if seen.contains(pid) {
                hops.append(ChainHop(pid: pid, command: "(cycle detected)"))
                break
            }
            // The terminal sentinel (pid 1, launchd) is exempt from the cap: it ends the
            // walk unconditionally one line below, so admitting it costs at most one
            // entry — while marking an already-rooted chain "truncated" would be the
            // mirror image of the misinformation this marker exists to eliminate
            // (#173 verify LOW-1, DA probe-confirmed).
            if hops.count >= maxHops, pid != 1 {
                hops.append(ChainHop(pid: pid, command: "(chain truncated after \(maxHops) hops)"))
                break
            }
            seen.insert(pid)
            guard let entry = table[pid] else {
                hops.append(ChainHop(pid: pid, command: "(unknown)"))
                break
            }
            hops.append(ChainHop(pid: pid, command: entry.command))
            if pid == 1 { break }  // launchd — chain root reached
            pid = entry.ppid
        }
        return hops
    }
}

/// Display layer for the `--print-tcc-path` execution-context block. Extracted from
/// `main.swift` per the #117 precedent (TCCStatusFormatter) so the output shape —
/// including the context-dependence warning that must survive capture failures — is
/// unit-testable without spawning the binary.
enum ParentChainFormatter {
    static func executionContextSection(
        selfPid: Int32,
        selfPath: String,
        result: ParentChainResult
    ) -> String {
        // Every interpolated field below is ancestor- or framework-controlled (`ps` comm
        // can carry ESC/C0/C1 in a hostile process path) and this string reaches an
        // interactive terminal — route through the same escaper as the EventKit stderr
        // paths (CWE-150/117 discipline, #37/#73/#150).
        let escape = EventKitErrorSanitizer.escapeForStderr
        var lines: [String] = ["Process tree (parent chain — not what TCC checks):"]
        lines.append("  \(selfPid)  \(escape(selfPath))  (this binary)")
        if let reason = result.failureReason {
            lines.append("  (parent chain unavailable: \(escape(reason)))")
        } else {
            for hop in result.hops {
                lines.append("  \(hop.pid)  \(escape(hop.command))")
            }
        }
        lines.append("")
        // #343: TCC checks the responsible process, which the kernel assigns at spawn time
        // and which need not sit on this chain (#173). A daemon-launched worker and a
        // spare-claimed one show the same chain shape with different grants, so the chain
        // is orientation only; the attribution block printed above is the answer. Since
        // this flag is shell-invoked, the chain can never show the Claude Desktop MCP
        // context; route Desktop diagnosis to the sqlite3 query printed earlier.
        lines.append("""
            NOTE: macOS checks the process under "TCC attribution" above, not this chain (#343).
            A host on this chain (Terminal, VS Code, Claude Code)
            supplies the grant only when it is the responsible process.
            The chain shows how this binary was launched.
            For Claude Desktop, this shell-invoked chain cannot show its MCP context —
            inspect the TCC database directly instead (sqlite3 command above).
            """)
        return lines.joined(separator: "\n")
    }
}

/// Production implementation: one `ps -A` snapshot, then an in-memory walk.
///
/// Why subprocess and not `sysctl` / `libproc`: same reasoning as
/// `LiveProcessInventorySource` (#122) — `ps` is universally available, its output is
/// stable across macOS versions, and one `-A` snapshot avoids per-hop process spawns.
/// Timeout via `SubprocessRunner` mirrors the drift detector's 500ms budget (#126).
struct LiveParentChainSource: ParentChainSource {
    let psPath: String
    let timeoutMilliseconds: Int

    init(psPath: String = "/bin/ps", timeoutMilliseconds: Int = 500) {
        self.psPath = psPath
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func captureChain(from startPid: Int32) -> ParentChainResult {
        guard FileManager.default.isExecutableFile(atPath: psPath) else {
            return ParentChainResult(hops: [], failureReason: "ps not at \(psPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: psPath)
        // `-ww` (#173): lift the output-width clamp so long bundle paths are never
        // truncated by ps itself (BSD ps applies the clamp even without a tty in
        // some configurations; the flag is a no-op when already unclamped).
        process.arguments = ["-Aww", "-o", "pid=,ppid=,comm="]

        let result: SubprocessRunResult
        do {
            result = try SubprocessRunner.run(process: process, timeoutMilliseconds: timeoutMilliseconds)
        } catch {
            return ParentChainResult(hops: [], failureReason: "ps spawn failed: \(error.localizedDescription)")
        }
        if result.timedOut {
            return ParentChainResult(hops: [], failureReason: "ps timed out after \(timeoutMilliseconds)ms")
        }
        guard result.exitStatus == 0 else {
            // Attach stderr's first line (#173) — it is the actionable part of a ps
            // failure. Rendering escapes it (ParentChainFormatter), so raw bytes are safe.
            let stderrFirstLine = String(data: result.stderrData, encoding: .utf8)?
                .split(separator: "\n").first.map(String.init) ?? ""
            let suffix = stderrFirstLine.isEmpty ? "" : ": \(stderrFirstLine)"
            return ParentChainResult(hops: [], failureReason: "ps exited with status \(result.exitStatus)\(suffix)")
        }

        // Non-UTF-8 output (#173): report it — a silent empty table would render as a
        // "successful" one-hop chain (mirrors ProcessInventorySource's decode handling).
        guard let output = String(data: result.stdoutData, encoding: .utf8) else {
            return ParentChainResult(hops: [], failureReason: "ps output not UTF-8")
        }
        let table = ParentChainWalker.parseProcessTable(output)
        return ParentChainResult(
            hops: ParentChainWalker.walk(table: table, from: startPid),
            failureReason: nil
        )
    }
}
