import Darwin
import Foundation

/// Test seam for the process macOS charges Calendar and Reminders access to (#343).
///
/// Why this exists: TCC attributes an EventKit request to the *responsible process* the
/// kernel assigned at spawn time, not to the `getppid` chain (#168, #169). Under the
/// Claude Code daemon a spare-claimed session inherits the app that launched the daemon
/// (e.g. VS Code), while a worker the daemon launches through `ClaudeCode.app` is its own
/// responsible process — two contexts with the same parent chain shape and different
/// grants. Diagnostics that walk `ps` cannot tell them apart; this source asks the kernel.
/// Per CLAUDE.md "Test Seam Convention": narrow `<Domain>Source` protocol, Live impl
/// default-wired, fake injected in tests.
protocol ResponsibleProcessSource: Sendable {
    /// Never throws — a lookup failure returns a reason so callers can print it.
    func responsibleProcess(for pid: Int32) -> ResponsibleProcessResult
}

/// The responsible process of some pid, as reported by the kernel.
struct ResponsibleProcess: Sendable, Equatable {
    let pid: Int32
    let path: String?
    /// The queried process is its own responsible process (self-disclaimed, or the
    /// `.mcpb` server under Claude Desktop's `disclaimer`).
    let isSelf: Bool

    var kind: ResponsibleHostKind {
        ResponsibleHostClassifier.classify(path: path, isSelf: isSelf)
    }
}

enum ResponsibleProcessResult: Sendable, Equatable {
    case resolved(ResponsibleProcess)
    case unavailable(reason: String)
}

/// The kind of TCC client a responsible process is, phrased for user-facing advice.
enum ResponsibleHostKind: Sendable, Equatable {
    /// CheICalMCP itself — the grant lives on this binary.
    case selfBinary
    /// Claude Code's native binary (`versions/<ver>` or `ClaudeCode.app`). It carries no
    /// Calendar or Reminders purpose string, so macOS never shows a prompt for it (#343).
    case claudeCode(version: String?)
    /// An ordinary app bundle (Terminal, VS Code, Ghostty, …), named as System Settings shows it.
    case appBundle(name: String)
    /// A bare executable outside any app bundle.
    case otherExecutable(path: String)
    /// The kernel gave no path.
    case unknown
}

enum ResponsibleHostClassifier {
    static let claudeCodeVersionsFragment = "/.local/share/claude/versions/"
    static let claudeCodeAppFragment = "/.local/share/claude/ClaudeCode.app/"
    private static let appExecutableMarker = ".app/Contents/MacOS/"

    private static let versionCharacters = CharacterSet(
        charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-")

    private static func sanitizedVersion(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 32,
              raw.unicodeScalars.allSatisfy(versionCharacters.contains) else { return nil }
        return raw
    }

    static func classify(path: String?, isSelf: Bool) -> ResponsibleHostKind {
        if isSelf { return .selfBinary }
        guard let path, !path.isEmpty else { return .unknown }

        if let range = path.range(of: claudeCodeVersionsFragment) {
            // The component is a name anyone can give a file, and it is printed into messages an
            // MCP client reads: keep it only if it looks like a version.
            let version = path[range.upperBound...].split(separator: "/").first
                .map(String.init).flatMap(sanitizedVersion)
            return .claudeCode(version: version)
        }
        if path.contains(claudeCodeAppFragment) {
            return .claudeCode(version: nil)
        }
        // The innermost bundle is the one whose executable this is, so anchor on the last
        // `.app/Contents/MacOS/` and take the path component that ends in `.app`.
        if let marker = path.range(of: appExecutableMarker, options: .backwards) {
            let bundlePath = path[..<marker.lowerBound]
            if let name = bundlePath.split(separator: "/").last, !name.isEmpty {
                return .appBundle(name: String(name))
            }
        }
        return .otherExecutable(path: path)
    }
}

/// Display layer for the responsible process (#343): the `--print-tcc-path` attribution
/// block, and the per-kind advice that the banner and the access-denied message reuse so
/// all three name the same client.
enum ResponsibleProcessFormatter {
    static func advice(for kind: ResponsibleHostKind) -> String {
        switch kind {
        case .selfBinary:
            return "macOS checks CheICalMCP's own grant: System Settings → Privacy & Security → "
                + "Calendar / Reminders → CheICalMCP."
        case .claudeCode(let version):
            let name = version.map { "Claude Code \($0)" } ?? "Claude Code"
            return "macOS checks \(name), which has no Calendar or Reminders purpose string, so it "
                + "can never be prompted. When the host has no full Calendar and Reminders access, "
                + "CheICalMCP re-executes itself so that it is checked under its own name, and this "
                + "process was not re-executed: CHE_ICAL_MCP_NO_DISCLAIM is set, CHE_ICAL_MCP_DISCLAIMED "
                + "was inherited, the re-exec failed (see the start-up line on stderr), or \(name) had "
                + "full access when this server started and has lost it since (#343)."
        case .appBundle(let name):
            return "macOS checks \(name)'s grant: System Settings → Privacy & Security → "
                + "Calendar / Reminders → \(name)."
        case .otherExecutable(let path):
            return "macOS checks the grant of \(path)."
        case .unknown:
            return "macOS did not report which process it checks."
        }
    }

    /// What to do when macOS checks a host and the host has no grant (#343, verify round 2
    /// row 1). The banner and the access-denied message both print these steps, so they give
    /// the same advice (verify round 3 row 11). Under the status-aware rule a host without full
    /// access at start-up makes CheICalMCP re-exec, so a restart is what moves this server onto
    /// CheICalMCP's own grant — the one `--setup` creates — unless one of the things that stops
    /// the re-exec is in the way (verify round 3 row 8). `setupCommand` is a ready-to-paste
    /// command from `EventKitManager.setupCommandHint`; `settingsPane` is the System Settings
    /// pane to name; `alsoEnable` offers keeping an app host's own grant instead.
    static func hostAttributedRemedy(setupCommand: String, settingsPane: String, alsoEnable: String?) -> [String] {
        let settings = "Open System Settings → Privacy & Security → \(settingsPane) and switch CheICalMCP on "
            + "if it is listed as off (a recorded \"Don't Allow\" is not asked again)"
        return [
            "Restart the MCP client. When the host has no full Calendar and Reminders access, CheICalMCP "
                + "re-executes itself and macOS checks CheICalMCP's own grant. If CHE_ICAL_MCP_NO_DISCLAIM, or an "
                + "inherited CHE_ICAL_MCP_DISCLAIMED, is set in the server's environment, remove it first; "
                + "if the server's stderr has a \"could not re-exec\" line, a restart does not help — see that line.",
            "If CheICalMCP's own grant is not set up yet, create it once from Terminal: \(setupCommand)",
            alsoEnable.map { settings + ", or \($0) to keep using its grant" } ?? settings,
        ]
    }

    /// The attribution line for a host whose context already has full Calendar and Reminders
    /// access: under the status-aware rule its grant is kept on purpose, so the failure causes
    /// in `advice(for:)` do not apply (verify round 3 row 3).
    static func keptHostLine(for kind: ResponsibleHostKind) -> String {
        let name: String
        switch kind {
        case .claudeCode(let version): name = version.map { "Claude Code \($0)" } ?? "Claude Code"
        case .appBundle(let app): name = app
        case .otherExecutable(let path): name = path
        case .selfBinary: name = "CheICalMCP"
        case .unknown: name = "the responsible process"
        }
        return "macOS checks \(name)'s grant, which has full Calendar and Reminders access, so CheICalMCP "
            + "keeps it and does not re-execute itself (#343)."
    }

    private static let appNameCharacters = CharacterSet.letters
        .union(.decimalDigits).union(.nonBaseCharacters).union(CharacterSet(charactersIn: " .-_()+"))

    /// An app bundle name fit to go into a message returned to an MCP client, or `nil`. The
    /// name is a path component anyone can choose, so only a short plain name passes:
    /// letters, digits, spaces and `.-_()+`, at most 64 characters (#343 verify round 2, row 9).
    static func responseSafeAppName(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy(appNameCharacters.contains) else { return nil }
        return name
    }

    /// The line `--setup` prints before requesting access: whose grant the dialogs create.
    static func setupTargetLine(_ result: ResponsibleProcessResult) -> String {
        let escape = EventKitErrorSanitizer.escapeForStderr
        switch result {
        case .unavailable(let reason):
            return "Authorization target: unknown (\(escape(reason)))"
        case .resolved(let process) where process.isSelf:
            let path = process.path.map(escape) ?? "(no path reported)"
            return "Authorization target: CheICalMCP (\(path)) — used whenever the responsible process macOS "
                + "checks for this binary (not necessarily the one that starts it) has no full Calendar and "
                + "Reminders access of its own (#343)"
        case .resolved(let process):
            let host: String
            switch process.kind {
            case .appBundle(let name): host = name
            case .claudeCode(let version): host = version.map { "Claude Code \($0)" } ?? "Claude Code"
            case .otherExecutable(let path): host = path
            case .selfBinary, .unknown: host = process.path ?? "an unknown process"
            }
            return "WARNING: macOS will record this grant for \(escape(host)), not CheICalMCP "
                + "(CHE_ICAL_MCP_NO_DISCLAIM is set, CHE_ICAL_MCP_DISCLAIMED was inherited, or the re-exec failed — #343)"
        }
    }

    static func attributionSection(selfPid: Int32, result: ResponsibleProcessResult, hostGrantUsable: Bool = false) -> String {
        // The path comes from the kernel but names a file anyone can create — escape it
        // like every other interpolated field on this output (CWE-150/117, #169).
        let escape = EventKitErrorSanitizer.escapeForStderr
        var lines = ["TCC attribution (the process macOS checks for Calendar and Reminders):"]
        switch result {
        case .unavailable(let reason):
            lines.append("  (responsible process unavailable: \(escape(reason)))")
        case .resolved(let process):
            let path = process.path.map(escape) ?? "(no path reported)"
            let marker = process.isSelf ? "  (this binary)" : ""
            lines.append("  \(process.pid)  \(path)\(marker)")
            let line = (!process.isSelf && hostGrantUsable) ? keptHostLine(for: process.kind) : advice(for: process.kind)
            lines.append("  \(escape(line))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Production implementation over the kernel's responsibility SPI.
///
/// `responsibility_get_pid_responsible_for_pid` is private libSystem API, so it is looked
/// up with `dlsym` rather than linked: if a future macOS drops or renames it, the lookup
/// returns a visible reason and every caller degrades to its pre-#343 behavior.
struct LiveResponsibleProcessSource: ResponsibleProcessSource {
    private typealias ResponsibleForPid = @convention(c) (pid_t) -> pid_t

    /// `RTLD_DEFAULT` is `((void *) -2)` on Darwin; the macro is not imported into Swift.
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    /// `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN); the macro is not imported into Swift.
    private static let pidPathMaxSize = 4 * 1024

    static var isAvailable: Bool {
        dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") != nil
    }

    func responsibleProcess(for pid: Int32) -> ResponsibleProcessResult {
        guard let symbol = dlsym(Self.rtldDefault, "responsibility_get_pid_responsible_for_pid") else {
            return .unavailable(reason: "responsibility SPI not found in this macOS")
        }
        let responsibleFor = unsafeBitCast(symbol, to: ResponsibleForPid.self)
        let responsible = responsibleFor(pid)
        guard responsible > 0 else {
            return .unavailable(reason: "kernel reported no responsible process for pid \(pid)")
        }
        return .resolved(ResponsibleProcess(
            pid: responsible,
            path: Self.executablePath(of: responsible),
            isSelf: responsible == pid))
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pidPathMaxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
