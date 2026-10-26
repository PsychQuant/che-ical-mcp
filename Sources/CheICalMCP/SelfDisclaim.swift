import Foundation

/// Why CheICalMCP did not re-exec itself as its own responsible process (#343).
///
/// Closed set — exactly these seven. A new reason means a new case here and a new test in
/// `SelfDisclaimDecisionTests`; do not fold one into an existing case by similarity.
enum SelfDisclaimSkipReason: Equatable, Sendable {
    /// `CHE_ICAL_MCP_DISCLAIMED` is set: this process is the re-exec'd image. Loop guard,
    /// independent of the responsibility lookup.
    case alreadyDisclaimed
    /// `CHE_ICAL_MCP_DISCLAIMED` is set but Claude Code is still the responsible process:
    /// the re-exec did not take effect, or the variable was inherited from an earlier run.
    /// It still must not loop, but unlike `alreadyDisclaimed` it is worth a stderr line,
    /// because the sentinel is an unauthenticated environment variable.
    case disclaimIneffective
    /// `CHE_ICAL_MCP_NO_DISCLAIM` is set: the user wants the host's grant (pre-#343 behavior).
    case optedOut
    /// Already its own responsible process — the Claude Desktop `.mcpb` server under
    /// `disclaimer`, or a binary launched by something that disclaimed it.
    case alreadySelfResponsible
    /// `--version` / `-v` / `--help` / `-h` / `--self-update` never touch EventKit.
    case noTCCAccessNeeded
    /// The responsibility SPI is missing or the lookup failed; run as before.
    case responsibilityUnavailable(String)
    /// The responsible process is an ordinary host (Terminal, VS Code, launchd, a process
    /// with no path): its own grant keeps working and CheICalMCP's own may still be empty,
    /// so swapping one for the other could only break a setup that works today.
    case hostGrantIsUsable
}

enum SelfDisclaimDecision: Equatable, Sendable {
    case reexec
    case skip(SelfDisclaimSkipReason)
}

/// Re-exec in place as our own responsible process, so macOS charges Calendar and
/// Reminders access to CheICalMCP — which carries the purpose strings — instead of to the
/// host. Under the Claude Code daemon the host is either the app that launched the daemon
/// or Claude Code's own binary, and the latter can never be prompted (#343).
///
/// The rule is narrow on purpose. It re-execs when the responsible process is Claude Code
/// (nothing can be prompted there), for `--setup` under any host (a deliberate foreground
/// request for CheICalMCP's own grant), and when the user forces it. Every other host keeps
/// the grant it has: the verify of PR #347 measured a VS Code host that was `fullAccess`
/// while CheICalMCP's own grant was empty, so re-execing everywhere would break it.
enum SelfDisclaim {
    static let disclaimedSentinel = "CHE_ICAL_MCP_DISCLAIMED"
    static let optOutVariable = "CHE_ICAL_MCP_NO_DISCLAIM"
    /// Re-exec under any host, for a user who wants CheICalMCP's own grant everywhere.
    /// `optOutVariable` wins over it.
    static let forceVariable = "CHE_ICAL_MCP_FORCE_DISCLAIM"
    static let flagsWithoutTCCAccess: Set<String> = ["--version", "-v", "--help", "-h", "--self-update"]

    static func decide(
        arguments: [String],
        environment: [String: String],
        responsible: ResponsibleProcessResult
    ) -> SelfDisclaimDecision {
        if isSet(environment[disclaimedSentinel]) {
            return .skip(isClaudeCode(responsible) ? .disclaimIneffective : .alreadyDisclaimed)
        }
        if arguments.dropFirst().contains(where: flagsWithoutTCCAccess.contains) {
            return .skip(.noTCCAccessNeeded)
        }
        if isSet(environment[optOutVariable]) { return .skip(.optedOut) }
        switch responsible {
        case .unavailable(let reason):
            return .skip(.responsibilityUnavailable(reason))
        case .resolved(let process) where process.isSelf:
            return .skip(.alreadySelfResponsible)
        case .resolved(let process):
            if case .claudeCode = process.kind { return .reexec }
            if arguments.dropFirst().contains("--setup") { return .reexec }
            if isSet(environment[forceVariable]) { return .reexec }
            return .skip(.hostGrantIsUsable)
        }
    }

    private static func isClaudeCode(_ responsible: ResponsibleProcessResult) -> Bool {
        guard case .resolved(let process) = responsible, case .claudeCode = process.kind else { return false }
        return true
    }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32

    /// Replace this process image with itself, disclaimed, keeping pid, argv and every
    /// open fd (the MCP stdio pipes included). Does not return on success; on failure it
    /// returns the reason and the caller carries on under the host's attribution.
    ///
    /// `responsibility_spawnattrs_setdisclaim` is private libSystem API — the same call
    /// Claude Desktop's `disclaimer` shim makes — so it is looked up with `dlsym`.
    static func reexecAsOwnResponsibleProcess(arguments: [String]) -> String {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return "responsibility_spawnattrs_setdisclaim not found in this macOS"
        }
        guard let executable = LiveResponsibleProcessSource.executablePath(of: getpid()) else {
            return "could not resolve this binary's path"
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return "posix_spawnattr_init failed" }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0 else {
            return "posix_spawnattr_setflags(SETEXEC) failed"
        }
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)
        guard setDisclaim(&attributes, 1) == 0 else { return "responsibility_spawnattrs_setdisclaim failed" }

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        setenv(disclaimedSentinel, "1", 1)
        let status = posix_spawn(nil, executable, nil, &attributes, argv, environ)
        unsetenv(disclaimedSentinel)
        return "posix_spawn(SETEXEC) failed: \(String(cString: strerror(status)))"
    }

    /// Same convention as `CHE_ICAL_MCP_NO_BANNER`: exported-but-empty counts as unset.
    private static func isSet(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }
}
