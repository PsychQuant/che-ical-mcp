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
            guard columns.count == 3,
                  let pid = Int32(columns[0]),
                  let ppid = Int32(columns[1])
            else { continue }
            table[pid] = ProcessEntry(ppid: ppid, command: String(columns[2]))
        }
        return table
    }

    /// Walk from `startPid` toward launchd (pid 1). Termination is guaranteed by three
    /// guards: a seen-set (kills cycles), a hop cap (kills oversized/corrupt chains), and
    /// the unknown-pid stop (a pid missing from the table renders as `(unknown)` and ends
    /// the walk — its ppid is unknowable).
    static func walk(
        table: [Int32: ProcessEntry],
        from startPid: Int32,
        maxHops: Int = 10
    ) -> [ChainHop] {
        guard startPid > 0 else { return [] }
        var hops: [ChainHop] = []
        var seen: Set<Int32> = []
        var pid = startPid
        while hops.count < maxHops, pid > 0, !seen.contains(pid) {
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
        process.arguments = ["-A", "-o", "pid=,ppid=,comm="]

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
            return ParentChainResult(hops: [], failureReason: "ps exited with status \(result.exitStatus)")
        }

        let output = String(data: result.stdoutData, encoding: .utf8) ?? ""
        let table = ParentChainWalker.parseProcessTable(output)
        return ParentChainResult(
            hops: ParentChainWalker.walk(table: table, from: startPid),
            failureReason: nil
        )
    }
}
