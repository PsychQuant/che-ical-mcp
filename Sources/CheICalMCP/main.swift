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
    let absolute = BinaryPathResolver.resolveArgv0(argv0)

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

    // #169: the EventKit status above is context-dependent (attribution follows the
    // responsible process, not the binary — #168). Show the parent chain so users can
    // see WHICH context this query ran under, plus the warning that stops them from
    // reading a Terminal-context status as a Claude-Desktop verdict. Capture failure
    // degrades to a visible "(parent chain unavailable: …)" line — never silent.
    let chainResult = LiveParentChainSource().captureChain(from: getppid())
    print("")
    print(ParentChainFormatter.executionContextSection(
        selfPid: ProcessInfo.processInfo.processIdentifier,
        selfPath: absolute,
        result: chainResult))
    exit(0)
}

if CommandLine.arguments.contains("--setup") {
    // Non-interactive detection for --setup deliberately uses `includeCI: false` (#143):
    // `--setup` is the human-run manual remediation path — a person in Terminal.app who
    // happens to have CI=1 exported can still see the TCC dialog, so CI must NOT force a
    // skip here (unlike the MCP server gate, which passes includeCI: true). Both call
    // sites now share the pure `NonInteractiveDetection` helper (#149).
    let nonInteractive = NonInteractiveDetection.isNonInteractive(
        env: ProcessInfo.processInfo.environment,
        ppid: getppid(),
        hasGUISession: NonInteractiveDetection.hasGUISession,
        includeCI: false)
    if nonInteractive {
        print("WARNING: --setup appears to be running in a non-interactive session.")
        print("Permission dialogs cannot appear here. Run this command from Terminal.app instead.\n")
    }

    print("CheICalMCP Setup — Requesting Calendar & Reminders permissions...")
    print("(This triggers macOS TCC permission dialogs for this binary)\n")

    // The interactive requests must run inside a foreground NSApplication so EventKit's TCC
    // dialogs can present. A bare CLI async request has no foreground-app context or running
    // run loop, so on macOS 14+/26 the FIRST request (Calendar) silently returns denied while
    // a later one (Reminders) slips through (#163). SetupRunner mirrors che-apple-mail-mcp's
    // SetupWindow.run() (che-apple-mail-mcp#213). The non-interactive path can't present a dialog anyway, so it
    // reports status headlessly (skip / already-granted) and exits — never entering the loop.
    if nonInteractive {
        let bad = await SetupRunner.requestBoth(nonInteractive: true)
        SetupRunner.printGuidanceIfNeeded(bad)
        exit(bad ? 1 : 0)
    } else {
        // Top-level code is @MainActor-isolated (SE-0343), so we can drive
        // NSApplication directly on the main thread. runInteractive() never returns
        // (the delegate exits once the TCC dialogs resolve).
        SetupRunner.runInteractive()
    }
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
    // Resolved via `BinaryPathResolver` (#129) — same realpath(3) canonical path that
    // `--print-tcc-path` and `--self-update` now use. Eliminates the multi-hop symlink
    // discrepancy (#121) and the false-positive drift signal from `destinationOfSymbolicLink`'s
    // 1-hop limitation (#128).
    let resolvedPath = BinaryPathResolver.resolveArgv0(argv0)

    let mtime: Date? = {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }()

    // #163: cheap status reads (never trigger a dialog) so the banner can surface the
    // `--setup` command when Calendar isn't granted for this binary. Reuses the same
    // probe the authorization gate uses. Read BEFORE detector construction (#175): both
    // services gate the versioned-host check — a Reminders-only breakage under a
    // versioned host deserves the rotation explanation too (verify DA-1) — and the
    // extra `ps` spawn only happens on the ungranted path.
    let statusSource = LiveAuthorizationStatusSource()
    let calendarGranted = statusSource.authorizationStatus(for: .event) == .fullAccess
    let remindersGranted = statusSource.authorizationStatus(for: .reminder) == .fullAccess

    let detector = TCCDriftDetector(
        tcc: LiveTCCDatabaseSource(),
        processes: LiveProcessInventorySource(),
        runningBinaryPath: resolvedPath,
        diskBinaryMtime: mtime,
        eventKitAccessGranted: calendarGranted && remindersGranted
    )
    let report = detector.detect()
    let bundleID = Bundle.main.bundleIdentifier ?? "com.checheng.CheICalMCP"
    let banner = TCCDriftDetector.formatBanner(
        report: report,
        version: AppVersion.current,
        runningBinaryPath: resolvedPath,
        pid: ProcessInfo.processInfo.processIdentifier,
        bundleID: bundleID,
        calendarAccessGranted: calendarGranted
    )
    FileHandle.standardError.write(Data(banner.utf8))
}
