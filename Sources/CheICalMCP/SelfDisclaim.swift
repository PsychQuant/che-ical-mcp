import Foundation

/// Why CheICalMCP did not re-exec itself as its own responsible process (#343).
///
/// Closed set — exactly these five. A new reason means a new case here and a new test in
/// `SelfDisclaimDecisionTests`; do not fold one into an existing case by similarity.
enum SelfDisclaimSkipReason: Equatable, Sendable {
    /// `CHE_ICAL_MCP_DISCLAIMED` is set: this process is the re-exec'd image. Loop guard,
    /// independent of the responsibility lookup.
    case alreadyDisclaimed
    /// `CHE_ICAL_MCP_NO_DISCLAIM` is set: the user wants the host's grant (pre-#343 behavior).
    case optedOut
    /// Already its own responsible process — the Claude Desktop `.mcpb` server under
    /// `disclaimer`, or a binary launched by something that disclaimed it.
    case alreadySelfResponsible
    /// `--version` / `-v` / `--help` / `-h` / `--self-update` never touch EventKit.
    case noTCCAccessNeeded
    /// The responsibility SPI is missing or the lookup failed; run as before.
    case responsibilityUnavailable(String)
}

enum SelfDisclaimDecision: Equatable, Sendable {
    case reexec
    case skip(SelfDisclaimSkipReason)
}

/// Re-exec in place as our own responsible process, so macOS charges Calendar and
/// Reminders access to CheICalMCP — which carries the purpose strings — instead of to the
/// host. Under the Claude Code daemon the host is either the app that launched the daemon
/// or Claude Code's own binary, and the latter can never be prompted (#343).
enum SelfDisclaim {
    static let disclaimedSentinel = "CHE_ICAL_MCP_DISCLAIMED"
    static let optOutVariable = "CHE_ICAL_MCP_NO_DISCLAIM"
    static let flagsWithoutTCCAccess: Set<String> = ["--version", "-v", "--help", "-h", "--self-update"]

    static func decide(
        arguments: [String],
        environment: [String: String],
        responsible: ResponsibleProcessResult
    ) -> SelfDisclaimDecision {
        if isSet(environment[disclaimedSentinel]) { return .skip(.alreadyDisclaimed) }
        if arguments.dropFirst().contains(where: flagsWithoutTCCAccess.contains) {
            return .skip(.noTCCAccessNeeded)
        }
        if isSet(environment[optOutVariable]) { return .skip(.optedOut) }
        switch responsible {
        case .unavailable(let reason):
            return .skip(.responsibilityUnavailable(reason))
        case .resolved(let process) where process.isSelf:
            return .skip(.alreadySelfResponsible)
        case .resolved:
            return .reexec
        }
    }

    /// Same convention as `CHE_ICAL_MCP_NO_BANNER`: exported-but-empty counts as unset.
    private static func isSet(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }
}
