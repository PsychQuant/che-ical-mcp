import EventKit
import Foundation

/// Why CheICalMCP did not re-exec itself as its own responsible process (#343).
///
/// Closed set — exactly these eight. A new reason means a new case here and a new test in
/// `SelfDisclaimDecisionTests`; do not fold one into an existing case by similarity.
enum SelfDisclaimSkipReason: Equatable, Sendable {
    /// `CHE_ICAL_MCP_DISCLAIMED` is set and this process is its own responsible process (or
    /// the lookup failed, so nothing contradicts the sentinel): the re-exec'd image. Loop
    /// guard, independent of the responsibility lookup.
    case alreadyDisclaimed
    /// `CHE_ICAL_MCP_DISCLAIMED` is set but another process is still responsible: the re-exec
    /// did not take effect, or the variable was inherited from an earlier run. It still must
    /// not loop, but unlike `alreadyDisclaimed` it is worth a stderr line, because the
    /// sentinel is an unauthenticated environment variable.
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
    /// The host's context already has full Calendar and Reminders access. Any host —
    /// Claude Code's version-number grant included — keeps a grant that works, rather than
    /// trading it for CheICalMCP's own, which may still be empty.
    case hostGrantIsUsable
    /// A policy (MDM or Screen Time) restricts the host's access to Calendar, Reminders, or
    /// both. Re-executing would move this server onto CheICalMCP's own grant, which that
    /// policy does not name, so the host keeps its attribution (#367).
    /// `CHE_ICAL_MCP_FORCE_DISCLAIM` yields to it.
    case hostRestrictedByPolicy
}

/// Why CheICalMCP re-execs itself as its own responsible process (#343).
///
/// Closed set — exactly these three; same rule as `SelfDisclaimSkipReason`.
enum SelfDisclaimReexecReason: Equatable, Sendable {
    /// The host's context lacks full access to Calendar, Reminders, or both, so its grant
    /// cannot serve this server; macOS checks CheICalMCP's own grant instead.
    case hostGrantUnusable
    /// `--setup` is the foreground action that creates CheICalMCP's own grant.
    case setup
    /// `CHE_ICAL_MCP_FORCE_DISCLAIM` is set. Printed on stderr, because it is an
    /// environment variable a parent process can set without the user noticing.
    case forced
}

enum SelfDisclaimDecision: Equatable, Sendable {
    case reexec(SelfDisclaimReexecReason)
    case skip(SelfDisclaimSkipReason)
}

/// The host context's Calendar and Reminders authorization, read once for the decision.
struct HostAuthorization: Equatable {
    let calendar: EKAuthorizationStatus
    let reminders: EKAuthorizationStatus
}

/// Re-exec in place as our own responsible process, so macOS charges Calendar and
/// Reminders access to CheICalMCP — which carries the purpose strings — instead of to the
/// host. Under the Claude Code daemon the host is either the app that launched the daemon
/// or Claude Code's own binary, and the latter can never be prompted (#343).
///
/// The rule depends on the host's authorization status and is the same for every host
/// (decision after verify round 2): a host whose context already has full Calendar and
/// Reminders access keeps that grant, and any other host re-execs, so the grant `--setup`
/// creates is the one that serves it. CheICalMCP's own grant can be empty while a host's
/// works (2026-10-23: `notDetermined` for both services under disclaim, `fullAccess` under
/// VS Code), which is why a host grant that works for both services is never traded for it.
/// One that works for a single service is (`hostGrantIsUsable`), as is a denied host: those
/// re-exec onto CheICalMCP's grant like any host without full access. A host that a policy
/// restricts for either service is the exception and keeps its attribution (#367). `--setup`
/// re-execs under any host, `CHE_ICAL_MCP_FORCE_DISCLAIM` under any host but a restricted one,
/// and `CHE_ICAL_MCP_NO_DISCLAIM` wins over both.
enum SelfDisclaim {
    static let disclaimedSentinel = "CHE_ICAL_MCP_DISCLAIMED"
    static let optOutVariable = "CHE_ICAL_MCP_NO_DISCLAIM"
    /// Re-exec under any host, for a user who wants CheICalMCP's own grant everywhere.
    /// `optOutVariable` wins over it.
    static let forceVariable = "CHE_ICAL_MCP_FORCE_DISCLAIM"
    static let flagsWithoutTCCAccess: Set<String> = ["--version", "-v", "--help", "-h", "--self-update"]

    /// The criterion the user chose after verify round 2: the host's grant is kept only when
    /// BOTH services have full access. Any other combination re-execs — including a host with one
    /// working service, whose working service then moves to CheICalMCP's grant as well, and a
    /// host the user denied. A restricted host is checked first (`hostIsRestricted`).
    static func hostGrantIsUsable(calendar: EKAuthorizationStatus, reminders: EKAuthorizationStatus) -> Bool {
        calendar == .fullAccess && reminders == .fullAccess
    }

    /// The decision after verify round 3b (#367): a policy restriction on either service keeps
    /// the host's attribution, whatever the other service's status is.
    static func hostIsRestricted(calendar: EKAuthorizationStatus, reminders: EKAuthorizationStatus) -> Bool {
        calendar == .restricted || reminders == .restricted
    }

    /// `hostAuthorization` reads the host context's authorization status. It is called only
    /// when the decision depends on it, so flags that never touch EventKit do not either.
    static func decide(
        arguments: [String],
        environment: [String: String],
        responsible: ResponsibleProcessResult,
        hostAuthorization: () -> HostAuthorization
    ) -> SelfDisclaimDecision {
        let flags = arguments.dropFirst()
        if isSet(environment[disclaimedSentinel]) {
            if case .resolved(let process) = responsible, !process.isSelf {
                return .skip(.disclaimIneffective)
            }
            return .skip(.alreadyDisclaimed)
        }
        if flags.contains(where: flagsWithoutTCCAccess.contains) {
            return .skip(.noTCCAccessNeeded)
        }
        if isSet(environment[optOutVariable]) { return .skip(.optedOut) }
        switch responsible {
        case .unavailable(let reason):
            return .skip(.responsibilityUnavailable(reason))
        case .resolved(let process) where process.isSelf:
            return .skip(.alreadySelfResponsible)
        case .resolved:
            // main.swift dispatches `--print-tcc-path` before `--setup`; follow the same order.
            if flags.contains("--setup"), !flags.contains("--print-tcc-path") { return .reexec(.setup) }
            let host = hostAuthorization()
            if hostIsRestricted(calendar: host.calendar, reminders: host.reminders) {
                return .skip(.hostRestrictedByPolicy)
            }
            if isSet(environment[forceVariable]) { return .reexec(.forced) }
            return hostGrantIsUsable(calendar: host.calendar, reminders: host.reminders)
                ? .skip(.hostGrantIsUsable) : .reexec(.hostGrantUnusable)
        }
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
