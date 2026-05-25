import EventKit
import Foundation
import MCP

// Handle command line arguments
if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print(AppVersion.versionString)
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(AppVersion.helpMessage)
    exit(0)
}

if CommandLine.arguments.contains("--self-update") {
    do {
        try await SelfUpdate.run()
        exit(0)
    } catch {
        // #49 verify Finding 4: SelfUpdateError does NOT conform to
        // TrustedErrorMessage because its detail strings come from
        // URLSession / FileManager localizedDescription (framework-
        // controlled, not author-controlled). Route through
        // escapeForStderr to defend against CWE-117 control-char
        // injection on the stderr path.
        let message = (error as? LocalizedError)?.errorDescription
                      ?? error.localizedDescription
        let safe = EventKitErrorSanitizer.escapeForStderr(message)
        FileHandle.standardError.write(Data("Self-update failed: \(safe)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--print-tcc-path") {
    // #109: TCC diagnostic flag — prints the runtime binary's path + bundle ID +
    // current EventKit authorization status + ready-to-paste tccutil reset / sqlite3
    // commands. Designed for the .mcpb-installed scenario where users can't easily
    // find the extracted binary path on their own.

    let argv0 = CommandLine.arguments[0]
    let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: argv0)) ?? argv0
    let absolute = URL(fileURLWithPath: resolved).standardizedFileURL.path

    let bundleID = Bundle.main.bundleIdentifier ?? "com.checheng.CheICalMCP"

    let calStatus = EKEventStore.authorizationStatus(for: .event)
    let remStatus = EKEventStore.authorizationStatus(for: .reminder)
    let statusString = TCCStatusFormatter.describe

    print("""
        CheICalMCP TCC diagnostic info (\(AppVersion.current))

        Binary path:
          \(absolute)

        Bundle identifier:
          \(bundleID)

        Current EventKit authorization status:
          Calendar:   \(statusString(calStatus))
          Reminders:  \(statusString(remStatus))

        Reset TCC + re-prompt (run from Terminal, NOT over SSH):
          tccutil reset Calendar \(bundleID)
          tccutil reset Reminders \(bundleID)
          "\(absolute)" --setup

        Inspect TCC database directly:
          sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db \\
            "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%CheICalMCP%'"
          (auth_value: 0=denied, 1=unknown, 2=granted, 3=limited)

        System Settings (manual toggle):
          System Settings → Privacy & Security → Calendar
          System Settings → Privacy & Security → Reminders

        Additional signing info:
          codesign -dv "\(absolute)"
        """)
    exit(0)
}

if CommandLine.arguments.contains("--setup") {
    // Warn if running in a non-interactive environment where TCC dialogs cannot appear
    if ProcessInfo.processInfo.environment["TERM"] == nil || getppid() == 1 {
        print("WARNING: --setup appears to be running in a non-interactive session.")
        print("Permission dialogs cannot appear here. Run this command from Terminal.app instead.\n")
    }

    print("CheICalMCP Setup — Requesting Calendar & Reminders permissions...")
    print("(This triggers macOS TCC permission dialogs for this binary)\n")

    let store = EKEventStore()

    // Request Calendar access
    do {
        let granted = try await store.requestFullAccessToEvents()
        print("Calendar access: \(granted ? "✓ granted" : "✗ denied")")
    } catch {
        print("Calendar access: ✗ error — \(error.localizedDescription)")
    }

    // Request Reminders access
    do {
        let granted = try await store.requestFullAccessToReminders()
        print("Reminders access: \(granted ? "✓ granted" : "✗ denied")")
    } catch {
        print("Reminders access: ✗ error — \(error.localizedDescription)")
    }

    print("\nIf permissions were denied, grant them manually:")
    print("  System Settings → Privacy & Security → Calendar → enable CheICalMCP")
    print("  System Settings → Privacy & Security → Reminders → enable CheICalMCP")
    exit(0)
}

// CLI mode: invoke tools directly without MCP server
if CommandLine.arguments.contains("--cli") {
    let server = try await CheICalMCPServer()
    await CLIRunner.run(server: server, args: CommandLine.arguments)
    exit(0)
}

// MCP server mode (default) — emit a startup banner with drift signals first
// (#122). Wrapped in do/catch so a banner failure never blocks the server: every
// drift signal is advisory and the banner is opt-out via CHE_ICAL_MCP_NO_BANNER.
emitStartupBanner()

let server = try await CheICalMCPServer()
try await server.run()

/// #122 — drift detector banner. Single-shot at startup, stderr only, non-blocking.
///
/// Skip conditions: env `CHE_ICAL_MCP_NO_BANNER` set. CLI side-channels (`--version` /
/// `--help` / `--setup` / `--print-tcc-path` / `--self-update` / `--cli`) all exit
/// before reaching this function — no need to re-check.
///
/// All call sites below use `try?` to swallow underlying failures (symlink resolution,
/// attribute fetch); the inner detector calls are non-throwing by design (subprocess
/// failures surface as `failureReason` skip-reasons in the banner). No `do/catch` is
/// needed — verify finding F1 (#122) removed the prior dead-catch wrapper.
func emitStartupBanner() {
    let env = ProcessInfo.processInfo.environment
    if let v = env["CHE_ICAL_MCP_NO_BANNER"], !v.isEmpty {
        return
    }

    let argv0 = CommandLine.arguments.first ?? ""
    let resolvedPath: String = {
        // Real path resolution mirrors `--print-tcc-path` behavior. See verify F5 /
        // F7 for the known follow-up about unifying `realpath(3)` across all three
        // diagnostic entry points (banner, --print-tcc-path, --self-update).
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: argv0) {
            return URL(fileURLWithPath: dest).standardizedFileURL.path
        }
        return URL(fileURLWithPath: argv0).standardizedFileURL.path
    }()

    let mtime: Date? = {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }()

    let detector = TCCDriftDetector(
        tcc: LiveTCCDatabaseSource(),
        processes: LiveProcessInventorySource(),
        runningBinaryPath: resolvedPath,
        diskBinaryMtime: mtime
    )
    let report = detector.detect()
    let bundleID = Bundle.main.bundleIdentifier ?? "com.checheng.CheICalMCP"
    let banner = TCCDriftDetector.formatBanner(
        report: report,
        version: AppVersion.current,
        runningBinaryPath: resolvedPath,
        pid: ProcessInfo.processInfo.processIdentifier,
        bundleID: bundleID
    )
    FileHandle.standardError.write(Data(banner.utf8))
}
