import EventKit
import Foundation

/// #361: why this process re-executed itself, carried across the exec in
/// `CHE_ICAL_MCP_DISCLAIMED`, because after the exec the host, what it had and the reason are gone.
///
/// The variable is unauthenticated and its content gets printed, so a parent process can set it to
/// anything. So every field is a closed vocabulary, and `decode` takes nothing else: no host name or
/// path is carried, and a value that is not exactly what `encoded` writes is unreadable. What it says
/// is reported as said by the image before the exec, not as verified.
struct SelfDisclaimRecord: Equatable, Sendable {
    enum Reason: String, CaseIterable, Sendable {
        case hostGrantUnusable, setup, forced
    }

    enum Status: String, CaseIterable, Sendable {
        case notDetermined, restricted, denied, fullAccess, writeOnly, unknown
        /// `--setup` re-executes without reading the host's status.
        case notRead

        init(_ status: EKAuthorizationStatus) {
            switch status {
            case .notDetermined: self = .notDetermined
            case .restricted: self = .restricted
            case .denied: self = .denied
            case .fullAccess: self = .fullAccess
            case .writeOnly: self = .writeOnly
            @unknown default: self = .unknown
            }
        }
    }

    enum Host: String, CaseIterable, Sendable {
        case claudeCode, appBundle, otherExecutable, unknown

        init(_ kind: ResponsibleHostKind?) {
            switch kind {
            case .claudeCode?: self = .claudeCode
            case .appBundle?: self = .appBundle
            case .otherExecutable?: self = .otherExecutable
            case .selfBinary?, .unknown?, nil: self = .unknown
            }
        }

        var word: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .appBundle: return "an app"
            case .otherExecutable: return "an executable"
            case .unknown: return "an unknown host"
            }
        }
    }

    /// Longer than any value `encoded` writes.
    private static let maxEncodedLength = 128

    let reason: Reason
    let calendar: Status
    let reminders: Status
    let host: Host

    init(reason: Reason, calendar: Status, reminders: Status, host: Host) {
        self.reason = reason
        self.calendar = calendar
        self.reminders = reminders
        self.host = host
    }

    init(reason: SelfDisclaimReexecReason, host authorization: HostAuthorization?, kind: ResponsibleHostKind?) {
        let carried: Reason
        switch reason {
        case .hostGrantUnusable: carried = .hostGrantUnusable
        case .setup: carried = .setup
        case .forced: carried = .forced
        }
        self.init(reason: carried, calendar: authorization.map { Status($0.calendar) } ?? .notRead,
                  reminders: authorization.map { Status($0.reminders) } ?? .notRead, host: Host(kind))
    }

    var encoded: String {
        "v1;reason=\(reason.rawValue);cal=\(calendar.rawValue);rem=\(reminders.rawValue);host=\(host.rawValue)"
    }

    static func decode(_ value: String) -> SelfDisclaimRecord? {
        guard value.utf8.count <= maxEncodedLength else { return nil }
        let fields = value.components(separatedBy: ";")
        guard fields.count == 5, fields[0] == "v1",
              let reason = field("reason", of: fields[1]).flatMap(Reason.init(rawValue:)),
              let calendar = field("cal", of: fields[2]).flatMap(Status.init(rawValue:)),
              let reminders = field("rem", of: fields[3]).flatMap(Status.init(rawValue:)),
              let host = field("host", of: fields[4]).flatMap(Host.init(rawValue:)) else { return nil }
        return SelfDisclaimRecord(reason: reason, calendar: calendar, reminders: reminders, host: host)
    }

    private static func field(_ name: String, of text: String) -> String? {
        text.hasPrefix(name + "=") ? String(text.dropFirst(name.count + 1)) : nil
    }

    private var hostStatus: String {
        calendar == .notRead && reminders == .notRead
            ? "the host's status was not read" : "had Calendar \(calendar.rawValue), Reminders \(reminders.rawValue)"
    }

    /// The line in `--print-tcc-path`, in the image after the exec.
    var attributionLine: String {
        "Re-executed at start (\(reason.rawValue), reported by the image before the exec): \(host.word) \(hostStatus)."
    }

    /// The one line on stderr before the exec, at every re-exec. `hostName` is the caller's, and is
    /// printed here only, so it stays out of the variable.
    func startLine(hostName: String) -> String {
        let name = EventKitErrorSanitizer.escapeForStderr(hostName)
        switch reason {
        case .hostGrantUnusable:
            return "[che-ical-mcp] re-executing so macOS checks CheICalMCP's own Calendar and Reminders grant: "
                + "\(name) \(hostStatus) (#343)\n"
        case .setup:
            return "[che-ical-mcp] --setup: re-executing so the grant it creates is CheICalMCP's own; "
                + "the host was \(name) (#343)\n"
        case .forced:
            return "[che-ical-mcp] \(SelfDisclaim.forceVariable) is set: re-executing so macOS checks "
                + "CheICalMCP's own Calendar and Reminders grant instead of the host's: \(name) \(hostStatus) (#343)\n"
        }
    }

    /// The host as the stderr line names it. The variable carries only `Host`.
    static func hostName(_ kind: ResponsibleHostKind?) -> String {
        switch kind {
        case .claudeCode(let version)?: return version.map { "Claude Code \($0)" } ?? "Claude Code"
        case .appBundle(let name)?: return name
        case .otherExecutable(let path)?: return path
        case .selfBinary?, .unknown?, nil: return Host.unknown.word
        }
    }
}

/// What the re-executed image found in the variable (#361).
enum CarriedReexec: Equatable, Sendable {
    case record(SelfDisclaimRecord)
    /// Set, but not what this binary writes: an older image, or something else set it.
    case unreadable

    init(sentinel value: String) {
        self = SelfDisclaimRecord.decode(value).map(CarriedReexec.record) ?? .unreadable
    }

    var attributionLine: String {
        switch self {
        case .record(let record): return record.attributionLine
        case .unreadable:
            return "\(SelfDisclaim.disclaimedSentinel) held a value this binary does not write, so why this "
                + "process re-executed is not known."
        }
    }
}
