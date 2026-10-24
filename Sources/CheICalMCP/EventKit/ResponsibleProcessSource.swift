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

    static func classify(path: String?, isSelf: Bool) -> ResponsibleHostKind {
        if isSelf { return .selfBinary }
        guard let path, !path.isEmpty else { return .unknown }

        if let range = path.range(of: claudeCodeVersionsFragment) {
            let version = path[range.upperBound...].split(separator: "/").first.map(String.init)
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
