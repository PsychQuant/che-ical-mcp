import EventKit
import CheMCPKit
import Foundation
import MCP

// #343 — before any dispatch, re-exec in place as our own responsible process, so macOS
// charges Calendar and Reminders access to CheICalMCP (which carries the purpose strings)
// instead of to the host. Under the Claude Code daemon the host is either the app that
// launched the daemon or Claude Code's own binary, which can never be prompted. The rule
// reads the host context's status and is the same for every host: full Calendar and
// Reminders access keeps the host's grant, anything else re-execs (as do `--setup` and an
// explicit CHE_ICAL_MCP_FORCE_DISCLAIM). Both reason sets are closed (SelfDisclaimSkipReason,
// SelfDisclaimReexecReason); any failure is fail-open.
switch SelfDisclaim.decide(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    responsible: LiveResponsibleProcessSource().responsibleProcess(for: getpid()),
    hostHasUsableGrant: {
        // Class methods only: this image is about to be replaced, so no EKEventStore is built
        // here (verify round 3, row 15).
        SelfDisclaim.hostGrantIsUsable(
            calendar: EKEventStore.authorizationStatus(for: .event),
            reminders: EKEventStore.authorizationStatus(for: .reminder))
    }
) {
case .reexec(let reason):
    if reason == .forced {
        let notice = "[che-ical-mcp] \(SelfDisclaim.forceVariable) is set: re-executing so macOS checks "
            + "CheICalMCP's own Calendar and Reminders grant instead of the host's (#343)\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
    let failure = SelfDisclaim.reexecAsOwnResponsibleProcess(arguments: CommandLine.arguments)
    let message = "[che-ical-mcp] could not re-exec as its own responsible process "
        + "(\(EventKitErrorSanitizer.escapeForStderr(failure))); continuing under the host's TCC attribution (#343)\n"
    FileHandle.standardError.write(Data(message.utf8))
case .skip(.alreadyDisclaimed):
    // Keep the sentinel out of the environments of the subprocesses we spawn (ps, sqlite3).
    unsetenv(SelfDisclaim.disclaimedSentinel)
case .skip(.disclaimIneffective):
    // The sentinel is set but another process still owns the attribution: the re-exec did not
    // take effect, or the variable leaked in from an earlier run. Say so instead of skipping silently.
    unsetenv(SelfDisclaim.disclaimedSentinel)
    let message = "[che-ical-mcp] \(SelfDisclaim.disclaimedSentinel) is set but another process is still "
        + "responsible for this one (the re-exec did not take effect, or the variable was inherited); "
        + "continuing under the host's TCC attribution (#343)\n"
    FileHandle.standardError.write(Data(message.utf8))
case .skip(.responsibilityUnavailable(let reason)):
    let message = "[che-ical-mcp] responsible process unavailable "
        + "(\(EventKitErrorSanitizer.escapeForStderr(reason))); continuing under the host's TCC attribution (#343)\n"
    FileHandle.standardError.write(Data(message.utf8))
case .skip:
    break
}

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
        try await SelfUpdate.run(KitConfiguration.selfUpdate())
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

    // #343: the status below belongs to whichever process macOS charges the access to —
    // print it first, from the kernel, so nobody has to infer it from the parent chain.
    let attribution = ResponsibleProcessFormatter.attributionSection(
        selfPid: ProcessInfo.processInfo.processIdentifier,
        result: LiveResponsibleProcessSource().responsibleProcess(for: getpid()))

    print("""
        CheICalMCP TCC diagnostic info (\(AppVersion.current))

        Binary path:
          \(EventKitErrorSanitizer.escapeForStderr(absolute))

        Bundle identifier:
          \(bundleID)

        \(attribution)

        Current EventKit authorization status:
          Calendar:   \(statusString(calStatus))
          Reminders:  \(statusString(remStatus))

        Reset TCC + re-prompt (run from Terminal, NOT over SSH):
          tccutil reset Calendar \(bundleID)
          tccutil reset Reminders \(bundleID)
          \(EventKitManager.setupCommandHint(binaryPath: absolute))

        Inspect TCC database directly:
          sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db \\
            "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%CheICalMCP%'"
          (auth_value: 0=denied, 1=unknown, 2=granted, 3=limited)

        System Settings (manual toggle):
          System Settings → Privacy & Security → Calendar
          System Settings → Privacy & Security → Reminders

        Additional signing info:
          \(TCCDriftDetector.pathHasControlChars(absolute)
            ? "(binary path has control characters; run codesign -dv on it by hand)"
            : "codesign -dv \(TCCDriftDetector.shellSingleQuote(absolute))")
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
    print("(This triggers macOS TCC permission dialogs for this binary)")
    print(ResponsibleProcessFormatter.setupTargetLine(
        LiveResponsibleProcessSource().responsibleProcess(for: getpid())) + "\n")

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
    await CLIRunner.run(executor: server, tools: CheICalMCPServer.defineTools(),
                        usageName: KitConfiguration.usageName, args: CommandLine.arguments,
                        errorFormatter: { KitConfiguration.formatCLIError($0).jsonMessage })
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
    // services gate the host-attribution check (#343) — a Reminders-only breakage deserves
    // the explanation too (verify DA-1) — and the kernel lookup only happens on the
    // ungranted path.
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
