import CheMCPKit
import CoreLocation
import EventKit
import Foundation

/// The subset of `EventKitManager`'s surface that handler integration tests
/// need to script. Kept deliberately minimal (#31 design D1): new methods land
/// here only when at least one landing test exercises them via
/// `FakeEventKitManager`.
///
/// Conformance is `Sendable` because `EventKitManager` is an actor and
/// `FakeEventKitManager` is also expected to be actor-isolated.
protocol EventKitManaging: Sendable {
    /// Return completed-reminder identifiers, optionally scoped to a calendar.
    ///
    /// The cleanup handler only needs identifiers — it never reads other
    /// `EKReminder` properties in its flow. Returning `[String]` directly
    /// lets `FakeEventKitManager` be a simple struct holder instead of
    /// fabricating `EKReminder` instances (which are tied to a real,
    /// authorized `EKEventStore`).
    func listCompletedReminderIdentifiers(
        calendarName: String?,
        calendarSource: String?
    ) async throws -> [String]

    /// See `EventKitManager.deleteRemindersBatch(identifiers:onlyCompleted:)`.
    func deleteRemindersBatch(
        identifiers: [String],
        onlyCompleted: Bool
    ) async throws -> BatchDeleteResult
}

/// EventKit wrapper for Calendar and Reminders operations
actor EventKitManager: EventKitManaging, ReminderReadSource, ReminderCompletionSource {
    // Internal for same-actor feature extensions; still actor-isolated. It counts its own commits
    // (`CountingEventStore`, #328).
    let eventStore: CountingEventStore
    private let authorizationSource: AuthorizationStatusSource
    private var needsRefresh = false
    /// #322: a test's `SeriesExceptionsStoreSource` (`forTesting(probe:seriesExceptionsStore:)`);
    /// nil in production, where the delete-undo exceptions layer runs on this manager's own store
    /// (`seriesExceptionsStore`).
    let seriesExceptionsStoreOverride: (any SeriesExceptionsStoreSource)?
    /// #321: the series a whole-series delete-undo recreated, by the series it was recorded as, so
    /// an older occurrence record of that series sees its slot held (`OccurrenceSlotGuard`). In
    /// memory, like the undo history: a restart loses both together.
    var seriesRecreations = SeriesRecreations()

    static let shared = EventKitManager()

    /// Singleton invariant: production code MUST go through `EventKitManager.shared`.
    /// Tests inject a mock probe via `EventKitManager.forTesting(probe:)` (DEBUG-only
    /// factory below). The init itself is `fileprivate` so only `shared` and the
    /// test factory in this file can construct instances. (#115)
    ///
    /// - Parameter authorizationSource: Probe for TCC state reads + access requests.
    ///   Default wires `LiveAuthorizationStatusSource` sharing the same `EKEventStore`
    ///   instance so request attribution matches data-ops.
    fileprivate init(authorizationSource: AuthorizationStatusSource? = nil,
                     seriesExceptionsStore: (any SeriesExceptionsStoreSource)? = nil) {
        let store = CountingEventStore()
        self.eventStore = store
        self.authorizationSource = authorizationSource ?? LiveAuthorizationStatusSource(store: store)
        self.seriesExceptionsStoreOverride = seriesExceptionsStore
    }

    #if DEBUG
    /// Test-only factory for injecting a custom `AuthorizationStatusSource` (e.g. a mock
    /// that returns `.notDetermined` without prompting). Production callers must use
    /// `EventKitManager.shared` — see fileprivate `init` above for the singleton invariant. (#115)
    static func forTesting(probe: AuthorizationStatusSource) -> EventKitManager {
        EventKitManager(authorizationSource: probe)
    }

    /// #322: also runs the `.deleteEvent` and `.deleteOccurrence` undo arms (`SeriesExceptionsUndo`,
    /// the exceptions restore and the slot guard included) on `seriesExceptionsStore`. The record
    /// sites' capture does not read it: it always runs on the manager's own store.
    static func forTesting(probe: AuthorizationStatusSource,
                           seriesExceptionsStore: any SeriesExceptionsStoreSource) -> EventKitManager {
        EventKitManager(authorizationSource: probe, seriesExceptionsStore: seriesExceptionsStore)
    }
    #endif

    // MARK: - Access Gate (#108 Phase 2)

    private static let isSSHSession: Bool =
        ProcessInfo.processInfo.environment["SSH_CLIENT"] != nil
            || ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil

    /// Detect if running in a non-interactive session (launchd daemon, cron, CI, no GUI).
    /// Delegates to the pure `NonInteractiveDetection` helper (#149) with `includeCI: true` —
    /// the MCP server gate treats a CI runner as non-interactive (#131). Uses a window-server
    /// (Aqua) session probe rather than `TERM` (#165): a GUI-app-spawned MCP server (Claude
    /// Desktop) has no controlling TTY yet IS in a GUI session and CAN present the TCC dialog,
    /// so it must NOT be treated as non-interactive — otherwise the gate fast-fails before
    /// `requestFullAccess` and the first-grant dialog never appears.
    private static let isNonInteractiveSession: Bool =
        NonInteractiveDetection.isNonInteractive(
            env: ProcessInfo.processInfo.environment,
            ppid: getppid(),
            hasGUISession: NonInteractiveDetection.hasGUISession,
            includeCI: true)

    /// Test-accessible wrapper
    static var isNonInteractive: Bool { isNonInteractiveSession }

    /// Detect the `.mcpb` extension install context inside Claude Desktop (#133).
    ///
    /// When the binary lives under `Claude Extensions/local.mcpb.*/server/`,
    /// it was spawned by Claude Desktop's `.mcpb` extension installer. On
    /// Claude Desktop ≥ 1.6608.2 (verified through current 1.8555.2 as of
    /// 2026-05-26), this spawn path hits the upstream Calendar/Reminders
    /// access regression tracked at `anthropics/claude-code#58239` (still
    /// open as of writing) — Claude.app bundle is missing the
    /// `com.apple.security.personal-information.calendars` entitlement and
    /// `NSCalendarsFullAccessUsageDescription` Info.plist string that
    /// macOS 14+ requires on the responsible process.
    ///
    /// Detection is by binary path substring because the bug is install-
    /// channel-specific (only `.mcpb` is affected; Claude Code plugin path
    /// `~/bin/CheICalMCP` is unaffected — different spawn chain).
    static let isMCPBClaudeDesktopInstall: Bool = {
        // The kernel's path, not argv[0] against the current directory (#360).
        RunningBinaryPath.current().contains("Claude Extensions/local.mcpb.")
    }()

    /// Pure formatter for the binary-specific `--setup` remediation hint (#163).
    /// The path is injected (not read from globals) so denial-message wiring is
    /// unit-testable deterministically. A clean path is single-quoted, so a pasted hint
    /// expands nothing — inside double quotes `$(…)` and backticks still run (#343 verify
    /// round 2, row 9) — and nothing else is done to it: escaping first doubled every
    /// backslash, so the quoted path named another file (verify round 3, row 10). A path with
    /// control characters gets no runnable command, only its escaped form to read. The
    /// access-denied message, the banner's host remedy and `--print-tcc-path` use it; the
    /// banner's other `--setup` lines quote with the same `shellSingleQuote` (verify round 3b
    /// row 14).
    static func setupCommandHint(binaryPath: String) -> String {
        guard !TCCDriftDetector.pathHasControlChars(binaryPath) else {
            return "run the binary at \(EventKitErrorSanitizer.escapeForStderr(binaryPath)) with --setup "
                + "(its path has control characters, so no command is printed)"
        }
        return "\(TCCDriftDetector.shellSingleQuote(binaryPath)) --setup"
    }

    /// What stands where `tccutil reset <service> com.checheng.CheICalMCP` stood (#357): that
    /// command fails with -10814 for a bare binary (no LaunchServices registration, README
    /// erratum). Round 4 (R1): no new remedy prose — this is the sentence main already uses in
    /// the self-attributed, already-denied access-denied branch, with the pane name, and #382 as
    /// the pointer to the open device question. Round 5: "on, or off and on", because these
    /// surfaces do not see an off switch. No reset of any kind.
    static func switchOnStep(pane: String) -> String {
        "switch CheICalMCP on, or off and on, in System Settings → Privacy & Security → \(pane) (#382)"
    }

    /// The "Re-prompt" section of `--print-tcc-path`, built here (not inline in `main.swift`)
    /// so it can be pinned without spawning the binary (#357, #368). It carries no reset (#357).
    static func printTCCPathRepromptSection(
        binaryPath: String,
        calendarStatus: EKAuthorizationStatus,
        remindersStatus: EKAuthorizationStatus
    ) -> String {
        var lines = [
            "Re-prompt (run from Terminal, NOT over SSH):",
            "  \(setupCommandHint(binaryPath: binaryPath))",
            "  If that does not restore access: " + switchOnStep(pane: "Calendar / Reminders"),
        ]
        // #368: a `restricted` status comes from a configuration profile or Screen Time; no
        // prompt appears for it, so nothing in this section can change it.
        if calendarStatus == .restricted || remindersStatus == .restricted {
            lines.append("  (a `restricted` status is set by a configuration profile or Screen Time: "
                + "nothing here changes it; ask whoever manages this Mac)")
        }
        return lines.joined(separator: "\n")
    }

    /// The binary path as `--print-tcc-path` shows it: as is, so it names the same file as the
    /// `--setup` command beneath it, unless it has control characters, which are escaped and
    /// said so (verify round 3b row 11: escaping a clean path doubled its backslashes).
    static func binaryPathForDisplay(_ path: String) -> String {
        guard TCCDriftDetector.pathHasControlChars(path) else { return path }
        return "\(EventKitErrorSanitizer.escapeForStderr(path))  (escaped: the path has control characters)"
    }

    /// Resolve the running binary's canonical path (`RunningBinaryPath`: the kernel's path,
    /// argv[0] only as a fallback, #360 — the same path `--print-tcc-path` / the banner use)
    /// and format the `--setup`
    /// remediation hint. The `.mcpb` install's binary lives at a buried path users can't
    /// easily locate, so denial messages surface the exact command to grant THIS binary's
    /// TCC permission — the foreground `--setup` is what makes the dialog present (#163).
    static func resolvedSetupCommandHint() -> String {
        setupCommandHint(binaryPath: RunningBinaryPath.current())
    }

    /// Pure formatter for the `EventKitError.accessDenied` remediation message. Every
    /// environment signal (`isMCPB`, `deniedByStatus`) and the resolved `--setup` hint are
    /// injected — not read from globals — so branch selection is unit-testable deterministically
    /// (same rationale as `setupCommandHint(binaryPath:)`; `isMCPBClaudeDesktopInstall` is a
    /// path-derived static that a test cannot flip). `deniedByStatus` selects the #154 dead-end
    /// variant that must NOT lead with `--setup`, because a bare `--setup` cannot re-prompt a
    /// status that is already `.denied` (the status-first check only requests on `.notDetermined`). (#158)
    /// `attribution` is the kind of process macOS checks (#343); it only shapes the generic
    /// branch, and `nil` means the kernel lookup was unavailable. `restrictedByPolicy` is a
    /// `.restricted` status (a configuration profile or Screen Time), which no prompt, switch
    /// or `--setup` can change, so it takes precedence over every other branch. It names the
    /// process macOS checks, because a restricted host keeps its attribution (#367).
    static func accessDeniedMessage(
        type: String,
        isSSH: Bool,
        isNonInteractive: Bool,
        isMCPB: Bool,
        deniedByStatus: Bool,
        setupHint: String,
        attribution: ResponsibleHostKind? = nil,
        restrictedByPolicy: Bool = false
    ) -> String {
        if restrictedByPolicy {
            let checked: String
            switch attribution {
            case .selfBinary?: checked = "CheICalMCP"
            case .claudeCode?: checked = "Claude Code"
            case .appBundle(let name)? where ResponsibleProcessFormatter.responseSafeAppName(name) != nil: checked = name
            default: checked = "the process macOS checks for this server (`CheICalMCP --print-tcc-path` shows which one)"
            }
            return """
            \(type) access is restricted on this Mac (TCC status `restricted`): a configuration \
            profile (MDM) or a Screen Time restriction controls it, so no prompt will appear and \
            the System Settings switch cannot change it. Ask whoever manages this Mac to allow \
            \(type) access for \(checked).
            """
        }
        if isSSH && isNonInteractive {
            return """
            \(type) access denied (SSH + non-interactive session detected). \
            macOS TCC does not carry privacy permissions to SSH sessions, \
            and permission dialogs cannot appear in non-interactive environments. Workarounds:
            1. Run 'CheICalMCP --setup' once from Terminal on the target Mac (not over SSH)
            2. Or manually add CheICalMCP in: \
            System Settings → Privacy & Security → \(type)
            3. Or grant Full Disk Access to /usr/sbin/sshd: \
            System Settings → Privacy & Security → Full Disk Access → add sshd
            4. After any step, restart both the SSH session and the non-interactive job \
            (launchd service, CI runner, etc.)
            """
        }
        if isSSH {
            return """
            \(type) access denied (SSH session detected). \
            macOS TCC does not carry privacy permissions to SSH sessions. Workarounds:
            1. Run CheICalMCP once LOCALLY first to trigger the TCC permission dialog
            2. Or grant Full Disk Access to /usr/sbin/sshd: \
            System Settings → Privacy & Security → Full Disk Access → add sshd
            3. After either step, restart the SSH session
            """
        }
        if isNonInteractive {
            return """
            \(type) access denied (non-interactive session detected — launchd / CI runner / no TTY). \
            macOS TCC cannot show permission dialogs in non-interactive sessions. Workarounds:
            1. Run this binary's setup once from Terminal to trigger the TCC permission dialog: \
            \(setupHint)
            2. Or switch CheICalMCP on, or off and on, in System Settings → Privacy & Security → \(type) \
            (if it is not listed, step 1 adds it: an app appears there once it requests access)
            3. After granting permission, restart the non-interactive job (launchd service, CI runner, etc.)
            """
        }
        // #154 dead-end signature under the `.mcpb` install: TCC status was already `.denied`
        // at the gate, so a bare `--setup` cannot re-prompt (the status-first check skips
        // requestFullAccess unless the status is `.notDetermined`). Recommending `--setup`
        // here actively misleads — Terminal `--setup` reads the *lying* `.fullAccess` legacy
        // row and no-ops, while the MCP context stays denied. Name the real blocker (#63032)
        // and point at the paths that actually work. (#158)
        if isMCPB && deniedByStatus {
            return """
            \(type) access denied (Claude Desktop `.mcpb` install; macOS TCC already reports this \
            binary as denied — not a first-run prompt). Re-running `--setup` will NOT fix this: the \
            status-first check only calls requestFullAccess on `.notDetermined`, so an already-denied \
            status short-circuits. This is the #154 signature — a stale Developer-ID TCC row \
            csreq-mismatches and reads back denied in the MCP context, while a Terminal `--setup`/`--cli` \
            sees the *lying* `.fullAccess` row and no-ops. Real blocker: csreq mismatch on a legacy \
            pinned row + Claude Desktop attribution lacking usage strings \
            (ref anthropics/claude-code#63032, https://github.com/anthropics/claude-code/issues/63032). \
            What actually works:
            1. Use the Claude Code plugin install path — a different spawn chain that avoids Claude.app's \
            `disclaimer` wrapper entirely (see #132): in Claude Code, run \
            `claude plugin install che-ical-mcp@psychquant-claude-plugins`
            2. Or \(switchOnStep(pane: type))
            3. Or, for one-off calendar data, fall back to `.ics` import
            4. Track the upstream fix: anthropics/claude-code#63032 (and #58239)
            """
        }
        // #133 / #163: first-run under `.mcpb` (status was `.notDetermined`, or the dialog could not
        // present) — here `--setup` from a foreground Terminal context IS the fix, because the status
        // is still requestable. Distinct from the `deniedByStatus` dead end above.
        if isMCPB {
            return """
            \(type) access denied (Claude Desktop `.mcpb` install). On macOS 14+ the TCC \
            permission dialog only presents from a foreground app context, so grant THIS \
            binary access by running its setup once from Terminal:
            1. \(setupHint)
            2. Click Allow on the \(type) dialog, then fully quit + reopen Claude Desktop (Cmd+Q)
            3. If still denied after granting (a signed-binary entitlement edge case still \
            under investigation), use the Claude Code plugin install path, which avoids \
            Claude.app's `disclaimer` wrapper — in Claude Code, run: \
            `claude plugin install che-ical-mcp@psychquant-claude-plugins`
            4. Background / follow / 👍 the upstream tracker: \
            anthropics/claude-code#58239 (https://github.com/anthropics/claude-code/issues/58239)
            """
        }
        // #343: name the process macOS actually checks. The old step "Enable access for the
        // MCP server or Terminal" named neither of them under the Claude Code daemon.
        switch attribution {
        case .selfBinary?:
            if deniedByStatus {
                // macOS already recorded "Don't Allow": no prompt will appear and --setup cannot
                // re-prompt (the #154 / #158 dead end), so do not promise one.
                // `tccutil reset <service> com.checheng.CheICalMCP` is not offered: for a bare
                // binary it fails with -10814 (no LaunchServices registration; README erratum).
                return """
                \(type) access denied. \(ResponsibleProcessFormatter.advice(for: .selfBinary))
                macOS already has a "Don't Allow" recorded for CheICalMCP, so no prompt will appear.
                1. Switch CheICalMCP on in System Settings → Privacy & Security → \(type)
                2. Restart Claude Desktop/Code
                """
            }
            return """
            \(type) access denied. \(ResponsibleProcessFormatter.advice(for: .selfBinary))
            1. Allow the macOS prompt for CheICalMCP, or run its setup from Terminal: \(setupHint)
            2. Open System Settings → Privacy & Security → \(type) and switch CheICalMCP on (instead of step 1)
            3. Restart Claude Desktop/Code
            """
        // A host is checked and has no grant: the steps are the same ones the banner prints
        // (#343 verify round 2, row 1), so the two cannot contradict each other.
        case .claudeCode(let version)?:
            return ([
                "\(type) access denied. \(ResponsibleProcessFormatter.advice(for: .claudeCode(version: version)))",
            ] + numbered(ResponsibleProcessFormatter.hostAttributedRemedy(
                setupCommand: setupHint, settingsPane: type, alsoEnable: nil)))
                .joined(separator: "\n")
        case .appBundle(let name)?:
            // The name comes from a path anyone can create and is returned to an MCP client, so
            // only a plain name is echoed (round 2, row 9).
            let app = ResponsibleProcessFormatter.responseSafeAppName(name)
            let checked = app.map { "\($0)'s grant" } ?? "the grant of the app that launched this server"
            let toggle = app.map { "enable \($0)" }
                ?? "enable the app that launched this server (`CheICalMCP --print-tcc-path` shows its name)"
            let steps = ResponsibleProcessFormatter.hostAttributedRemedy(
                setupCommand: setupHint, settingsPane: type, alsoEnable: toggle)
            return (["\(type) access denied. macOS checks \(checked) here, not CheICalMCP's."] + numbered(steps))
                .joined(separator: "\n")
        case .otherExecutable?, .unknown?:
            return ([
                "\(type) access denied. macOS checks another process here, not CheICalMCP "
                    + "(run `CheICalMCP --print-tcc-path` to see which one).",
            ] + numbered(ResponsibleProcessFormatter.hostAttributedRemedy(
                setupCommand: setupHint, settingsPane: type, alsoEnable: nil)))
                .joined(separator: "\n")
        case nil:
            return """
            \(type) access denied. Please grant permission:
            1. Open System Settings → Privacy & Security → \(type)
            2. Enable access for CheICalMCP, or for the process macOS checks here \
            (run `CheICalMCP --print-tcc-path` to see which one)
            3. Or grant this exact binary access by running its setup from Terminal: \
            \(setupHint)
            4. Restart Claude Desktop/Code
            """
        }
    }

    private static func numbered(_ steps: [String]) -> [String] {
        steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
    }

    /// Whether the current status of `typeName`'s service is `.restricted` (#343 verify
    /// round 2, row 9). The gate reports `.denied` and `.restricted` alike as `deniedByStatus`;
    /// the message reads which one at message time, the same way it reads the attribution.
    static func currentStatusIsRestricted(typeName: String) -> Bool {
        let entity: EKEntityType = typeName == "Reminders" ? .reminder : .event
        return EKEventStore.authorizationStatus(for: entity) == .restricted
    }

    /// The kind of process macOS checks for this server (#343), or `nil` when the kernel
    /// lookup is unavailable. Read at message time — cheap, and it reflects the re-exec.
    static func currentAttribution() -> ResponsibleHostKind? {
        guard case .resolved(let process) = LiveResponsibleProcessSource().responsibleProcess(for: getpid()) else {
            return nil
        }
        return process.kind
    }

    /// Per-call TCC status check for Calendar. Replaces legacy `requestCalendarAccess()`
    /// which cached the granted state in `hasCalendarAccess` and silently failed on
    /// any subsequent revoke. See `AuthorizationGate.ensureAccess` for the switch logic.
    ///
    /// Threads SSH / non-interactive session context into the gate so `EventKitError.accessDenied`
    /// surfaces with the appropriate context-specific workaround text. (#113, #144)
    func ensureCalendarAccess() async throws {
        try await AuthorizationGate.ensureAccess(
            for: .event,
            typeName: "Calendar",
            isSSH: Self.isSSHSession,
            isNonInteractive: Self.isNonInteractiveSession,
            probe: authorizationSource
        )
    }

    /// Per-call TCC status check for Reminders. Counterpart of `ensureCalendarAccess()`.
    /// Threads SSH / non-interactive context (#113, #144) — same reasoning as `ensureCalendarAccess`.
    func ensureReminderAccess() async throws {
        try await AuthorizationGate.ensureAccess(
            for: .reminder,
            typeName: "Reminders",
            isSSH: Self.isSSHSession,
            isNonInteractive: Self.isNonInteractiveSession,
            probe: authorizationSource
        )
    }

    // MARK: - Refresh Management

    /// Refresh EventKit sources if needed (called before read operations)
    func refreshIfNeeded() {
        if needsRefresh {
            eventStore.refreshSourcesIfNecessary()
            needsRefresh = false
        }
    }

    /// Mark that EventKit sources need to be refreshed (called after write operations)
    func markNeedsRefresh() {
        needsRefresh = true
        refreshMarks &+= 1
    }

    private var refreshMarks = 0

    /// #328 (PR #413 verify r1 and security review): moves with every commit made through this
    /// manager's store, in the same synchronous step as the commit (`CountingEventStore`), and with
    /// every `markNeedsRefresh` (a few reads too, which only makes the check refuse more often).
    /// `deleteCalendar(requireEmpty:)` compares it across its one suspension, so a write committed
    /// during it is seen even when its writer marks the store stale later (in a `defer`, or after
    /// its own `await`).
    var writeGeneration: Int { eventStore.commitCount &+ refreshMarks }

    // MARK: - Calendars

    /// Find a calendar by name and optional source
    /// - Parameters:
    ///   - name: Calendar name
    ///   - source: Optional source name (e.g., "iCloud", "Google", "Exchange")
    ///   - entityType: Calendar type (.event or .reminder)
    /// - Returns: The matching calendar
    /// - Throws: calendarNotFound if not found, multipleCalendarsFound if ambiguous
    func findCalendar(
        name: String,
        source: String?,
        entityType: EKEntityType
    ) throws -> EKCalendar {
        let allCalendars = eventStore.calendars(for: entityType)

        // Exact, then ignoring case (#437: one rule, shared with find_duplicate_events).
        let calendars = CalendarNameMatch.matching(allCalendars, name: name, source: source,
                                                   title: { $0.title }, sourceTitle: { $0.source.title })

        if calendars.isEmpty {
            let available = allCalendars.map { "\($0.title) (\($0.source.title))" }
            if let source = source {
                throw EventKitError.calendarNotFoundWithSource(name: name, source: source, available: available)
            } else {
                throw EventKitError.calendarNotFound(identifier: name, available: available)
            }
        }

        if calendars.count > 1 {
            let sources = calendars.map { $0.source.title }.joined(separator: ", ")
            throw EventKitError.multipleCalendarsFound(name: name, sources: sources)
        }

        return calendars[0]
    }

    /// Find calendars by name and optional source (returns array for filtering)
    /// - Parameters:
    ///   - name: Calendar name
    ///   - source: Optional source name
    ///   - entityType: Calendar type
    /// - Returns: Array of matching calendars (may be empty)
    func findCalendars(
        name: String,
        source: String?,
        entityType: EKEntityType
    ) throws -> [EKCalendar] {
        let allCalendars = eventStore.calendars(for: entityType)

        // Exact, then ignoring case (#437: one rule, shared with find_duplicate_events).
        let calendars = CalendarNameMatch.matching(allCalendars, name: name, source: source,
                                                   title: { $0.title }, sourceTitle: { $0.source.title })

        if calendars.isEmpty {
            let available = allCalendars.map { "\($0.title) (\($0.source.title))" }
            if let source = source {
                throw EventKitError.calendarNotFoundWithSource(name: name, source: source, available: available)
            } else {
                throw EventKitError.calendarNotFound(identifier: name, available: available)
            }
        }

        if calendars.count > 1 && source == nil {
            let sources = calendars.map { $0.source.title }.joined(separator: ", ")
            throw EventKitError.multipleCalendarsFound(name: name, sources: sources)
        }

        return calendars
    }

    func listCalendars(for entityType: EKEntityType? = nil) async throws -> [EKCalendar] {
        if entityType == .event || entityType == nil {
            try await ensureCalendarAccess()
        }
        if entityType == .reminder || entityType == nil {
            try await ensureReminderAccess()
        }
        refreshIfNeeded()

        if let type = entityType {
            return eventStore.calendars(for: type)
        } else {
            let eventCalendars = eventStore.calendars(for: .event)
            let reminderCalendars = eventStore.calendars(for: .reminder)
            return eventCalendars + reminderCalendars
        }
    }

    struct CreateCalendarResult {
        let calendar: EKCalendar
        let isDuplicate: Bool
        /// #261: compared fields a new store holds differently after a save that threw but
        /// committed (`NewObjectSave.run`); empty otherwise.
        let storeDiffers: [String]
    }

    func createCalendar(title: String, entityType: EKEntityType, color: String? = nil) async throws -> CreateCalendarResult {
        if entityType == .event {
            try await ensureCalendarAccess()
        } else {
            try await ensureReminderAccess()
        }

        // Idempotency: check for existing calendar with same title and type
        let existing = eventStore.calendars(for: entityType).first { $0.title == title }
        if let existing = existing {
            return CreateCalendarResult(calendar: existing, isDuplicate: true, storeDiffers: [])
        }

        let calendar = EKCalendar(for: entityType, eventStore: eventStore)
        calendar.title = title

        // Set source (use default source)
        if entityType == .event {
            calendar.source = eventStore.defaultCalendarForNewEvents?.source
        } else {
            calendar.source = eventStore.defaultCalendarForNewReminders()?.source
        }

        // Set color if provided
        if let colorHex = color {
            calendar.cgColor = parseColor(colorHex)
        }

        // #261: a reminder list whose save failed may stay pending and be written by the next
        // save, so it is discarded when a new store does not find it; when it finds it, it was
        // saved, and it is returned as created. When that store cannot answer, the list is kept and
        // the call fails with `saveUnchecked` (#289: a create has no undo that removes it; #273's
        // marker, recorded by `writeNewCalendar` after a create that returned, removes nothing either). An event
        // calendar is saved as before: in the failure classes tried, a failed one was not written
        // by a later save (see NewObjectSave).
        var storeDiffers: [String] = []
        if NewObjectSave.keepsFailedInsert(entityType) {
            storeDiffers = try NewObjectSave.run(save: { try eventStore.saveCalendar(calendar, commit: true) },
                                  committed: { NewObjectSave.freshStoreFinds(NewObjectSave.listCheck(calendar)) },
                                  onNoAnswer: .keep,
                                  discard: { try eventStore.removeCalendar(calendar, commit: false) },
                                  report: { Self.logNewObjectOutcome(handler: "createCalendar", identifier: calendar.calendarIdentifier, $0) })
        } else {
            try eventStore.saveCalendar(calendar, commit: true)
        }
        markNeedsRefresh()
        return CreateCalendarResult(calendar: calendar, isDuplicate: false, storeDiffers: storeDiffers)
    }

    func updateCalendar(
        identifier: String,
        title: String? = nil,
        color: String? = nil
    ) async throws -> EKCalendar {
        try await ensureCalendarAccess()
        try await ensureReminderAccess()

        guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
            throw EventKitError.calendarNotFound(identifier: identifier)
        }
        guard calendar.allowsContentModifications else {
            // #37 verify (Codex high finding): never interpolate `calendar.title`
            // into trusted-path errors — the title comes from CalendarStore and
            // includes shared/subscribed calendars whose names are remote-set
            // (#21/#27 threat class). Echo the caller's own `identifier` and
            // mark the read-only state via author-controlled text.
            throw EventKitError.calendarNotFound(identifier: "\(identifier) (read-only)")
        }

        // #273: the title before the rename, for the marker's listing.
        let titleBefore = calendar.title
        if let t = title { calendar.title = t }
        if let c = color { calendar.cgColor = parseColor(c) }

        try saveExistingCalendar(calendar)   // #274
        markNeedsRefresh()
        await CalendarUndoManager.shared.record(.calendarOperation(kind: .updated, title: titleBefore))
        return calendar
    }

    /// #328: with `requireEmpty`, the calendar is checked first: events over the stated window
    /// (`CalendarEmptiness.checkEvents`), reminders whole (`checkReminders`); a non-empty one, or one
    /// that cannot be counted, is refused and nothing is deleted. The event check runs on this actor
    /// with no suspension; the one suspension is the reminder fetch, across which the write
    /// generation is compared, so no write by this server process lands between the check and
    /// `removeCalendar` (PR #413 verify r1), except one that failed earlier and is still pending
    /// (#274, `ExistingReminderSave`), which the check does not see and which the removal may commit
    /// (not measured). A write by another app or a sync can still land in between: EventKit offers
    /// no way to delete a calendar only if it is empty.
    @discardableResult
    func deleteCalendar(identifier: String, requireEmpty: Bool = false) async throws -> CalendarEmptiness.Checked? {
        try await ensureCalendarAccess()
        try await ensureReminderAccess()

        guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
            throw EventKitError.calendarNotFound(identifier: identifier)
        }
        // #273: the title for the marker's listing, read before the removal.
        let title = calendar.title

        var checked: CalendarEmptiness.Checked?
        if requireEmpty {
            // As the other read paths: a write this server made is seen (PR #413 round 2).
            refreshIfNeeded()
            let generation = writeGeneration
            try CalendarEmptiness.checkKinds(holdsEvents: calendar.allowedEntityTypes.contains(.event),
                                             holdsReminders: calendar.allowedEntityTypes.contains(.reminder))
            var searched: EventRangeQuery.Span?
            if calendar.allowedEntityTypes.contains(.event) {
                let window = CalendarEmptiness.window(now: Date())
                // Each probe query is at most 1459 days + 1 s (`CalendarEmptiness.probeSpanDays`), so
                // `events(from:to:calendars:)` (the one path a range reaches EventKit by, #325) runs
                // one query for it.
                try CalendarEmptiness.checkEvents(window: window, count: { try events(from: $0, to: $1, calendars: [calendar]).count })
                searched = window
            }
            var reminders: Int?
            if calendar.allowedEntityTypes.contains(.reminder) {
                let counted = await countReminders(in: calendar)
                try CalendarEmptiness.checkReminders(counted: counted, generationBefore: generation, generationAfter: writeGeneration)
                reminders = 0
            }
            // An events read cannot tell a failure from an empty calendar (`events(matching:)`
            // answers [] either way); a calendar that no longer resolves after the reads is refused,
            // since its reads may have answered nothing for that reason (PR #413 round 2).
            guard eventStore.calendar(withIdentifier: identifier) != nil else {
                throw EventKitError.calendarNotEmpty(reason: CalendarEmptiness.calendarGoneMessage)
            }
            checked = CalendarEmptiness.Checked(searched: searched, reminders: reminders)
        }

        try removeExistingCalendar(calendar)   // #274
        markNeedsRefresh()
        // #273: a marker, so that undo after this does not revert an older operation in its place.
        await CalendarUndoManager.shared.record(.calendarOperation(kind: .deleted, title: title))
        return checked
    }

    /// The number of reminders in `calendar`, completed ones included; nil when the fetch returns
    /// nothing (it failed), which the check refuses (PR #413 verify r1).
    private func countReminders(in calendar: EKCalendar) async -> Int? {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: eventStore.predicateForReminders(in: [calendar])) { reminders in
                continuation.resume(returning: reminders?.count)
            }
        }
    }

    // MARK: - Events

    struct CreateEventResult {
        let event: EKEvent
        let isDuplicate: Bool
    }

    /// Find an existing event that matches by title and start date on the same calendar.
    /// Used for idempotency checks to prevent duplicate event creation.
    private func findDuplicateEvent(
        title: String,
        startDate: Date,
        isAllDay: Bool,
        calendar: EKCalendar
    ) -> EKEvent? {
        // Search within a 1-minute window around the start date
        let searchStart = startDate.addingTimeInterval(-30)
        let searchEnd = startDate.addingTimeInterval(30)
        let predicate = eventStore.predicateForEvents(
            withStart: searchStart,
            end: searchEnd,
            calendars: [calendar]
        )
        let events = eventStore.events(matching: predicate)
        return events.first {
            Self.isCreateDuplicate(title: title, start: startDate, isAllDay: isAllDay,
                                   candidateTitle: $0.title, candidateStart: $0.startDate,
                                   candidateAllDay: $0.isAllDay)
        }
    }

    /// Whether an event found around the start counts as the one `create_event` was asked to make.
    /// #364 verify round 1: an all-day create's start is midnight after normalization, and a
    /// same-titled all-day event on the previous day (ending 23:59:59) overlaps the search window,
    /// so for an all-day create only an all-day event starting at the same instant matches.
    /// Round 2: a timed create matches only a timed event, since every all-day event on that day
    /// overlaps the window too.
    static func isCreateDuplicate(
        title: String, start: Date, isAllDay: Bool,
        candidateTitle: String?, candidateStart: Date?, candidateAllDay: Bool
    ) -> Bool {
        guard candidateTitle == title else { return false }
        guard isAllDay else { return !candidateAllDay }
        return candidateAllDay && candidateStart == start
    }

    func listEvents(
        startDate: Date,
        endDate: Date,
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) async throws -> [EKEvent] {
        try await ensureCalendarAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        return try events(from: startDate, to: endDate, calendars: calendars)
    }

    /// Validates that a timed event's start is strictly before its end, and that an all-day
    /// event's last day is not before its first day (#364 / #348, through `AllDayRange`; start = end
    /// is one day).
    /// Shared by `createEvent` and `updateEvent` so both reject inverted / zero-duration
    /// timed events consistently — previously only `updateEvent` guarded this, letting
    /// `createEvent` persist invalid events (#160).
    ///
    /// - Parameter hint: optional caller-specific guidance appended to the error message
    ///   (e.g. `updateEvent`'s "provide both start_time and end_time" advice).
    static func validateTimeRange(
        start: Date, end: Date, isAllDay: Bool, hint: String? = nil,
        calendar: Calendar = Calendar.gregorian(in: .current)
    ) throws {
        // #348 step 5 / #364: an all-day event is checked by its days (an end day before the start
        // day is refused; start = end is one day). It used to be exempt entirely.
        if isAllDay {
            _ = try AllDayRange.normalize(start: start, end: end, calendar: calendar)
            return
        }
        guard start >= end else { return }
        let formatter = ISO8601DateFormatter()
        var message = "Start time (\(formatter.string(from: start))) must be before end time (\(formatter.string(from: end)))."
        if let hint { message += " " + hint }
        throw EventKitError.invalidTimeRange(message: message)
    }

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        location: String? = nil,
        url: String? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        isAllDay: Bool = false,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        structuredLocation: StructuredLocationInput? = nil,
        timezone: TimeZone? = nil
    ) async throws -> CreateEventResult {
        try await ensureCalendarAccess()

        // Reject inverted / zero-duration timed events (symmetric with updateEvent — #160).
        try Self.validateTimeRange(start: startDate, end: endDate, isAllDay: isAllDay)

        // #364 / #348: an all-day pair is written as (start of the first day, last day 23:59:59),
        // so the reading does not depend on the order of assignments below, and the duplicate
        // check keys on the day rather than on a time of day.
        let (startDate, endDate) = isAllDay
            ? try AllDayRange.normalize(start: startDate, end: endDate, calendar: Calendar.gregorian(in: .current))
            : (startDate, endDate)

        // #190 — defense-in-depth behind the handler guard (zero mutation).
        if isAllDay, timezone != nil {
            throw EventKitError.allDayTimezoneConflict
        }

        // #182 — pre-save exclusion window check (zero mutation): every excluded
        // date must fall AFTER the first occurrence day (excluding DTSTART itself is
        // rejected — verify finding #5) and within end_date / occurrence_count bounds.
        if let rule = recurrenceRule, let excluded = rule.excludedOccurrenceDates, !excluded.isEmpty {
            try Self.validateExclusionWindow(excluded: excluded, startDate: startDate, rule: rule, timezone: timezone)
        }

        // Resolve calendar first (required for both duplicate check and creation)
        guard let name = calendarName else {
            throw EventKitError.calendarNameRequired(forType: "events")
        }
        let calendar = try findCalendar(name: name, source: calendarSource, entityType: .event)

        // Idempotency: check for existing event with same title + start time on same calendar
        if let existing = findDuplicateEvent(title: title, startDate: startDate, isAllDay: isAllDay, calendar: calendar) {
            // #182 — idempotency with exclusions: identical retry (every requested
            // date already absent from the existing series) → skipped; any requested
            // date still present → conflict (differing exclusion set). Extra
            // exclusions on the existing series are NOT detected — documented limitation.
            if let rule = recurrenceRule, let excluded = rule.excludedOccurrenceDates, !excluded.isEmpty,
               let existingId = existing.eventIdentifier {
                // Verify finding #8 — absence != exclusion: a non-recurring existing
                // event trivially has no occurrence on any future date, which would
                // read as "already excluded". Require a recurring existing series
                // before the absence check can mean anything.
                guard existing.hasRecurrenceRules else {
                    throw EventKitError.exclusionConflict(
                        existingId: existingId,
                        date: Self.formatExclusionDay(excluded[0], timezone: timezone))
                }
                // Verify finding #7 — request timezone first: the requested dates were
                // normalized in the request timezone; probing day windows in a
                // different zone can hit the wrong calendar day (false skipped).
                let tz = timezone ?? existing.timeZone
                for date in excluded {
                    if findOccurrence(identifier: existingId, on: date, in: tz) != nil {
                        throw EventKitError.exclusionConflict(
                            existingId: existingId,
                            date: Self.formatExclusionDay(date, timezone: tz))
                    }
                }
            }
            return CreateEventResult(event: existing, isDuplicate: true)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.isAllDay = isAllDay
        event.calendar = calendar

        if let urlString = url, let eventURL = URL(string: urlString) {
            event.url = eventURL
        }

        // Set per-event timezone (#12)
        if let tz = timezone {
            event.timeZone = tz
        }

        // Add alarms
        if let offsets = alarmOffsets {
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                event.addAlarm(alarm)
            }
        }

        // Validate recurrence: start_time weekday must match days_of_week (#5)
        // Use event timezone (if provided) to determine the correct weekday near midnight
        // #454: every frequency uses the list, and a start off it is a stray first occurrence.
        if let refusal = WeekdayCheck.createRefusal(rule: recurrenceRule, start: startDate, timezone: timezone, host: Calendar.current) {
            throw refusal
        }
        // #461: the same for days_of_month on a monthly or yearly rule.
        if let refusal = MonthDayCheck.createRefusal(rule: recurrenceRule, start: startDate, timezone: timezone, host: Calendar.current) {
            throw refusal
        }

        // Add recurrence rule
        if let rule = recurrenceRule {
            event.recurrenceRules = [createRecurrenceRule(from: rule)]
        }

        // Set structured location (overrides location text if both provided)
        if let loc = structuredLocation {
            let structured = EKStructuredLocation(title: loc.title)
            if let lat = loc.latitude, let lon = loc.longitude {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            if let radius = loc.radius, radius > 0 {
                structured.radius = radius
            }
            event.structuredLocation = structured
        }

        // #261: no discard; in the failure classes tried on device, a failed new event was not
        // written by a later save (see NewObjectSave).
        try eventStore.save(event, span: .thisEvent)

        // #182 — two-pass exclusion (resolve all → remove all); any failure
        // compensating-deletes the just-created series. The undo record moves
        // AFTER the exclusion pass so (a) one undo removes the whole series and
        // (b) the rollback path leaves no stale entry on the stack. Calls without
        // exclusions keep the pre-#182 record-after-save semantics unchanged.
        if let rule = recurrenceRule, let excluded = rule.excludedOccurrenceDates, !excluded.isEmpty {
            try applyExclusions(to: event, dates: excluded, timezone: timezone)
        }
        markNeedsRefresh()
        let createdID = event.eventIdentifier ?? ""
        await CalendarUndoManager.shared.record(.createEvent(id: createdID, title: event.title ?? title,
                                                             created: postWriteSnapshot(eventID: createdID, saved: event)))
        return CreateEventResult(event: event, isDuplicate: false)
    }

    /// #182 — pre-save exclusion window validation. Static + EventKit-free so CI can
    /// exercise it directly (the createEvent call path fast-fails at
    /// `ensureCalendarAccess` under CI=1 before reaching this).
    static func validateExclusionWindow(excluded: [Date], startDate: Date, rule: RecurrenceRuleInput, timezone: TimeZone?) throws {
        var cal = Calendar.current
        if let tz = timezone { cal.timeZone = tz }
        let firstDay = cal.startOfDay(for: startDate)

        // Coarse occurrence_count upper bound (spec clause (c)) — DAILY/WEEKLY ONLY.
        // For those the stride is exact (interval days / interval*7 days; days_of_week
        // only shortens the span), so (count-1)*interval*period is a strict loose
        // bound that never false-rejects. Monthly/yearly have no cheap loose bound
        // (days_of_month=[31] skips months; Feb-29 yearly skips years — R2 finding),
        // so the count bound is NOT applied there; end_date still is. Overflow-safe:
        // an overflowing product simply drops the bound (huge counts bound nothing).
        var lastDayBound: Date? = rule.endDate.map { cal.startOfDay(for: $0) }
        if let count = rule.occurrenceCount, count > 0 {
            let periodDays: Int?
            switch rule.frequency {
            case .daily: periodDays = 1
            case .weekly: periodDays = 7
            case .monthly, .yearly: periodDays = nil
            }
            if let period = periodDays {
                let (step, o1) = (count - 1).multipliedReportingOverflow(by: max(rule.interval, 1))
                let (spanDays, o2) = o1 ? (0, true) : step.multipliedReportingOverflow(by: period)
                if !o1, !o2, let countBound = cal.date(byAdding: .day, value: spanDays, to: firstDay) {
                    lastDayBound = lastDayBound.map { min($0, countBound) } ?? countBound
                }
            }
        }

        for date in excluded {
            let day = cal.startOfDay(for: date)
            if day == firstDay {
                throw EventKitError.exclusionFirstOccurrence(date: Self.formatExclusionDay(date, timezone: timezone))
            }
            if day < firstDay || (lastDayBound.map { day > $0 } ?? false) {
                throw EventKitError.exclusionOutOfWindow(date: Self.formatExclusionDay(date, timezone: timezone))
            }
        }

        // Verify finding #6 — the whole series must not be emptied out. Checked AFTER
        // the per-date window pass (R2 note 3): only dates proven in-window can
        // truthfully claim to remove every occurrence; an out-of-window date gets the
        // more accurate out-of-window / first-occurrence error above instead.
        if let count = rule.occurrenceCount, count > 0, excluded.count >= count {
            throw EventKitError.exclusionRemovesAllOccurrences(excludedCount: excluded.count, occurrenceCount: count)
        }
    }

    /// #182 — day formatter for exclusion error messages and response payloads
    /// (normalized `yyyy-MM-dd` in the event timezone).
    static func formatExclusionDay(_ date: Date, timezone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let tz = timezone { formatter.timeZone = tz }
        return formatter.string(from: date)
    }

    /// #182 — exclusion execution: maps the neutral `ExclusionExecutor` failures
    /// onto `EventKitError` with formatted dates and the master event ID.
    private func applyExclusions(to event: EKEvent, dates: [Date], timezone: TimeZone?) throws {
        guard let masterId = event.eventIdentifier else {
            // Pathological: saved event with no identifier — roll back and report.
            do {
                try eventStore.remove(event, span: .futureEvents)
                markNeedsRefresh()
            } catch {
                throw EventKitError.exclusionRollbackFailed(masterId: "(unknown)", appliedDates: [])
            }
            throw EventKitError.exclusionNoOccurrence(date: "(series has no identifier)")
        }
        do {
            _ = try ExclusionExecutor.run(
                dates: dates,
                resolve: { self.findOccurrence(identifier: masterId, on: $0, in: timezone) },
                remove: { try self.eventStore.remove($0, span: .thisEvent) },
                rollback: {
                    try self.eventStore.remove(event, span: .futureEvents)
                    self.markNeedsRefresh()
                }
            )
        } catch let error as ExclusionExecutionError {
            markNeedsRefresh()
            switch error {
            case .noOccurrence(let date):
                throw EventKitError.exclusionNoOccurrence(date: Self.formatExclusionDay(date, timezone: timezone))
            case .removeFailed(let date):
                throw EventKitError.exclusionRemoveFailed(date: Self.formatExclusionDay(date, timezone: timezone))
            case .rollbackFailed(let applied):
                throw EventKitError.exclusionRollbackFailed(
                    masterId: masterId,
                    appliedDates: applied.map { Self.formatExclusionDay($0, timezone: timezone) })
            }
        }
    }

    /// The fixed reason for refusing a whole-series save from the stand-in (#326).
    private static let standInSplitReason = "This series' first occurrence was deleted, so updating it from its first remaining occurrence would split it into a new series with a new event id. Update a single occurrence after the first remaining one with occurrence_date and span 'this'."

    /// The fixed hint for a bare id that is listed but cannot be acted on as a whole series (#335).
    /// What reaches such a series, with its condition: without one this text pointed back to a call
    /// that is refused in the same shape (PR #431 round 6). `update_event` and `delete_event` with
    /// span `all` get here no more when the first occurrence was edited (#428): they go through
    /// that occurrence. Span `future` and the batch do, and so does a series whose first left is
    /// not edited, which the text's condition leaves out (verify r1: it named only the old routes).
    private static let editedBeforeWays = "When the occurrence that comes first in the series was edited on its own and its start is not later than any other occurrence's original or shown start, update_event and delete_event with span 'all' through the series' id go through it: update_event writes the fields its description lists for such an occurrence, and delete_event deletes every occurrence, which cannot be undone. Otherwise (it starts later than another occurrence, or its identifier does not name it as an occurrence of this series) nothing else updates or deletes the series as a whole yet. A write from a date on through the series' id has no tested way yet; span 'future' through the id of a later occurrence edited on its own takes title, notes, location and recurrence."

    static let standInEditedBeforeReason = "This series' first occurrence was deleted or edited on its own, with an occurrence edited on its own before the rest, so this call cannot act on the series as a whole or from a date on. You can delete or update a single occurrence with occurrence_date and span 'this', move the series within its account, or copy one of its occurrences (a copy is a single event, not a series). \(editedBeforeWays)"
    /// #335 item 6: `standInEditedBeforeReason` as a `delete_events_batch` row (and its `dry_run`
    /// by `event_ids`) reports it. That tool by `event_ids` cannot take an `occurrence_date`, so the
    /// text names the ways a batch caller has to a single occurrence instead.
    static let standInEditedBeforeBatchReason = "This series' first occurrence was deleted or edited on its own, with an occurrence edited on its own before the rest, so this call cannot act on the series as a whole or from a date on, and delete_events_batch by event_ids cannot name a single occurrence. To delete single occurrences, use delete_event with occurrence_date and span 'this', or this tool by calendar_name and a date range with span 'this'. \(editedBeforeWays)"

    /// #335 item 6: a reason as a batch row reports it: the edited-before hint becomes
    /// `standInEditedBeforeBatchReason`; every other reason (the all-edited hint, whose `/RID=` ids
    /// work in `event_ids` too, and "Event not found") is unchanged.
    static func batchRowReason(_ reason: String) -> String {
        reason == standInEditedBeforeReason ? standInEditedBeforeBatchReason : reason
    }

    /// `batchRowReason` for an error a batch row reports through `writeFailureLog` (the `dry_run`
    /// preview by `event_ids`); other errors pass through.
    static func batchRowError(_ error: Error) -> Error {
        if case EventKitError.standInRefused(let reason) = error {
            return EventKitError.standInRefused(reason: batchRowReason(reason))
        }
        return error
    }

    /// The fixed hint for a bare id of a series whose remaining occurrences were all edited on
    /// their own (#335 item 1; device, iCloud, 2026-10-26: the bare id is not found even with
    /// `occurrence_date`, while the id `list_events` gives an occurrence updates that one).
    static let standInAllEditedReason = "This series' first occurrence was deleted or edited on its own, and the occurrences found for it (within about four years of its start) were all edited on their own, so the series id reaches none of them, except update_event and delete_event with span 'all', which go through the earliest of them when it was edited on its own and its start is not later than any other occurrence's original or shown start. Otherwise (it starts later than another occurrence, or its identifier does not name it as an occurrence of this series) only single occurrences can be updated or deleted. Use the id that list_events shows for an occurrence (it ends in /RID=...) to update or delete that one occurrence."
    /// The fixed reason for refusing a change of account through the stand-in (#326).
    private static let standInAccountReason = "This series' first occurrence was deleted, so moving the whole series to a calendar of another account (a create plus a delete from its first remaining occurrence) is not supported. Move it within the same account, or move a single occurrence with its occurrence date and span 'this'."
    /// The fixed reason for refusing the undo of a whole-series move whose way back goes through
    /// the stand-in to another account (#369). The record is kept, as every refusal outside the
    /// spec's discard scenarios is (`undo-history-discard`).
    static let standInUndoAccountReason = "Cannot undo the move: this series' first occurrence was deleted, so moving the whole series back to its original calendar in another account (a create plus a delete from its first remaining occurrence) is not supported. Nothing was written and this history entry was kept. Move the series back in Calendar, or move single occurrences with their occurrence date and span 'this'; then ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."
    /// The fixed reason for refusing a series-level update (calendar of another account,
    /// recurrence rules) through the stand-in (#326).
    private static let standInSeriesPropertyReason = "This series' first occurrence was deleted or edited on its own, so changing its calendar to one of another account, or its recurrence, from the occurrence that stands in for the series is not supported."

    /// #268 (PR #387 verify round 4): an edit of one occurrence (span this) with a calendar of
    /// another account. A new calendar moves the whole series even with span this (device), and a
    /// cross-account move gives it a new identifier (#226), which this server cannot read back
    /// reliably from an occurrence save and which was not checked on a device; the call is refused
    /// before any field is written. A calendar whose account cannot be read counts as another
    /// account (`FirstRemainingOccurrence.movesAcrossAccounts`), as for the stand-in refusal.
    static func refusesOccurrenceEditAcrossAccounts(onOccurrence: Bool, span: EKSpan, crossesAccounts: Bool) -> Bool {
        onOccurrence && span == .thisEvent && crossesAccounts
    }

    /// #288: fixed text, no EventKit text. It does not say not found, and it says not to recreate.
    static let eventLookupFailedReason = "The event lookup failed, so this event may still exist. Do not create it again; try again, and restart the server if this keeps happening"
    /// PR #439 verify: the rule belongs to the series. Measured on iCloud: a rule saved on one
    /// occurrence (span this) left that occurrence as a one-off and deleted the rest of the series,
    /// answering `updated`; clear_recurrence there detached the occurrence and left the series
    /// repeating. Span all changes the rule and a rule with span future changes it from that
    /// occurrence on, so only span this is refused. A one-off event gaining a rule is not an
    /// occurrence.
    static func refusesRecurrenceChangeOnOccurrence(onOccurrence: Bool, span: EKSpan, changesRecurrence: Bool) -> Bool {
        onOccurrence && span == .thisEvent && changesRecurrence
    }

    /// PR #439 verify round 2, measured on iCloud and on v1.22.0: clear_recurrence with
    /// occurrence_date and span future left one event on the series' first day, of ten, deleting
    /// the occurrences before the one named as well, and answered `updated`. `onOccurrenceObject`
    /// is true for an object found by occurrence_date only: span all saves the series object, which
    /// is what clearing means, and an occurrence's own id is the object it resolved to.
    static func refusesClearRecurrenceFromOccurrence(onOccurrenceObject: Bool, span: EKSpan, clearRecurrence: Bool) -> Bool {
        onOccurrenceObject && span == .futureEvents && clearRecurrence
    }

    /// How a refused rule change named the event, for the message: span 'all' and span 'future' on
    /// an occurrence's own id take another path, so that caller is told the series' id instead.
    enum RecurrenceChangeAddress: Equatable, Sendable {
        case seriesId
        /// `series` is nil when the id does not show it (only iCloud's `/RID=` shape does).
        case occurrenceOwnId(series: String?)
    }

    static func recurrenceChangeAddress(identifier: String, isDetached: Bool, viaStandIn: Bool) -> RecurrenceChangeAddress {
        // A stand-in may be an edited occurrence, but the caller named the series.
        guard isDetached, !viaStandIn else { return .seriesId }
        return .occurrenceOwnId(series: UpdatedIdentifier.seriesOfOccurrenceId(identifier))
    }

    static let occurrenceAcrossAccountsReason = "Moving to a calendar in another account moves the whole series, so it cannot be combined with an edit of one occurrence (occurrence_date with span 'this'). To move the series, call update_event with span 'all' and no occurrence_date, or move_events_batch; to edit the occurrence, leave calendar_name out. A calendar whose account cannot be read counts as another account. Nothing was written."

    /// #426: a new calendar on one occurrence, within one account. See
    /// `refusesOccurrenceEditAcrossAccounts` for another account, which comes first.
    static func refusesCalendarOnOccurrence(onOccurrence: Bool, span: EKSpan, applyToAll: Bool, changesCalendar: Bool) -> Bool {
        onOccurrence && span == .thisEvent && !applyToAll && changesCalendar
    }

    static let occurrenceCalendarReason = "A new calendar on one occurrence moves the whole series, so it cannot be combined with an edit of one occurrence. To move the series, use move_events_batch with span 'all'. To move this occurrence alone, use move_events_batch with its occurrence_dates and span 'this', which copies it out of the series as a single event. To edit the occurrence, leave calendar_name out. Nothing was written."

    func updateEvent(
        identifier: String,
        fields: Set<String>,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        notes: String? = nil,
        location: String? = nil,
        url: String? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        isAllDay: Bool? = nil,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        clearRecurrence: Bool = false,
        structuredLocation: StructuredLocationInput? = nil,
        span: EKSpan = .thisEvent,
        occurrenceDate: Date? = nil,
        applyToAll: Bool = false,
        timezone: TimeZone? = nil,
        clearTimezone: Bool = false
    ) async throws -> (event: EKEvent, seriesIdentifier: String?, matchedOccurrence: MatchedOccurrence?) {
        try await ensureCalendarAccess()

        // #236 (PR #259 verify #5): refreshed, so the snapshot undo restores is not a stale copy
        // that would write back over an edit made elsewhere before this call.
        guard let resolved = try freshEventWithOrigin(
            id: identifier,
            refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span, wholeSeries: applyToAll)) else {
            // #428: the series reaches no stand-in, and its first occurrence was edited on its own:
            // the same write through that occurrence's own id, which answers for the series.
            if applyToAll, let first = try firstEditedOccurrenceID(of: identifier) {
                let saved: (event: EKEvent, seriesIdentifier: String?, matchedOccurrence: MatchedOccurrence?)
                do {
                    saved = try await updateEvent(
                        identifier: first.id, fields: fields, title: title, startDate: startDate, endDate: endDate, notes: notes,
                        location: location, url: url, calendarName: calendarName, calendarSource: calendarSource, isAllDay: isAllDay,
                        alarmOffsets: alarmOffsets, recurrenceRule: recurrenceRule, clearRecurrence: clearRecurrence,
                        structuredLocation: structuredLocation, span: span, occurrenceDate: occurrenceDate, applyToAll: applyToAll,
                        timezone: timezone, clearTimezone: clearTimezone)
                } catch EventKitError.occurrenceAddressRefused(let reason) {
                    // verify r2: the occurrence's texts speak to a caller who named it.
                    throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.throughSeriesID(reason, allEdited: first.allEdited, firstDeleted: first.firstDeleted))
                } catch EventKitError.seriesWriteRefused(let reason) {
                    // verify r7/r8: #451's texts name span future with occurrence_date, not offered here;
                    // only that sentence is replaced.
                    throw EventKitError.seriesWriteRefused(reason: DetachedOccurrenceSpan.throughSeriesIDStartedRule(reason, allEdited: first.allEdited))
                }
                return (saved.event, UpdatedIdentifier.seriesThroughOccurrence(saved: saved.event.eventIdentifier), saved.matchedOccurrence)
            }
            throw notFoundError(id: identifier)
        }
        let masterEvent = resolved.event
        // Read once: the #416 refusal below and the #451 checks use it (PR #471 verify).
        let addressesOwnOccurrence = (applyToAll || span == .futureEvents)
            && DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: masterEvent.isDetached)
        let ownNeighbours = addressesOwnOccurrence ? try occurrenceNeighbours(of: masterEvent, id: identifier) : nil
        // #416: through an occurrence edited on its own, span 'all' or 'future' writes only what was
        // measured to do what it says (`DetachedOccurrenceSpan`); refused before anything is read
        // into the update or written.
        if let refusal = try DetachedOccurrenceSpan.updateRefusal(
            identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll,
            futureSpan: span == .futureEvents, fields: fields,
            repeatsOccurrenceValue: DetachedOccurrenceSpan.repeatsOccurrenceValue(
                title: title, notes: notes, location: location, occurrenceTitle: masterEvent.title,
                occurrenceNotes: masterEvent.notes, occurrenceLocation: masterEvent.location),
            writesLocation: location != nil, turnsTimed: isAllDay == false,
            datesStayOnTheDay: DetachedOccurrenceSpan.datesStayOnTheDay(
                newStart: startDate, newEnd: endDate, start: masterEvent.startDate, end: masterEvent.endDate,
                zone: masterEvent.timeZone ?? .current),
            neighbours: ownNeighbours) {
            throw EventKitError.occurrenceAddressRefused(reason: refusal)
        }
        // #326: the series' first occurrence was deleted, so `masterEvent` is its first remaining
        // occurrence, and saving the whole series from it splits it into a new series with a new
        // identifier (device, iCloud). Refused rather than done silently; the other writes
        // (move, copy, delete) keep the identifier.
        if applyToAll, resolved.viaStandIn {
            throw EventKitError.standInRefused(reason: Self.standInSplitReason)
        }

        // Snapshot before update for undo
        let oldSnapshot = EventSnapshot(from: masterEvent)
        let hadRules = masterEvent.hasRecurrenceRules

        // For recurring events, resolve the specific occurrence when needed.
        // When applyToAll is true, operate on master event directly (correct for "all" series updates).
        // "this" or "future" on recurring → require occurrence_date to find the right occurrence.
        let event: EKEvent
        // #383 verify: the occurrence occurrence_date matched, read before any field is assigned,
        // reported as occurrence_start so the caller can see which day was edited.
        var matchedOccurrence: MatchedOccurrence?
        if !masterEvent.hasRecurrenceRules {
            event = masterEvent
            // #416: an occurrence's own id answers for itself, so occurrence_date has to be that
            // occurrence. It was ignored here, and the write started at the wrong one (device).
            if DetachedOccurrenceSpan.refusesOccurrenceDate(
                identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: applyToAll,
                hasOccurrenceDate: occurrenceDate != nil,
                matches: occurrenceDateMatches(occurrenceDate, occurrence: masterEvent, id: identifier)) {
                throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.occurrenceDateReason)
            }
            if occurrenceDate != nil, !applyToAll, DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: masterEvent.isDetached) {
                matchedOccurrence = MatchedOccurrence(start: masterEvent.startDate, zone: Self.occurrenceZone(of: masterEvent))
            }
        } else if applyToAll {
            // "all" = modify entire series via master event + .futureEvents
            event = masterEvent
        } else if let date = occurrenceDate {
            guard let occurrence = findOccurrence(identifier: identifier, on: date, in: Self.occurrenceZone(of: masterEvent)) else {
                throw EventKitError.eventNotFound(identifier: "\(identifier) (no occurrence on \(date))")
            }
            // Span future at the stand-in itself is the same whole-series save (verify round 3).
            if FirstRemainingOccurrence.refusesFutureUpdate(
                viaStandIn: resolved.viaStandIn, isFutureSpan: span == .futureEvents,
                occurrenceStart: occurrence.startDate, standInStart: masterEvent.startDate) {
                throw EventKitError.standInRefused(reason: Self.standInSplitReason)
            }
            matchedOccurrence = MatchedOccurrence(start: occurrence.startDate, zone: Self.occurrenceZone(of: masterEvent))
            event = occurrence
        } else {
            throw EventKitError.invalidTimeRange(
                message: "For recurring events, occurrence_date is required to identify which occurrence to modify."
            )
        }

        // #416: the same checks when occurrence_date found an edited occurrence under the series'
        // identifier, the one way to it the check above cannot see.
        if let refusal = DetachedOccurrenceSpan.resolvedOccurrenceRefusal(
            addressedByItsOwnId: event === masterEvent, resolvedIsDetached: event.isDetached,
            futureSpan: span == .futureEvents && !applyToAll, fields: fields,
            repeatsOccurrenceValue: DetachedOccurrenceSpan.repeatsOccurrenceValue(
                title: title, notes: notes, location: location, occurrenceTitle: event.title,
                occurrenceNotes: event.notes, occurrenceLocation: event.location),
            writesLocation: location != nil,
            own: UndoPostState.ownValues(ofResolved: event, series: masterEvent)) {
            throw EventKitError.occurrenceAddressRefused(reason: refusal)
        }

        // #455: it answered updated and the last occurrence went (device).
        if DetachedOccurrenceSpan.refusesClearTimezone(
            clearTimezone: clearTimezone, wholeOrFollowing: applyToAll || span == .futureEvents,
            // Cluster verify r3: the rule this call writes counts too (a count rule written in the
            // same save was the measured shape); either one with a count refuses (fail closed). Only
            // an all-day result has no zone to clear: a floating series still gets timeZone = nil.
            occurrenceCounts: (event.recurrenceRules ?? []).map { $0.recurrenceEnd?.occurrenceCount ?? 0 }
                + [recurrenceRule?.occurrenceCount ?? 0],
            hasZone: !(isAllDay ?? event.isAllDay), clearingRecurrence: clearRecurrence) {
            throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.clearTimezoneReason)
        }

        // Series-level properties through the stand-in (verify rounds 6-7), decided before the
        // first field of the event is assigned, so nothing is half-written when it throws. A new
        // calendar moves the whole series even with span this (device), so one of another account
        // is the cross-account move again; a change of the recurrence rules is series-level too.
        let newCalendar = try calendarName.map { try findCalendar(name: $0, source: calendarSource, entityType: .event) }
        // Read before any field is assigned; also tells the response (#268) not to trust the series
        // object's identifier after the save.
        // The calendar the event is already in moves nothing, even when its account cannot be read
        // (#268 final review).
        let crossesAccounts = newCalendar.map {
            $0.calendarIdentifier != event.calendar?.calendarIdentifier
                && FirstRemainingOccurrence.movesAcrossAccounts(fromSourceID: event.calendar?.source?.sourceIdentifier,
                                                                toSourceID: $0.source?.sourceIdentifier)
        } ?? false
        if FirstRemainingOccurrence.refusesUpdateThroughStandIn(
            viaStandIn: resolved.viaStandIn,
            changesAccount: crossesAccounts,
            changesRecurrence: clearRecurrence || recurrenceRule != nil) {
            throw EventKitError.standInRefused(reason: Self.standInSeriesPropertyReason)
        }
        // #268 verify round 4: an occurrence edit that would move the series to another account.
        // An occurrence addressed by its own detached id resolves as masterEvent itself; it is an
        // occurrence edit all the same (final review), as the undo classifier below counts it.
        if Self.refusesOccurrenceEditAcrossAccounts(
            onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span, crossesAccounts: crossesAccounts) {
            throw EventKitError.moveRefused(reason: Self.occurrenceAcrossAccountsReason)
        }
        // #426: within one account too. It answered updated and every occurrence moved (device), with
        // the series' id plus occurrence_date and with the occurrence's own id.
        if Self.refusesCalendarOnOccurrence(
            onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span, applyToAll: applyToAll,
            changesCalendar: newCalendar.map { $0.calendarIdentifier != event.calendar?.calendarIdentifier } ?? false) {
            throw EventKitError.moveRefused(reason: Self.occurrenceCalendarReason)
        }
        if Self.refusesRecurrenceChangeOnOccurrence(
            onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span,
            changesRecurrence: clearRecurrence || recurrenceRule != nil)
            || Self.refusesClearRecurrenceFromOccurrence(
                onOccurrenceObject: event !== masterEvent, span: span, clearRecurrence: clearRecurrence) {
            throw EventKitError.recurrenceChangeOnOccurrenceRefused(
                clearing: clearRecurrence,
                address: Self.recurrenceChangeAddress(identifier: identifier, isDetached: masterEvent.isDetached,
                                                      viaStandIn: resolved.viaStandIn))
        }

        // #373 verify (PR #379): every check that can refuse the update runs here, before the first
        // field of the event is assigned. A refusal after an assignment left the rejected values on
        // the cached EKEvent, where a later save in the same process could write them.
        //
        // Dates: decided from the state the event will be in after this update (#364 T3), checked
        // with the shared guard (#160), and for an all-day result normalized to whole days (#364 /
        // #348). When only the start changes, a timed event keeps its duration and an all-day event
        // its number of days.
        let datePlan = try AllDayRange.planUpdate(
            storedStart: event.startDate, storedEnd: event.endDate, storedAllDay: event.isAllDay,
            newStart: startDate, newEnd: endDate, requestedAllDay: isAllDay,
            calendar: Calendar.gregorian(in: .current))

        // #190 — resolved-state check: whether all-day came from this request or
        // the stored event, pairing it with a non-nil timezone strips the flag.
        // clear_timezone remains legal (nil-ing the tz of an all-day event is fine).
        // The plan's flag is the one the event ends with (requested, else stored).
        if datePlan.isAllDay, timezone != nil, !clearTimezone {
            throw EventKitError.allDayTimezoneConflict
        }

        // #451: what the write covers, from the original slots (an edited occurrence shows another
        // time). Through an occurrence's own id the object found is that occurrence, so whether it
        // is the first comes from the series' listing (PR #471 verify).
        let seriesRules: [SeriesRuleWrite.StoredRule] = try {
            // #288: a lookup that raises is a failed lookup, not "no rule" (which would read as an
            // unwritable pattern), so it throws.
            let series = try addressesOwnOccurrence
                ? DetachedOccurrenceSpan.seriesIdentifier(of: identifier).flatMap { try storedEvent(id: $0) } : masterEvent
            // PR #471 verify rounds 6-7: whether a week start regroups the rule depends on the
            // series' start weekday, read in the zone its days are read in, from the first
            // occurrence's original slot (occurrenceDate), not where an edit moved it.
            let startWeekday = series.map {
                Calendar.gregorian(in: $0.isAllDay ? .current : ($0.timeZone ?? .current))
                    .component(.weekday, from: $0.occurrenceDate ?? $0.startDate)
            }
            return (series?.recurrenceRules ?? []).map { SeriesRuleWrite.StoredRule($0, startWeekday: startWeekday) }
        }()
        let shownStart: Date = event.startDate
        let eventSlot: Date = UndoPostState.ruleSlot(
            eventIdentifier: addressesOwnOccurrence ? identifier : event.eventIdentifier,
            externalIdentifier: event.calendarItemExternalIdentifier, occurrenceDate: event.occurrenceDate,
            isAllDay: event.isAllDay) ?? shownStart
        let seriesStart: Date = masterEvent.startDate
        let wholeFromSeries = applyToAll && !addressesOwnOccurrence
        let reach = SeriesRuleWrite.reach(
            applyToAll: applyToAll, futureSpan: span == .futureEvents, repeats: masterEvent.hasRecurrenceRules,
            ownIdLater: ownNeighbours.map { $0.earlierRemain || $0.own.firstSlotGone },
            seriesStart: seriesStart, occurrenceSlot: wholeFromSeries ? seriesStart : eventSlot)
        // #442: it answered updated and an occurrence nobody created appeared (device). Read from the
        // reach, so span future from the first occurrence (the same save over the whole series) is
        // refused too (cluster verify); still before the first write.
        // Cluster verify r2, r3: a series the scan cannot rule out is refused too (fail closed).
        var allDayFacts: (edited: Bool, unknown: Bool, listed: Bool)?
        if DetachedOccurrenceSpan.refusesAllDayChange(
            wholeSeries: reach.isWholeSeries, hasRules: masterEvent.hasRecurrenceRules, requested: isAllDay, current: masterEvent.isAllDay,
            clearingRecurrence: clearRecurrence,
            hasEditedOccurrence: { let facts = allDayEditFacts(of: masterEvent, id: identifier); allDayFacts = facts; return facts.edited || facts.unknown }()) {
            throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.allDayRefusalReason(
                edited: allDayFacts?.edited ?? true, listed: allDayFacts?.listed ?? true))
        }
        let now = Date()
        let happened = reach.anchor.map {
            SeriesRuleWrite.hasHappened(slot: $0, shownStart: wholeFromSeries ? seriesStart : shownStart, now: now)
        } ?? false

        // #451: span future from a later occurrence, on the fields measured to lose occurrences.
        if let reason = SeriesRuleWrite.laterOccurrenceRefusal(
            fromLaterOccurrence: reach.isFromLaterOccurrence,
            changesAllDay: datePlan.isAllDay != event.isAllDay,
            changesCalendar: newCalendar.map { $0.calendarIdentifier != event.calendar?.calendarIdentifier } ?? false,
            hasRecurrence: recurrenceRule != nil, occurrenceCount: recurrenceRule?.occurrenceCount,
            wholeSeriesCall: applyToAll,
            storedRuleUnwritable: SeriesRuleWrite.writableRule(seriesRules) == nil,
            recurrenceIsStored: recurrenceRule.map { SeriesRuleWrite.isStoredRule($0, stored: seriesRules) } ?? false) {
            throw EventKitError.seriesWriteRefused(reason: reason)
        }
        // #451 (PR #471 verify round 2): from an occurrence that happened, start_time keeps that
        // occurrence's date; from one still to come, it is not before now. Any other date moved
        // or dropped occurrences that happened, and undo refuses.
        let dayCalendar = Calendar.gregorian(in: datePlan.isAllDay || event.isAllDay ? .current : (event.timeZone ?? .current))
        if let reason = SeriesRuleWrite.startRefusal(
            reach: reach, plannedStart: datePlan.datesToWrite?.start, happened: happened, now: now,
            dayCalendar: dayCalendar, clearingRecurrence: clearRecurrence) {
            throw EventKitError.seriesWriteRefused(reason: reason)
        }
        // #478: from an occurrence that happened, a zone change moved happened occurrences and lost
        // the last one, and undo refuses.
        let changesZone = SeriesRuleWrite.changesZone(
            requested: timezone, clearTimezone: clearTimezone, stored: event.timeZone)
        // #428 verify r9: through the first occurrence by slot no identifier takes this refusal's span
        // future route for a time zone, so that sentence is replaced there (#478's text only).
        if let reason = SeriesRuleWrite.zoneRefusal(
            reach: reach, happened: happened, changesZone: changesZone,
            storedAllDay: event.isAllDay, resultAllDay: datePlan.isAllDay, clearingTimezone: clearTimezone) {
            throw EventKitError.seriesWriteRefused(reason: DetachedOccurrenceSpan.addressesFirstBySlot(ownNeighbours)
                ? DetachedOccurrenceSpan.firstEditedOccurrenceRoute(reason) : reason)
        }
        // #509: the store keeps the rule end as a fixed instant and re-expands the rule from the new
        // start, so a start change over the rest of the series dropped every occurrence moved past
        // that end, and answered updated (device). Refused before the first field is assigned.
        // PR #510 round 1: gated on the series' rules, so the own-id routes (#416, #428) are checked
        // (HIGH 2); a zone change counts (MEDIUM 5); a rule passed in the call is checked against its
        // own end (MEDIUM 6).
        let shiftStart: Date = datePlan.datesToWrite?.start ?? event.startDate
        if RuleEndShift.applies(
            repeats: RuleEndShift.repeats(masterHasRules: masterEvent.hasRecurrenceRules, addressesOwnOccurrence: addressesOwnOccurrence),
            reachesEnd: applyToAll || span == .futureEvents,
            movesStart: !UndoPostState.sameInstant(shiftStart, event.startDate), changesZone: changesZone) {
            let seriesID: String? = addressesOwnOccurrence ? DetachedOccurrenceSpan.seriesIdentifier(of: identifier) : identifier
            let ruleHolder: EKEvent? = addressesOwnOccurrence ? try seriesObject(ofOccurrence: identifier) : event
            if addressesOwnOccurrence { _ = ruleHolder?.refresh() }   // as #505 reads it; a failure is fine (#326)
            let rules = ruleHolder?.recurrenceRules ?? []
            let storedZone: TimeZone = event.isAllDay ? .current : (event.timeZone ?? .current)
            let newZone: TimeZone = datePlan.isAllDay || clearTimezone ? .current : (timezone ?? event.timeZone ?? .current)
            let plan = RuleEndShift.Plan(
                storedStarts: addressesOwnOccurrence ? [event.startDate, eventSlot] : [event.startDate],
                plannedStart: shiftStart, storedZone: storedZone, newZone: newZone,
                unit: RuleEndShift.unit(of: rules), keepsDays: rules.contains(where: RuleEndShift.keepsDays))
            let ends = RuleEndShift.ends(stored: rules.compactMap { $0.recurrenceEnd?.endDate },
                                         passedRule: RuleEndShift.passedRule(recurrenceRule, clearing: clearRecurrence))
            if let reason = ruleEndShiftRefusal(
                series: ruleHolder, seriesID: seriesID, ends: ends, plan: plan,
                from: applyToAll ? nil : eventSlot, ruleWritable: SeriesRuleWrite.writableRule(seriesRules) != nil) {
                throw EventKitError.seriesWriteRefused(reason: reason)
            }
        }
        // #451 (PR #471 verify item 4): a rule from an occurrence that happened keeps only the
        // stored pattern with a bound that keeps what happened; any other rewrote the past.
        // The stored count runs from the original first start, which only a call over the whole
        // series from its first slot holds (PR #471 verify round 3).
        if let reason = SeriesRuleWrite.startedRuleRefusal(
            recurrenceRule, stored: seriesRules, happened: happened,
            countBase: SeriesRuleWrite.countBase(reach: reach, viaStandIn: resolved.viaStandIn,
                                                 firstSlotGone: ownNeighbours?.own.firstSlotGone ?? false),
            now: now, calendar: Calendar.gregorian(in: event.timeZone ?? .current)) {
            throw EventKitError.seriesWriteRefused(reason: reason)
        }

        // Validate recurrence weekday consistency (#5, #454): which days apply is `WeekdayCheck.daysToCheck`.
        // Skip entirely if clearRecurrence is true (event becoming non-recurring)
        // Read from the values the event will have after this update: the planned start, in the
        // zone WeekdayCheck.zone picks (the host zone for an all-day result).
        let effectiveRule: RecurrenceRuleInput? = clearRecurrence ? nil : recurrenceRule
        // #428: the detached object has no rules of its own; a new start over the series still has
        // to fit the series' rule.
        let detachedWrite = (applyToAll || span != .thisEvent)
            && DetachedOccurrenceSpan.addressesOneOccurrence(identifier: identifier, isDetached: event.isDetached)
        let storedRule = clearRecurrence ? nil
            : (detachedWrite ? try seriesObject(ofOccurrence: identifier)?.recurrenceRules : event.recurrenceRules)?.first
        let plannedStart: Date = datePlan.datesToWrite?.start ?? event.startDate
        let startDayMoves = WeekdayCheck.dayChanges(
            from: event.startDate, in: WeekdayCheck.zone(resultIsAllDay: event.isAllDay, requested: nil, clearTimezone: false, stored: event.timeZone),
            to: plannedStart, in: WeekdayCheck.zone(resultIsAllDay: datePlan.isAllDay, requested: timezone, clearTimezone: clearTimezone, stored: event.timeZone),
            host: Calendar.current)
        let storedNumbered = storedRule.map {
            WeekdayCheck.isNumberedRule(weekNumbers: $0.daysOfTheWeek?.map(\.weekNumber) ?? [], setPositions: $0.setPositions?.map(\.intValue))
        } ?? false
        let ruleKeepsStoredPattern: Bool = {
            guard let effectiveRule, let storedRule else { return false }
            let otherParts = [storedRule.monthsOfTheYear, storedRule.weeksOfTheYear, storedRule.daysOfTheYear]
                .contains { $0?.isEmpty == false }
            return WeekdayCheck.keepsStoredPattern(
                frequency: effectiveRule.frequency, interval: effectiveRule.interval, daysOfMonth: effectiveRule.daysOfMonth,
                stored: storedRule.frequency, storedInterval: storedRule.interval,
                storedDaysOfMonth: storedRule.daysOfTheMonth?.map(\.intValue),
                storedNumbered: storedNumbered, storedHasOtherParts: otherParts)
        }()
        let daysToValidate = WeekdayCheck.daysToCheck(
            requested: effectiveRule?.daysOfWeek, ruleInCall: effectiveRule != nil,
            stored: storedRule?.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue },
            storedCount: storedRule.map { WeekdayCheck.storedDaysCount(isWeekly: $0.frequency == .weekly, span: span) } ?? false,
            ruleKeepsStoredPattern: ruleKeepsStoredPattern, startDayMoves: startDayMoves)
        // #416: through an occurrence's own id the rule runs from its original day, not the day it
        // shows. A new start moves that day, and `recurrence` is not written with one here.
        let originalDay = startDate != nil ? nil : DetachedOccurrenceSpan.originalDay(
            identifier: identifier, isDetached: event.isDetached, wholeSeries: applyToAll, futureSpan: span == .futureEvents,
            externalIdentifier: event.calendarItemExternalIdentifier, occurrenceDate: event.occurrenceDate, isAllDay: event.isAllDay)
        // #428 verify r4: through an occurrence's own id a new weekly days_of_week is read against
        // the original day before #454's exemptions, which read the series' stored rule.
        if let originalDay, let rule = effectiveRule, rule.frequency == .weekly,
           DetachedOccurrenceSpan.refusesRecurrenceDay(
               originalWeekday: WeekdayCheck.weekday(of: originalDay, resultIsAllDay: datePlan.isAllDay, requested: timezone,
                                                     clearTimezone: clearTimezone, stored: event.timeZone, host: Calendar.current),
               requestedDays: rule.daysOfWeek) {
            throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.recurrenceDayReason)
        }
        if let days = daysToValidate, !days.isEmpty {
            let weekday = WeekdayCheck.weekday(
                of: originalDay ?? datePlan.datesToWrite?.start ?? event.startDate, resultIsAllDay: datePlan.isAllDay,
                requested: timezone, clearTimezone: clearTimezone, stored: event.timeZone, host: Calendar.current)
            if !days.contains(weekday) {
                if originalDay != nil, effectiveRule != nil { throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.recurrenceDayReason) }
                let names = WeekdayCheck.names(weekday: weekday, days: days)
                if effectiveRule == nil, storedNumbered {
                    throw EventKitError.weekdayOffNumberedRule(startDay: names.start)
                }
                throw EventKitError.weekdayMismatch(startDay: names.start, expectedDays: names.expected)
            }
        }

        // #461: days_of_month by the same rules, read on the same day in the same zone.
        let storedUsesMonthDays = storedRule.map { $0.frequency == .monthly || $0.frequency == .yearly } ?? false
        if MonthDayCheck.refusesStoredMove(ruleInCall: effectiveRule != nil, stored: storedRule?.daysOfTheMonth?.map(\.intValue),
                                           storedUsesMonthDays: storedUsesMonthDays, span: span, startDayMoves: startDayMoves) {
            let otherParts = storedRule.map { [$0.monthsOfTheYear, $0.weeksOfTheYear, $0.daysOfTheYear].contains { $0?.isEmpty == false } } ?? false
            throw EventKitError.monthDayMoveRefused(
                expectedDays: MonthDayCheck.names(storedRule?.daysOfTheMonth?.map(\.intValue) ?? []),
                unwritable: MonthDayCheck.storedUnwritable(days: storedRule?.daysOfTheMonth?.map(\.intValue), numbered: storedNumbered, otherParts: otherParts),
                spanAll: applyToAll)
        }
        let monthDaysToValidate = MonthDayCheck.daysToCheck(
            requested: effectiveRule?.daysOfMonth, ruleInCall: effectiveRule != nil,
            stored: storedRule?.daysOfTheMonth?.map(\.intValue),
            storedUsesMonthDays: storedUsesMonthDays,
            span: span, ruleKeepsStoredPattern: ruleKeepsStoredPattern, startDayMoves: startDayMoves)
        if let days = monthDaysToValidate {
            let start = MonthDayCheck.day(
                of: originalDay ?? plannedStart,
                zone: WeekdayCheck.zone(resultIsAllDay: datePlan.isAllDay, requested: timezone, clearTimezone: clearTimezone, stored: event.timeZone),
                host: Calendar.current)
            if !MonthDayCheck.contains(day: start.day, daysInMonth: start.daysInMonth, list: days) {
                if originalDay != nil { throw EventKitError.occurrenceAddressRefused(reason: MonthDayCheck.occurrenceReason) }
                throw EventKitError.dayOfMonthMismatch(startDay: start.day, expectedDays: MonthDayCheck.names(days))
            }
        }

        if let t = title { event.title = t }

        if let dates = datePlan.datesToWrite {
            // The planned flag goes first (#364 verify round 4, device): timed dates assigned while
            // the event is still all-day are read as whole days, so 22:00 → 00:00 came back as two
            // days. The normalized all-day pair reads the same in either state.
            event.isAllDay = datePlan.isAllDay
            event.startDate = dates.start
            event.endDate = dates.end
        }

        if let n = notes { event.notes = n }
        if let l = location { event.location = l }
        if let a = isAllDay { event.isAllDay = a }

        if let urlString = url, let eventURL = URL(string: urlString) {
            event.url = eventURL
        }

        // Update per-event timezone (#12)
        // #478 (PR #479 verify rounds 2-3): on a started series, a zone that changes nothing (the
        // stored identifier, or clear_timezone over no zone) is not assigned, so the store does not
        // rewrite the series.
        // clear_timezone wins over timezone, as before.
        if SeriesRuleWrite.writesZone(
            requested: timezone, clearingTimezone: clearTimezone, changesZone: changesZone, reach: reach, happened: happened) {
            event.timeZone = clearTimezone ? nil : timezone
        }

        if let newCalendar = newCalendar {
            event.calendar = newCalendar
        }

        // Update alarms
        if let offsets = alarmOffsets {
            // Remove existing alarms
            if let existingAlarms = event.alarms {
                for alarm in existingAlarms {
                    event.removeAlarm(alarm)
                }
            }
            // Add new alarms
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                event.addAlarm(alarm)
            }
        }

        // Update recurrence rule
        if clearRecurrence {
            event.recurrenceRules = nil
        } else if let rule = recurrenceRule {
            event.recurrenceRules = [createRecurrenceRule(from: rule)]
        }

        // Update structured location
        if let loc = structuredLocation {
            let structured = EKStructuredLocation(title: loc.title)
            if let lat = loc.latitude, let lon = loc.longitude {
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
            }
            if let radius = loc.radius, radius > 0 {
                structured.radius = radius
            }
            event.structuredLocation = structured
        }

        // #373 verify round 2: a failed save (a read-only calendar, an alarm or recurrence EventKit
        // rejects) would leave every field assigned above on the cached event. Discard every unsaved
        // change before rethrowing, as the move path does. #274 measured it (iCloud, 2026-11-06): a
        // failed save of an event, a series or a move to another calendar left nothing pending, with
        // or without this, and saving the same object again did not write the failed title either.
        // It clears `hasChanges`; it is not what stops the change. Reminders differ
        // (`ExistingReminderSave`).
        do {
            try eventStore.save(event, span: span)
        } catch {
            event.rollback()
            throw error
        }
        markNeedsRefresh()
        // #236: an update that touched a recurring event is recorded only as a marker; its undo is
        // refused (RecurringUpdateKind). The rules after the update come from the request: a
        // detached occurrence reads back with none although its series still repeats. A detached
        // occurrence addressed by its own identifier is an occurrence update (round 5).
        let recurringKind = RecurringUpdateKind.of(
            hadRules: hadRules,
            hasRulesAfter: clearRecurrence ? false : (recurrenceRule != nil || hadRules),
            onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span)
        // #246: a calendar change across accounts changes the identifier, so the record keeps the
        // one the event has now (read here, after the save); #236: and the state the update left.
        await CalendarUndoManager.shared.record(EventUpdateRecord.operation(
            requestedID: identifier, identifierAfterSave: event.eventIdentifier, oldSnapshot: oldSnapshot,
            recurringKind: recurringKind, postState: { postWriteSnapshot(eventID: $0, saved: event) }))
        // #268 verify rounds 2-4: a save of one occurrence (span this) is known from the objects,
        // not from the id's shape; one with a calendar of another account was refused above. The
        // series object's identifier counts only when it refreshed and is a real series object (the
        // stand-in is an occurrence); otherwise `savedOccurrenceSeries` takes the occurrence id's
        // part before /RID=, or keeps the input.
        let savedIsOccurrence = event !== masterEvent
        let masterRefreshed = savedIsOccurrence && !resolved.viaStandIn && masterEvent.refresh()
        let seriesIdentifier = UpdatedIdentifier.savedOccurrenceSeries(
            savedIsOccurrence: event !== masterEvent, span: span,
            masterRefreshed: masterRefreshed,
            master: masterRefreshed ? masterEvent.eventIdentifier : nil,
            occurrence: event.eventIdentifier)
        return (event, seriesIdentifier, matchedOccurrence)
    }

    /// The zone a date-only `occurrence_date` is read in for `delete_event` and
    /// `move_events_batch` (`OccurrenceDateInput.resolve` asks for it only when the value needs a
    /// zone): the zone of the event the write will resolve (nil if not found or no zone set).
    /// Access is ensured first (#270): before access was ever granted the lookup finds nothing and
    /// the date would be read in the server zone. A failed check is thrown, the same error the
    /// write's own check reports, instead of falling back to the host zone (verify LOW). The event
    /// is resolved the way the write resolves it, refreshed (#271): a stored object can keep its
    /// old zone after an edit made elsewhere. No edited-before refusal, since only the zone is
    /// needed; the write applies its own, and that refusal only ever turns the pick into nil
    /// (`FirstRemainingOccurrence.pick`), so whenever the write resolves an event it is the one
    /// whose zone was read. A reminder's id gives nil here and not found from the write (#260).
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? {
        try await ensureCalendarAccess()
        return try freshEventWithOrigin(id: identifier, refuseWhenEditedBefore: false).flatMap { Self.occurrenceZone(of: $0.event) }
    }

    /// #270 round 3: the one zone an occurrence date is read in and searched in. The parse side
    /// (`occurrenceDateTimeZone`) and the search side (`findOccurrence` in `deleteEvent`,
    /// `moveEvent` and, since #383, `updateEvent`) read the same field through here, so a code change cannot make them differ; a
    /// zone edit landing between the lookup and the write still can (accepted, round 2).
    static func occurrenceZone(of event: EKEvent) -> TimeZone? {
        event.timeZone
    }

    /// Find a specific occurrence of a recurring event on a given date: the one that starts on that
    /// day in `timeZone` (#391, `OccurrenceDay.startsOnRequestedDay`), not one that only overlaps it.
    /// Returns the occurrence EKEvent (not the master event). With `slot`, only the occurrence
    /// whose `occurrenceDate` is that slot (#325 verify round 6): a day can hold two occurrences of
    /// one series, and the first enumerated one is not necessarily the one asked for.
    func findOccurrence(identifier: String, on date: Date, in timeZone: TimeZone? = nil, slot: Date? = nil) -> EKEvent? {
        // PR #394 verify round 1: the search day and the host day, so an all-day occurrence (a host day) is enumerated.
        guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone) else { return nil }
        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)

        var target: EKEvent?
        eventStore.enumerateEvents(matching: predicate) { event, stop in
            // #391: the occurrence must start on the requested day, not only overlap it.
            if FutureDeletionCoverage.isRequested(eventIdentifier: event.eventIdentifier, occurrenceDate: event.occurrenceDate,
                                                  identifier: identifier, slot: slot),
               OccurrenceDay.startsOnRequestedDay(occurrenceStart: event.startDate, isAllDay: event.isAllDay, requested: date, in: timeZone) {
                target = event
                stop.pointee = true
            }
        }
        return target
    }

    func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil) async throws {
        try await ensureCalendarAccess()

        guard let masterEvent = try freshEventWithOrigin(
            id: identifier, refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span))?.event else {
            throw notFoundError(id: identifier)
        }
        // #416: as in updateEvent; the delete removed the occurrence the id names, not that day's.
        if DetachedOccurrenceSpan.refusesOccurrenceDate(
            identifier: identifier, isDetached: masterEvent.isDetached, wholeSeries: false,
            hasOccurrenceDate: occurrenceDate != nil,
            matches: occurrenceDateMatches(occurrenceDate, occurrence: masterEvent, id: identifier)) {
            throw EventKitError.occurrenceAddressRefused(reason: DetachedOccurrenceSpan.occurrenceDateReason)
        }
        // verify r6: from the first occurrence by slot, moved to start after another, not measured.
        if span == .futureEvents, let refusal = try movedFirstDeleteRefusal(masterEvent, id: identifier) {
            throw EventKitError.occurrenceAddressRefused(reason: refusal)
        }
        let hadRules = masterEvent.hasRecurrenceRules

        // For recurring events, always resolve the specific occurrence (this/future both need it).
        // Non-recurring events operate on master directly. #244: the snapshots and the facts the
        // record is classified by are taken before the removal.
        let snapshots: DeletedEventSnapshots
        if hadRules, let date = occurrenceDate {
            guard let occurrence = findOccurrence(identifier: identifier, on: date, in: Self.occurrenceZone(of: masterEvent)) else {
                throw EventKitError.eventNotFound(identifier: "\(identifier) (no occurrence on \(date))")
            }
            snapshots = DeletedEventSnapshots(series: masterEvent, removed: occurrence, span: span,
                                              seriesExceptions: { self.captureSeriesExceptions(of: masterEvent) })
            try eventStore.remove(occurrence, span: span)
        } else if hadRules {
            throw EventKitError.invalidTimeRange(
                message: "For recurring events, occurrence_date is required to identify which occurrence to delete."
            )
        } else {
            snapshots = DeletedEventSnapshots(series: masterEvent, removed: masterEvent)
            try eventStore.remove(masterEvent, span: span)
        }
        markNeedsRefresh()
        let kind = snapshots.kind(span: span, seriesResolves: { seriesResolves(identifier: identifier) })
        await CalendarUndoManager.shared.record(snapshots.record(for: kind))
    }

    /// Delete an entire recurring event series by removing from the earliest occurrence.
    /// Uses .futureEvents on the master event to delete all occurrences.
    @discardableResult
    func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute {
        try await ensureCalendarAccess()

        guard let event = try freshEvent(id: identifier) else {
            // #428: as in updateEvent. Only span 'all' gets here (`handleDeleteEvent`). From the
            // occurrence that comes first, span future removed every occurrence on iCloud, open-ended
            // series and further edited occurrences included (2026-11-08), and its record cannot be
            // undone (`.followingOccurrences`): the response says so.
            if let first = try firstEditedOccurrenceID(of: identifier) {
                try await deleteEvent(identifier: first.id, span: .futureEvents)
                return .firstEditedOccurrence(id: first.id)
            }
            throw notFoundError(id: identifier)
        }
        // #416: through an occurrence edited on its own this removes that occurrence only (device,
        // iCloud: it has no recurrence rules of its own), while the answer says the series.
        if let refusal = try seriesDeleteRefusal(event, id: identifier) {
            throw EventKitError.occurrenceAddressRefused(reason: refusal)
        }

        // If the event has recurrence rules, it is (or belongs to) a recurring series.
        // eventStore.event(withIdentifier:) returns the master event for recurring series,
        // so calling .futureEvents on it deletes the entire series.
        // If it's a non-recurring event, just delete it normally.
        // #185 — snapshot BEFORE removal (the rules as value snapshots since #191, so undo
        // rebuilds the whole series), consistent with single deleteEvent.
        // #285: a series' exceptions are listed before the removal takes them away.
        let snapshot = EventSnapshot.recordingSeriesDelete(of: event, capture: { self.captureSeriesExceptions(of: event) })
        if event.hasRecurrenceRules {
            try eventStore.remove(event, span: .futureEvents)
        } else {
            try eventStore.remove(event, span: .thisEvent)
        }
        markNeedsRefresh()
        await CalendarUndoManager.shared.record(.deleteEvent(snapshot: snapshot))
        return .series
    }

    /// #436 (PR #465 verify r1): what the batch's route through the first occurrence refuses, as
    /// `delete_event` would through that id with span future: the moved-first refusal, and an
    /// occurrence that reports rules of its own, which delete_event refuses without occurrence_date
    /// (on iCloud an edited occurrence has none; Google and Exchange are not measured).
    static func throughFirstOccurrenceRefusal(_ occurrence: EKEvent, movedFirst: String?) -> String? {
        if let movedFirst { return movedFirst }
        return occurrence.hasRecurrenceRules ? throughFirstOccurrenceHasRulesReason : nil
    }

    /// PR #465 verify r2: the row has no occurrence_date to give, so the text names a call that works.
    static let throughFirstOccurrenceHasRulesReason = "This series' first occurrence was edited on its own and reports recurrence rules of its own, which was not measured, so this row does not delete the series through it. This shape has no tested way to delete the whole series through this tool yet; delete it in Calendar. This row deleted nothing."

    /// A row without a date on a recurring event, with span `this` or `future`. By `event_ids` no
    /// date is passed, so every bare recurring id gets this; its dry run says the same (#416).
    static let batchOccurrenceDateRequired = "For recurring events, occurrence_date is required"

    /// #185 — batch series deletion with a single aggregated undo unit, symmetric
    /// with deleteEventsBatch. One undo restores every series actually removed
    /// (partial failure: only the successes). Lives in the manager so undo
    /// bookkeeping never leaks into the server layer.
    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {
        try await ensureCalendarAccess()

        var successCount = 0
        var failures: [(String, String)] = []
        var undoSnapshots: [EventSnapshot] = []
        var throughFirstOccurrence: [(identifier: String, occurrenceID: String)] = []
        var refusingMarker: UndoOperation?

        for id in identifiers {
            do {
                // #236 (PR #259 round 3, finding 1): refreshed, like deleteEventSeries, so the
                // snapshot undo recreates is not a stale copy; not found stays a per-row failure.
                guard let event = try freshEvent(id: id) else {
                    // #436: as in deleteEventSeries: through the
                    // occurrence that comes first, with span future, which reaches every occurrence left.
                    if let first = try firstEditedOccurrenceID(of: id),
                       let occurrence = try freshEvent(id: first.id) {
                        if let refusal = try Self.throughFirstOccurrenceRefusal(occurrence, movedFirst: try movedFirstDeleteRefusal(occurrence, id: first.id)) {
                            failures.append((id, refusal))
                            continue
                        }
                        let snapshots = DeletedEventSnapshots(series: occurrence, removed: occurrence)
                        try eventStore.remove(occurrence, span: .futureEvents)
                        successCount += 1
                        throughFirstOccurrence.append((identifier: id, occurrenceID: first.id))
                        // PR #465 verify r2: kept only for a call where no other row is recorded.
                        if refusingMarker == nil {
                            refusingMarker = snapshots.record(for: snapshots.kind(
                                span: .futureEvents, seriesResolves: { seriesResolves(identifier: first.id) }))
                        }
                        continue
                    }
                    failures.append((id, notFoundReason(id: id)))
                    continue
                }
                // #416: as in deleteEventSeries; a row refused, the others go on. By date range too (#427).
                if let refusal = try seriesDeleteRefusal(event, id: id, namedInTheCall: Set(identifiers), batch: true) {
                    failures.append((id, refusal))
                    continue
                }
                let snapshot = EventSnapshot.recordingSeriesDelete(of: event, capture: { self.captureSeriesExceptions(of: event) })
                if event.hasRecurrenceRules {
                    try eventStore.remove(event, span: .futureEvents)
                } else {
                    try eventStore.remove(event, span: .thisEvent)
                }
                successCount += 1
                undoSnapshots.append(snapshot)
            } catch {
                let code = EventKitErrorSanitizer.writeFailureLog(
                    handler: "deleteEventsBatch",
                    identifier: id,
                    error: error
                )
                failures.append((id, code))
            }
        }

        markNeedsRefresh()
        if !undoSnapshots.isEmpty {
            await CalendarUndoManager.shared.record(.batch(undoSnapshots.map { .deleteEvent(snapshot: $0) }))
        } else if let refusingMarker {
            // PR #465 verify r2: with no other row recorded, the call records what delete_event
            // records for the same delete, which undo refuses and drops. Without it, the next undo
            // would revert an older, unrelated entry, and redo would not be cleared.
            await CalendarUndoManager.shared.record(refusingMarker)
        }
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures,
            throughFirstOccurrence: throughFirstOccurrence
        )
    }

    // MARK: - Search and Conflict Detection

    /// Search events by keyword(s) in title, notes, or location
    /// - Parameters:
    ///   - keywords: Array of keywords to search for
    ///   - matchMode: "any" (OR) or "all" (AND)
    ///   - startDate: Optional start date for search range
    ///   - endDate: Optional end date for search range
    ///   - calendarName: Optional calendar name filter
    ///   - calendarSource: Optional calendar source filter
    func searchEvents(
        keywords: [String],
        matchMode: String = "any",
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) async throws -> [EKEvent] {
        try await ensureCalendarAccess()
        refreshIfNeeded()

        // Default to ±2 years from now. EventKit's predicateForEvents can return
        // incomplete results with extremely wide ranges (distantPast/distantFuture).
        let defaults = EventRangeQuery.defaultSearchRange(now: Date())
        let searchStart = startDate ?? defaults.start
        let searchEnd = endDate ?? defaults.end

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        let allEvents = try events(from: searchStart, to: searchEnd, calendars: calendars)

        // Lowercase all keywords
        let lowercasedKeywords = keywords.map { $0.lowercased() }

        return allEvents.filter { event in
            // Combine searchable text
            let searchableText = [
                event.title?.lowercased(),
                event.notes?.lowercased(),
                event.location?.lowercased()
            ].compactMap { $0 }.joined(separator: " ")

            if matchMode == "all" {
                // AND mode: all keywords must match
                return lowercasedKeywords.allSatisfy { searchableText.contains($0) }
            } else {
                // OR mode (default): any keyword matches
                return lowercasedKeywords.contains { searchableText.contains($0) }
            }
        }
    }

    /// Backward-compatible single keyword search
    func searchEvents(
        keyword: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) async throws -> [EKEvent] {
        return try await searchEvents(
            keywords: [keyword],
            matchMode: "any",
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            calendarSource: calendarSource
        )
    }

    /// Find events with similar titles (case-insensitive substring match).
    /// Used to provide hints when creating events, helping LLMs reuse correct calendar names.
    /// - Parameters:
    ///   - title: The title to match against
    ///   - limit: Maximum number of results (default 5)
    /// - Returns: Array of matching events, sorted by start date descending (most recent first)
    func findSimilarEvents(title: String, limit: Int = 5) async throws -> [EKEvent] {
        try await ensureCalendarAccess()
        refreshIfNeeded()

        let searched = EventRangeQuery.defaultSearchRange(now: Date())
        let allEvents = try events(from: searched.start, to: searched.end, calendars: nil)

        let lowercasedTitle = title.lowercased()
        // Split title into words for flexible matching
        let titleWords = lowercasedTitle.split(separator: " ").map(String.init).filter { $0.count >= 2 }

        let matches = allEvents.filter { event in
            guard let eventTitle = event.title?.lowercased() else { return false }
            // Match if any significant word from the new title appears in existing event title
            return titleWords.contains { eventTitle.contains($0) }
        }
        .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }

        // Deduplicate by title+calendar (keep most recent)
        var seen = Set<String>()
        var unique: [EKEvent] = []
        for event in matches {
            let key = "\(event.title ?? "")|\(event.calendar.title)"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(event)
            }
            if unique.count >= limit { break }
        }

        return unique
    }

    // MARK: - Batch Operations

    /// Delete multiple events at once.
    /// Each item is (eventIdentifier, occurrenceDate). For recurring events, occurrenceDate is required.
    /// The same eventIdentifier can appear multiple times with different dates (multiple occurrences).
    func deleteEventsBatch(
        items: [(identifier: String, occurrenceDate: Date?)],
        span: EKSpan = .thisEvent,
        slots: [Date?]? = nil
    ) async throws -> BatchDeleteResult {
        try await ensureCalendarAccess()

        var successCount = 0
        var failures: [(String, String)] = []
        // #185 — collect a record per successful removal so the whole batch is one undo unit,
        // classified per item as in deleteEvent (#244): one occurrence is recorded as that
        // occurrence, an occurrence and the following ones as a marker (which refuses the batch's
        // undo before any member runs, D3), and the series only when a span future delete started
        // at its first occurrence and removed it all (`EventRemovalKind.of`).
        // Same-identifier dedupe (#185 verify F5), now for whole-event records only: two whole
        // snapshots of one identifier would rebuild it twice; occurrence records are distinct items.
        var undoOperations: [UndoOperation] = []
        var undoSeenWholeIdentifiers = Set<String>()
        // #325 verify rounds 3-4: occurrences an earlier span-future removal already reached; #452:
        // and ids an earlier row deleted whole. The event_ids dry run goes through the same sequence.
        var sequence = BatchRowSequence(span: span)
        var coveredCount = 0
        var followingOccurrencesDeleted: [String] = []
        // #452 review r1 items 1-2: by event_ids a row an earlier cut reaches counts as already removed
        // only when it resolved before the call; a stale or mistyped id fails as not found.
        if span == .futureEvents {
            for item in items where item.occurrenceDate == nil && item.identifier.contains("/RID=") {
                // A lookup that raises (#288) is not known to resolve: a later miss of that row then
                // fails as not found instead of being counted. The row's own lookup reports the raise.
                let resolved: EKEvent?
                do {
                    resolved = try freshEventWithOrigin(
                        id: item.identifier, refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span))?.event
                } catch {
                    resolved = nil
                }
                if let resolved {
                    sequence.resolvedBeforeTheCall(item.identifier, hasRecurrenceRules: resolved.hasRecurrenceRules)
                }
            }
        }

        for (index, item) in items.enumerated() {
            // `slots` is index-aligned with `items` (the by-date-range handler); absent, nothing is skipped.
            let slot = slots.flatMap { index < $0.count ? $0[index] : nil }
            if BatchRowSequence.settle(sequence.before(identifier: item.identifier, listed: item.occurrenceDate, slot: slot),
                                       identifier: item.identifier, failures: &failures, coveredCount: &coveredCount) {
                continue
            }
            do {
                // #236 (PR #259 round 3, finding 1): refreshed, like deleteEvent.
                guard let masterEvent = try freshEventWithOrigin(
                    id: item.identifier, refuseWhenEditedBefore: FirstRemainingOccurrence.refusesEditedBefore(span: span))?.event else {
                    _ = BatchRowSequence.settle(
                        sequence.notFound(identifier: item.identifier, listed: item.occurrenceDate,
                                          reason: { notFoundReason(id: item.identifier) }),
                        identifier: item.identifier, failures: &failures, coveredCount: &coveredCount)
                    continue
                }
                let hadRules = masterEvent.hasRecurrenceRules

                let snapshots: DeletedEventSnapshots
                if hadRules, let date = item.occurrenceDate {
                    guard let occurrence = findOccurrence(identifier: item.identifier, on: date, in: masterEvent.timeZone, slot: slot) else {
                        failures.append((item.identifier, "No occurrence found on specified date"))
                        continue
                    }
                    snapshots = DeletedEventSnapshots(series: masterEvent, removed: occurrence, span: span,
                                                      seriesExceptions: { self.captureSeriesExceptions(of: masterEvent) })
                    let removedStart = occurrence.startDate, removedSlot = occurrence.occurrenceDate
                    try eventStore.remove(occurrence, span: span)
                    if let removedStart {
                        sequence.deletedOccurrence(identifier: item.identifier, requested: date, requestedSlot: slot,
                                                   removedStart: removedStart, removedSlot: removedSlot)
                    }
                } else if hadRules {
                    failures.append((item.identifier, Self.batchOccurrenceDateRequired))
                    continue
                } else {
                    snapshots = DeletedEventSnapshots(series: masterEvent, removed: masterEvent)
                    let removedStart = masterEvent.startDate, removedSlot = masterEvent.occurrenceDate
                    try eventStore.remove(masterEvent, span: span)
                    // An occurrence edited on its own reads back without rules; with span future its
                    // removal takes its series from its slot on (#325 verify round 6), by event_ids too (#452).
                    if let removedStart {
                        sequence.deletedWhole(identifier: item.identifier, requested: item.occurrenceDate, requestedSlot: slot,
                                              removedStart: removedStart, removedSlot: removedSlot)
                    }
                    // Review r1 item 3: its undo record refuses the whole batch's undo; the response says so.
                    if item.occurrenceDate == nil, BatchRowSequence.deletesLaterOccurrences(identifier: item.identifier, span: span) {
                        followingOccurrencesDeleted.append(item.identifier)
                    }
                }
                successCount += 1
                let kind = snapshots.kind(span: span, seriesResolves: { seriesResolves(identifier: item.identifier) })
                if kind != .wholeEvent || undoSeenWholeIdentifiers.insert(item.identifier).inserted {
                    undoOperations.append(snapshots.record(for: kind))
                }
            } catch {
                let code = EventKitErrorSanitizer.writeFailureLog(
                    handler: "deleteEventsBatch",
                    identifier: item.identifier,
                    error: error
                )
                failures.append((item.identifier, code))
            }
        }

        markNeedsRefresh()
        // #185 — one .batch entry for the whole call (partial failure: only the
        // events actually removed). A single undo restores every one of them.
        if !undoOperations.isEmpty {
            await CalendarUndoManager.shared.record(.batch(undoOperations))
        }
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures,
            coveredCount: coveredCount,
            followingOccurrencesDeleted: followingOccurrencesDeleted
        )
    }

    /// Find duplicate events across calendars
    func findDuplicateEvents(
        calendarNames: [String]?,
        startDate: Date,
        endDate: Date,
        toleranceMinutes: Int = 5
    ) async throws -> DuplicateSearchValue {
        try await ensureCalendarAccess()
        refreshIfNeeded()

        // #437: never empty, which EventKit reads as all calendars.
        let calendars = try DuplicateCalendars.resolve(names: calendarNames, among: eventStore.calendars(for: .event),
                                                       identifier: { $0.calendarIdentifier },
                                                       title: { $0.title }, sourceTitle: { $0.source?.title ?? "" })

        let events = try self.events(from: startDate, to: endDate, calendars: calendars)

        // #325 verify round 1: pairs are found by title group and start order, not by comparing
        // every pair (the range is no longer cut to four years, so n can be large).
        let tolerance = TimeInterval(toleranceMinutes) * 60   // no Int overflow for a huge tolerance_minutes (verify round 2)
        let pairs = try DuplicateMatcher.pairs(
            count: events.count, tolerance: tolerance,
            maxComparisons: EventRangeQuery.comparisonLimit(searched: EventRangeQuery.Span(start: startDate, end: endDate)),
            title: { events[$0].title }, calendar: { events[$0].calendar.calendarIdentifier },
            start: { events[$0].startDate }, end: { events[$0].endDate }
        )
        let duplicates = pairs.map { pair -> DuplicatePair in
            let e1 = events[pair.first], e2 = events[pair.second]
            return DuplicatePair(
                event1Id: e1.eventIdentifier ?? "",
                event1Title: e1.title ?? "",
                event1Calendar: e1.calendar.title,
                event1CalendarSource: e1.calendar.source?.title ?? "",
                event1StartDate: e1.startDate,
                event2Id: e2.eventIdentifier ?? "",
                event2Title: e2.title ?? "",
                event2Calendar: e2.calendar.title,
                event2CalendarSource: e2.calendar.source?.title ?? "",
                event2StartDate: e2.startDate,
                timeDifferenceSeconds: Int(pair.startDifference)
            )
        }

        return DuplicateSearchValue(
            calendarsChecked: DuplicateCalendars.checkedLabels(calendars, title: { $0.title }, sourceTitle: { $0.source?.title ?? "" }),
            pairs: duplicates
        )
    }

    /// Check for events that overlap with the given time range
    func checkConflicts(
        startDate: Date,
        endDate: Date,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        excludeEventId: String? = nil
    ) async throws -> [EKEvent] {
        try await ensureCalendarAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        let events = try self.events(from: startDate, to: endDate, calendars: calendars)

        // Filter out excluded event and check for actual overlap
        return events.filter { event in
            // Exclude the specified event (useful when checking before updating)
            if let excludeId = excludeEventId, event.eventIdentifier == excludeId {
                return false
            }
            // Check for time overlap (event must actually overlap with the range)
            return event.startDate < endDate && event.endDate > startDate
        }
    }

    /// Copies an event to another calendar. The copy is a new event; see `makeCopy` for the
    /// fields it keeps, and `EventCopyOperation.saveCopy` for a refused copy. Moves go through
    /// `moveEvent` / `moveEventForCopyTool` (#226). Returns the saved copy and the fields it did
    /// not keep (#272), read after the save with the move paths' rule.
    func copyEvent(
        identifier: String,
        toCalendarName: String,
        toCalendarSource: String? = nil
    ) async throws -> (event: EKEvent, notCarriedOver: [String]) {
        try await ensureCalendarAccess()
        guard let resolved = try freshEventWithOrigin(id: identifier, refuseWhenEditedBefore: false) else {
            throw notFoundError(id: identifier)
        }
        let sourceEvent = resolved.event
        let targetCalendar = try writableTargetCalendar(name: toCalendarName, source: toCalendarSource)
        // From the stand-in, an occurrence of the series: its absolute alarm dates are the series'
        // (verify round 5), so they move to its start like a split occurrence's (#253 D2).
        let alarms = Self.copyOutAlarms(of: sourceEvent, isSplit: resolved.viaStandIn).alarms
        let newEvent = Self.makeCopy(of: sourceEvent, alarms: alarms, in: targetCalendar, store: eventStore)
        defer { markNeedsRefresh() }
        // #261: no discard for a failed copy (see EventCopyOperation.saveCopy).
        try EventCopyOperation.saveCopy(carrying: alarms,
                                        logFailure: { Self.logCopyFailure(handler: "copyEvent", identifier: identifier, error: $0) }) {
            try eventStore.save(newEvent, span: .thisEvent)
        }
        // #273: the copy is a new one-off event, so its record is a create: undo deletes the copy
        // through the create-undo's #236 check (refused when the copy changed since).
        let copyID = newEvent.eventIdentifier ?? ""
        await CalendarUndoManager.shared.record(.createEvent(id: copyID, title: newEvent.title ?? "",
                                                             created: postWriteSnapshot(eventID: copyID, saved: newEvent)))
        return (newEvent, Self.fieldsNotCarriedOver(from: sourceEvent, to: newEvent))
    }

    /// A refused copy that carries location, email or sound alarms is reported by name
    /// (`EventKitError.copyRefused`), a trusted message that is not logged; the underlying
    /// error goes to stderr here, sanitized like any other write failure, under the caller's
    /// `handler` label.
    private static func logCopyFailure(handler: String, identifier: String, error: Error) -> String {
        EventKitErrorSanitizer.writeFailureLog(handler: handler, identifier: identifier, error: error)
    }

    /// `copy_event` with `delete_original` (#226). copy_event has no occurrence_date, so a
    /// recurring event is refused here with a pointer to move_events_batch. The move result
    /// is returned as is (verify #2, #3): no re-fetch by the new identifier, which may be empty
    /// on the copy path or not yet resolvable after a move across accounts.
    func moveEventForCopyTool(
        identifier: String,
        toCalendarName: String,
        toCalendarSource: String?
    ) async throws -> (result: EventMoveResult, title: String?) {
        try await ensureCalendarAccess()
        guard let sourceEvent = try freshEventWithOrigin(id: identifier, refuseWhenEditedBefore: false)?.event else {
            throw notFoundError(id: identifier)
        }
        // #426: an occurrence by its own id has no rules of its own, and a new calendar moves its
        // whole series (device).
        if EventMovePolicy.movesAsRecurring(hasRules: sourceEvent.hasRecurrenceRules, identifier: identifier, isDetached: sourceEvent.isDetached) {
            throw EventKitError.moveRefused(reason: "copy_event cannot move a recurring event; use move_events_batch with span and occurrence_dates.")
        }
        return try await moveEvent(identifier: identifier, occurrenceDate: nil, span: .this,
                                   toCalendarName: toCalendarName, toCalendarSource: toCalendarSource)
    }

    /// #226: moves an event (or one occurrence) to another calendar. In place first, which
    /// keeps every field, and the identifier on iCloud (on Google it changed within one account, #435); see `EventMovePolicy` for when
    /// it splits, falls back to copy + delete, or refuses.
    func moveEvent(
        identifier: String,
        occurrenceDate: Date?,
        span: EventMovePolicy.Span,
        toCalendarName: String,
        toCalendarSource: String?
    ) async throws -> (result: EventMoveResult, title: String?) {
        try await ensureCalendarAccess()
        guard let resolved = try freshEventWithOrigin(id: identifier, refuseWhenEditedBefore: false) else {
            throw notFoundError(id: identifier)
        }
        let master = resolved.event
        let targetCalendar = try writableTargetCalendar(name: toCalendarName, source: toCalendarSource)
        // #426: an occurrence by its own id reads as a one-off (no rules of its own), and a calendar
        // assigned to it moves the whole series (device): it takes the rules of a recurring event.
        let isRecurring = EventMovePolicy.movesAsRecurring(hasRules: master.hasRecurrenceRules, identifier: identifier, isDetached: master.isDetached)
        // Across accounts EventKit does a create plus a delete from a middle occurrence, which was
        // only ever shown to be safe within one account: refused outright (verify rounds 5-6).
        if FirstRemainingOccurrence.refusesMoveThroughStandIn(
            viaStandIn: resolved.viaStandIn,
            wholeSeries: !(isRecurring && span == .this && occurrenceDate != nil),
            acrossAccounts: FirstRemainingOccurrence.movesAcrossAccounts(
                fromSourceID: master.calendar?.source?.sourceIdentifier,
                toSourceID: targetCalendar.source?.sourceIdentifier)) {
            throw EventKitError.standInRefused(reason: Self.standInAccountReason)
        }

        var subject = master
        if isRecurring, span == .this, let date = occurrenceDate {
            guard let occurrence = findOccurrence(identifier: identifier, on: date, in: Self.occurrenceZone(of: master)) else {
                throw EventKitError.moveRefused(reason: "No occurrence of this event falls on occurrence_date.")
            }
            subject = occurrence
        }
        guard let originalCalendar = subject.calendar else {
            throw EventKitError.calendarNotFound(identifier: "source event calendar")
        }
        let input = EventMovePolicy.Input(isRecurring: isRecurring, span: span,
                                          hasOccurrenceDate: occurrenceDate != nil,
                                          attendeeCount: subject.attendees?.count ?? 0,
                                          alreadyInTarget: originalCalendar.calendarIdentifier == targetCalendar.calendarIdentifier)
        let title = subject.title
        var undo: UndoOperation?
        defer { markNeedsRefresh() }

        let copyOut: (_ isSplit: Bool) throws -> EventMoveExecutor.Copied = { isSplit in
            // A split occurrence's absolute alarms go to its start (#253 verify round 2, D2).
            let planned = Self.copyOutAlarms(of: subject, isSplit: isSplit)
            // A copy removes one occurrence (.thisEvent), so undo restores a standalone
            // occurrence rather than duplicating the original series (#208), with the alarms
            // the copy was given.
            // #321: a split occurrence is tied to its series, which its undo's slot check compares.
            let copied = EventSnapshot(from: subject, includeRecurrence: false, alarms: planned.alarms)
            let snapshot = isSplit ? copied.withOccurrenceOrigin(OccurrenceOrigin.of(subject)) : copied
            let copy = Self.makeCopy(of: subject, alarms: planned.alarms, in: targetCalendar, store: self.eventStore)
            let outcome = try EventCopyOperation.execute(source: snapshot, saveCopy: {
                // A refused copy names its location, email or sound alarms; the source is removed
                // only after the copy is saved (#253 verify round 2, D1). #261: no discard for a
                // failed copy (see EventCopyOperation.saveCopy).
                try EventCopyOperation.saveCopy(carrying: planned.alarms,
                                                logFailure: { Self.logCopyFailure(handler: isSplit ? "moveEvent.split" : "moveEvent.fallbackCopy",
                                                                                  identifier: identifier, error: $0) }) {
                    try self.eventStore.save(copy, span: .thisEvent)
                    return copy
                }
            }, sourceIsOccurrence: isSplit, sourceNotCarriedOver: planned.notCarriedOver, removeSource: {
                try self.eventStore.remove(subject, span: .thisEvent)
            }, copyRecord: { copy in
                // An empty identifier is recorded as such; its undo restores the source and says the
                // copy was not looked up (#466).
                let copyID = copy.eventIdentifier ?? ""
                return (copyID, self.postWriteSnapshot(eventID: copyID, saved: copy))
            })
            undo = outcome.undo
            return (outcome.value.eventIdentifier ?? "",
                    Self.fieldsNotCarriedOver(from: subject, to: outcome.value) + planned.notCarriedOver)
        }

        let result = try EventMoveExecutor.run(
            input,
            currentIdentifier: identifier,
            inPlace: {
                subject.calendar = targetCalendar
                // As measured from an occurrence's own id (#426): span this there moves the series.
                try self.eventStore.save(subject, span: master.hasRecurrenceRules ? .futureEvents : .thisEvent)
                let movedIdentifier = subject.eventIdentifier ?? identifier
                undo = .moveEvent(id: movedIdentifier, fromCalendarIdentifier: originalCalendar.calendarIdentifier,
                                  toCalendarIdentifier: targetCalendar.calendarIdentifier,
                                  title: title ?? "", isSeries: isRecurring)
                return movedIdentifier
            },
            restore: {
                // Discard every unsaved change the failed save left on the object, not just the
                // calendar, before the fallback copy reads it (verify #8).
                // rollback() also restores the calendar (checked on device 2026-10-04); assigning
                // it again would mark the event dirty for nothing (verify round 2 #4).
                subject.rollback()
            },
            copy: { try copyOut(false) },
            split: { try copyOut(true) })
        // #435: older records of this event follow it to its new identifier.
        if result.method == .inPlace, CalendarUndoManager.identifierChanged(from: identifier, to: result.eventIdentifier) {
            await CalendarUndoManager.shared.replaceEventIdentifier(identifier, with: result.eventIdentifier)
        }
        if let undo { await CalendarUndoManager.shared.record(undo) }
        return (result, title)
    }

    private func writableTargetCalendar(name: String, source: String?) throws -> EKCalendar {
        let targetCalendar = try findCalendar(name: name, source: source, entityType: .event)
        guard targetCalendar.allowsContentModifications else {
            // #37 verify: `name` is caller-supplied; keep it. The "(read-only)" suffix is
            // author-controlled. Do NOT interpolate `targetCalendar.title` (CalendarStore-sourced).
            throw EventKitError.calendarNotFound(identifier: "\(name) (read-only)")
        }
        return targetCalendar
    }

    /// The fields a copy keeps, availability included when the target calendar supports the
    /// value (#272). Recurrence and attendees are not among them; the move
    /// policy refuses before a copy would drop those (#226). `alarms` replaces the source's
    /// own: the copy-out passes `copyOutAlarms`, which puts a split occurrence's absolute
    /// alarms at its start.
    static func makeCopy(of source: EKEvent, alarms: [AlarmSnapshot]? = nil,
                         in calendar: EKCalendar, store: EKEventStore) -> EKEvent {
        let copy = EKEvent(eventStore: store)
        copy.title = source.title
        copy.startDate = source.startDate
        copy.endDate = source.endDate
        copy.notes = source.notes
        copy.location = source.location
        copy.url = source.url
        copy.isAllDay = source.isAllDay
        copy.timeZone = source.timeZone
        copy.calendar = calendar
        // #272: the source's availability when the target calendar supports it (#245's support
        // rule; decided after the calendar is set, since support depends on it). Otherwise the
        // calendar's default stays, and `fieldsNotCarriedOver` lists `availability`.
        if let value = EventSnapshot.availabilityForCopy(source: source.availability,
                                                         supported: calendar.supportedEventAvailabilities) {
            copy.availability = value
        }
        // #230: whole alarms; rebuilt from offsets, absolute and location alarms landed at the
        // event start and email alarms became display alarms.
        for alarm in alarms ?? (source.alarms ?? []).map(AlarmSnapshot.init(from:)) {
            copy.addAlarm(alarm.rebuild())
        }
        return copy
    }

    /// The alarms a copy-out writes: the source's own, or for an occurrence split out of its
    /// series those of `AlarmSnapshot.forSplitOccurrence` (#253 verify round 2, D2).
    static func copyOutAlarms(of source: EKEvent, isSplit: Bool) -> (alarms: [AlarmSnapshot], notCarriedOver: [String]) {
        let alarms = (source.alarms ?? []).map(AlarmSnapshot.init(from:))
        return isSplit ? AlarmSnapshot.forSplitOccurrence(alarms) : (alarms, [])
    }

    /// Fields the source actually had that `makeCopy` did not keep (#226).
    static func fieldsNotCarriedOver(from source: EKEvent, to copy: EKEvent) -> [String] {
        lostFields(hasCoordinates: source.structuredLocation?.geoLocation != nil,
                   sourceAvailability: source.availability,
                   copyAvailability: copy.availability)
    }

    static func lostFields(hasCoordinates: Bool,
                           sourceAvailability: EKEventAvailability,
                           copyAvailability: EKEventAvailability) -> [String] {
        var lost: [String] = []
        if hasCoordinates { lost.append("structured_location") }
        // A source without availability (`.notSupported`: subscribed, holiday or local
        // calendars) had nothing to lose (#272 verify).
        if sourceAvailability != .notSupported, sourceAvailability != copyAvailability { lost.append("availability") }
        return lost
    }

    // MARK: - Reminders

    /// Return identifiers of completed reminders matching the optional scope.
    ///
    /// Thin wrapper over `listReminders(completed: true, ...)` that projects
    /// the result to `[String]`. Exposed on `EventKitManaging` so handlers
    /// can be tested against `FakeEventKitManager` without having to fabricate
    /// `EKReminder` instances (which require an authorized `EKEventStore`).
    func listCompletedReminderIdentifiers(
        calendarName: String?,
        calendarSource: String?
    ) async throws -> [String] {
        let reminders = try await listReminders(
            completed: true,
            calendarName: calendarName,
            calendarSource: calendarSource
        )
        return reminders.map { $0.calendarItemIdentifier }
    }

    func listReminderPage(completed: Bool?, calendarName: String?, calendarSource: String?, query: ReminderPageQuery) async throws -> ReminderPage {
        let values = try await listReminders(completed: completed, calendarName: calendarName, calendarSource: calendarSource)
        return query.page(values, snapshot: ReminderReadSnapshot.init(from:))
    }

    func searchReminderPage(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?, query: ReminderPageQuery) async throws -> ReminderPage {
        let values = try await searchReminders(keywords: keywords, matchMode: matchMode, calendarName: calendarName, calendarSource: calendarSource, completed: completed)
        return query.page(values, snapshot: ReminderReadSnapshot.init(from:))
    }

    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] {
        let reminders = try await listReminders(completed: completed, calendarName: calendarName, calendarSource: calendarSource)
        return reminders.map(ReminderReadSnapshot.init(from:))
    }

    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?) async throws -> [ReminderReadSnapshot] {
        let reminders = try await searchReminders(keywords: keywords, matchMode: matchMode, calendarName: calendarName, calendarSource: calendarSource, completed: completed)
        return reminders.map(ReminderReadSnapshot.init(from:))
    }

    func listReminders(completed: Bool? = nil, calendarName: String? = nil, calendarSource: String? = nil) async throws -> [EKReminder] {
        try await ensureReminderAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .reminder)
        }

        let predicate: NSPredicate
        if let isCompleted = completed {
            if isCompleted {
                predicate = eventStore.predicateForCompletedReminders(
                    withCompletionDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            }
        } else {
            predicate = eventStore.predicateForReminders(in: calendars)
        }

        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders = reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    struct CreateReminderResult: Sendable {
        let reminder: ReminderWriteSnapshot
        let isDuplicate: Bool
        /// #261: compared fields a new store holds differently after a save that threw but
        /// committed (`NewObjectSave.run`); empty otherwise.
        let storeDiffers: [String]
        /// #267 (PR #298 verify round 2): the duplicate found has a due with a time. A bare-date
        /// create matches a reminder stored at 00:00 of that day and leaves it as it is.
        var duplicateHasTime = false
        /// #301 / #308: a created reminder's `date_sync`, judged on the saved reminder
        /// (`ReminderCreateWrite.readBack`), as `update_reminder` reports it, for a date-only and a
        /// timed due. Nil for an undated create and for a duplicate.
        var dateSync: ReminderDateSync.Report? = nil
        /// #333: the relative alarms read off the saved reminder (minutes before), when the create
        /// asked for `alarmOffsets`; nil otherwise and for a duplicate, which writes none.
        var storedRelativeAlarms: [Double]? = nil
        /// #433: the call wrote alarms, they were read back, and the earliest one is off the due time.
        var listShowsAlarmTime = false
    }

    /// #301: the duplicate reported among the matches. A list can hold both a date-only and a
    /// 00:00 timed reminder with the same title that match a bare date; which one the store
    /// fetches first must not decide which kind is reported, or whether the skip's note fires (among
    /// several matches of one kind, the first fetched is still reported). A match of the request's own kind wins (a date-only one for a bare date, a timed one for a time),
    /// else the first: a bare date that has an exact date-only duplicate reports that one with
    /// no note, and gets the note only when the reminder that matched has a time (PR #307
    /// verify round 2).
    static func preferringSameKind(_ matches: [EKReminder], as due: ReminderDueInput?) -> EKReminder? {
        let wantsDay: Bool
        switch due {
        case .day?: wantsDay = true
        case .timed?: wantsDay = false
        case nil: return matches.first
        }
        return matches.first { ($0.dueDateComponents?.hour == nil) == wantsDay } ?? matches.first
    }

    /// Find an existing incomplete reminder that matches by title on the same list, and by due
    /// date within a minute, a day counting as 00:00 of that day (`ReminderDueInput.matches`).
    private func findDuplicateReminder(
        title: String,
        due: ReminderDueInput?,
        calendar: EKCalendar
    ) async -> EKReminder? {
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: [calendar]
        )
        let reminders = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        return Self.preferringSameKind(reminders.filter { reminder in
            reminder.title == title && ReminderDueInput.matches(due, existing: reminder.dueDateComponents)
        }, as: due)
    }

    func createReminder(
        title: String,
        notes: String? = nil,
        due: ReminderDueInput? = nil,
        priority: Int = 0,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        locationTrigger: LocationTriggerInput? = nil
    ) async throws -> CreateReminderResult {
        try await ensureReminderAccess()
        // #333: refused before any lookup or write (the handler checks first too).
        try ReminderRelativeAlarms.check(alarmOffsets, due: ReminderRelativeAlarms.dueState(requested: due, clearDue: false, existing: nil))

        // Resolve calendar first (required for both duplicate check and creation)
        guard let name = calendarName else {
            throw EventKitError.calendarNameRequired(forType: "reminders")
        }
        let calendar = try findCalendar(name: name, source: calendarSource, entityType: .reminder)

        // Idempotency: check for existing reminder with same title (+due date) on same list
        if let existing = await findDuplicateReminder(title: title, due: due, calendar: calendar) {
            return CreateReminderResult(reminder: ReminderWriteSnapshot(from: existing), isDuplicate: true, storeDiffers: [],
                                        duplicateHasTime: existing.dueDateComponents?.hour != nil)
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority
        reminder.calendar = calendar

        var dateReport: ReminderDateSync.Report?
        if case .day(let day)? = due {
            // #267: a date-only reminder. No alarms exist yet, so only the start and due are written.
            // #301: the report is judged on the saved reminder below.
            dateReport = ReminderDateSync.setDueDay(reminder, to: day)
        } else if case .timed(let due)? = due {
            // #134: populate dueDateComponents.timeZone so iCloud Web / macOS
            // Today-view render the time at the host's wall clock instead of
            // re-interpreting floating components as UTC. EKReminder's
            // dueDateComponents is NSDateComponents-based which permits
            // timeZone == nil ("floating"); native EventKit on Mac/iPhone
            // resolves floating as local but iCloud Web does not — the spec
            // contract is "always store with explicit timezone".
            // #299: built by the same function as `update_reminder`'s timed due, in the
            // Gregorian calendar, not the host's region calendar.
            // #308: same write, and its report is judged on the saved reminder below.
            dateReport = ReminderCreateWrite.writeTimedDue(reminder, components: ReminderDateSync.timedDueComponents(for: due))
        }

        // #333: relative alarms, minutes before the due date.
        if let offsets = alarmOffsets {
            ReminderRelativeAlarms.replace(on: reminder, with: offsets)
        }

        // Add recurrence rule
        if let rule = recurrenceRule {
            reminder.recurrenceRules = [createRecurrenceRule(from: rule)]
        }

        // Add location trigger
        if let trigger = locationTrigger {
            let structured = EKStructuredLocation(title: trigger.title)
            structured.geoLocation = CLLocation(latitude: trigger.latitude, longitude: trigger.longitude)
            structured.radius = trigger.radius > 0 ? trigger.radius : 100
            let alarm = EKAlarm()
            alarm.structuredLocation = structured
            alarm.proximity = trigger.proximity
            reminder.addAlarm(alarm)
        }

        let storeDiffers = try saveNewReminder(reminder, handler: "createReminder", restoring: false)
        markNeedsRefresh()
        // #301 / #308: read every dated create back, as `update_reminder` does. A timed due that lost
        // its time or zone runs the #237 fallback and saves the new reminder again, unless the first
        // save threw and the store holds fields differently (`storeDiffers`, #261). This happens
        // before the result is built and the undo entry is recorded, so both see the re-read state.
        let dateSync = ReminderCreateWrite.readBack(reminder, report: dateReport, storeDiffers: storeDiffers,
                                                    save: { try eventStore.save(reminder, commit: true) },
                                                    reload: { reminder.refresh() },
                                                    rollback: { reminder.rollback() })
        let alarms = ReminderCreateWrite.alarmReadBack(offsets: alarmOffsets, saved: reminder, dateSync: dateSync, storeDiffers: storeDiffers)
        let result = CreateReminderResult(reminder: ReminderWriteSnapshot(from: reminder), isDuplicate: false, storeDiffers: storeDiffers,
                                          dateSync: dateSync,
                                          storedRelativeAlarms: alarms.stored,
                                          listShowsAlarmTime: alarms.listShowsAlarmTime)
        let createdID = result.reminder.calendarItemIdentifier
        await CalendarUndoManager.shared.record(.createReminder(id: createdID, title: result.reminder.title ?? title,
                                                                created: postWriteSnapshot(reminderID: createdID, saved: reminder)))
        return result
    }

    /// #261: saves a reminder that has never been written (`create_reminder`, delete-undo). If
    /// the save fails and a new store does not find the reminder, it is removed from the store
    /// without committing, so the next save by any tool does not write it (`NewObjectSave`). If
    /// that store cannot answer, a create keeps the reminder and fails with `saveUnchecked` (#289:
    /// it has no undo record), and a restore (`restoring`) removes it as before, its undo record
    /// being kept for a retry (PR #421 round 1). If
    /// that store finds it, it counts as saved, whether or not its compared fields agree, and this
    /// returns as after a save: the caller's success path runs (the create's result and undo
    /// entry, the delete-undo's restore). Returns the compared fields the store holds differently
    /// (empty after a save or when it holds the reminder as written), for the caller to name
    /// through `NewObjectSave.differingFieldsNote`.
    ///
    /// #281: a save that returns is checked in this store, as it is (no refresh; see
    /// `NewObjectSave`): does the list (by the identifier the reminder had before the save) and the
    /// reminder still resolve. A save
    /// into a list deleted elsewhere between the caller's list lookup and this save returns without
    /// error and writes nothing; it reads as a gone list and an unresolvable reminder, and
    /// `NewObjectSave.ListDeletedDuringSave` is thrown (`restoring` picks the delete-undo wording),
    /// so no undo entry is recorded for a create and a delete-undo keeps its record.
    private func saveNewReminder(_ reminder: EKReminder, handler: String, restoring: Bool) throws -> [String] {
        let listID = reminder.calendar?.calendarIdentifier
        return try NewObjectSave.run(save: { try eventStore.save(reminder, commit: true) },
                              verified: {
                                  try NewObjectSave.confirmWritten(
                                      listGone: listID.map { eventStore.calendar(withIdentifier: $0) == nil } ?? false,
                                      itemResolves: eventStore.calendarItem(withIdentifier: reminder.calendarItemIdentifier) != nil,
                                      restoring: restoring)
                              },
                              committed: { NewObjectSave.freshStoreFinds(NewObjectSave.reminderCheck(reminder)) },
                              onNoAnswer: restoring ? .discard : .keep,
                              discard: { try eventStore.remove(reminder, commit: false) },
                              report: { Self.logNewObjectOutcome(handler: handler, identifier: reminder.calendarItemIdentifier, $0) })
    }

    /// What a failed new-object save left (#261), on stderr only, one escaped line per failure.
    /// A failed discard is written as `<handler>.discard(<id>) failed: …` with both errors' domain
    /// and code, and means the object may still be written by the next save; the other outcomes
    /// are notes. `NewObjectSaveTests` pins this body.
    private static func logNewObjectOutcome(handler: String, identifier: String, _ outcome: NewObjectSave.Outcome) {
        let note = NewObjectSave.note(for: outcome, handler: handler, identifier: identifier)
        FileHandle.standardError.write(Data((EventKitErrorSanitizer.escapeForStderr(note) + "\n").utf8))
    }

    func updateReminder(
        identifier: String,
        title: String? = nil,
        notes: String? = nil,
        due: ReminderDueInput? = nil,
        priority: Int? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        locationTrigger: LocationTriggerInput? = nil,
        clearLocationTrigger: Bool = false,
        clearDueDate: Bool = false,
        realignToDue: Bool = false,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        clearRecurrence: Bool = false
    ) async throws -> ReminderUpdateResult {
        try await ensureReminderAccess()

        // PR #256 verify round 2: re-read before the first decision, so the no-due check, the
        // realign anchor and the undo snapshot see edits made elsewhere (Reminders.app) since this
        // store cached the reminder. `refresh() == false` means it is gone (the #236 convention).
        let store = eventStore
        let reminder = try ReminderUpdateWrite.freshReminder(
            identifier: identifier, lookup: { store.calendarItem(withIdentifier: $0) as? EKReminder },
            refresh: { $0.refresh() })
        let request = ReminderUpdateRequest(
            identifier: identifier, title: title, notes: notes, due: due, priority: priority,
            calendarName: calendarName, calendarSource: calendarSource, locationTrigger: locationTrigger,
            clearLocationTrigger: clearLocationTrigger, clearDueDate: clearDueDate, realignToDue: realignToDue,
            alarmOffsets: alarmOffsets, recurrenceRule: recurrenceRule, clearRecurrence: clearRecurrence)
        // PR #256 verify round 1: everything that can refuse the call runs before the first write,
        // so a refused call leaves the cached reminder untouched (#235 no-due check, #333 alarm
        // check, list lookup).
        try ReminderUpdateWrite.checkRealign(request, existingDue: reminder.dueDateComponents)
        try ReminderUpdateWrite.checkAlarms(request, existingDue: reminder.dueDateComponents)
        // #354: the rule checks, on the re-read reminder, before the first write.
        try ReminderRecurrenceWrite.check(request, existingDue: reminder.dueDateComponents,
                                          repeats: reminder.hasRecurrenceRules, isCompleted: reminder.isCompleted)
        let calendar = try calendarName.map { try findCalendar(name: $0, source: calendarSource, entityType: .reminder) }

        let oldSnapshot = ReminderSnapshot(from: reminder)
        let dateSync = try ReminderUpdateWrite.apply(
            request, to: reminder, calendar: calendar,
            save: { try saveExistingReminder(reminder, handler: "updateReminder") },
            reload: { reminder.refresh() },
            rollback: { reminder.rollback() })
        markNeedsRefresh()
        // PR #438 verify: judged on the re-read reminder, absolute alarms included; if it could not
        // be re-read, nothing is reported as stored.
        let alarms = ReminderUpdateWrite.alarmReadBack(request, saved: reminder, dateSync: dateSync, reload: { reminder.refresh() })
        let result = ReminderUpdateResult(
            reminder: ReminderWriteSnapshot(from: reminder), dateSync: dateSync,
            storedRelativeAlarms: alarms.stored,
            // PR #415 verify round 1: relative alarms left on a reminder that lost its timed due.
            leftoverAlarmsNote: ReminderRelativeAlarms.leftoverNote(saved: reminder, request: request, dateSync: dateSync),
            listShowsAlarmTime: alarms.listShowsAlarmTime,
            // #354 (PR #420 verify round 1): read off the saved reminder after a reload, when the
            // call touched the rule.
            recurrence: (recurrenceRule != nil || clearRecurrence)
                ? ReminderRecurrenceWrite.readBackAfterSave(reminder, request: request, reload: { reminder.refresh() }) : nil)
        // Same reason as update_event (#246): the identifier the reminder has after the save.
        let savedID = reminder.calendarItemIdentifier
        await CalendarUndoManager.shared.record(.updateReminder(id: savedID, oldSnapshot: oldSnapshot,
                                                                saved: postWriteSnapshot(reminderID: savedID, saved: reminder)))
        return result
    }

    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        try await ensureReminderAccess()

        // PR #256 verify round 3: `update_reminder` merges notes and tags into what this returns,
        // so it must be the stored reminder, not the cached one.
        let store = eventStore
        let reminder = try ReminderUpdateWrite.freshReminder(
            identifier: identifier, lookup: { store.calendarItem(withIdentifier: $0) as? EKReminder },
            refresh: { $0.refresh() })
        return ReminderWriteSnapshot(from: reminder)
    }

    func deleteReminder(identifier: String) async throws {
        try await ensureReminderAccess()

        guard let reminder = freshReminder(id: identifier) else {
            throw EventKitError.reminderNotFound(identifier: identifier)
        }

        let snapshot = ReminderSnapshot(from: reminder)
        try removeExistingReminder(reminder, handler: "deleteReminder")
        markNeedsRefresh()
        await CalendarUndoManager.shared.record(.deleteReminder(snapshot: snapshot))
    }

    // MARK: - Reminder Search & Batch

    /// Search reminders by keyword(s) in title or notes
    func searchReminders(
        keywords: [String],
        matchMode: String = "any",
        calendarName: String? = nil,
        calendarSource: String? = nil,
        completed: Bool? = nil
    ) async throws -> [EKReminder] {
        try await ensureReminderAccess()
        refreshIfNeeded()

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .reminder)
        }

        // Build predicate based on completed filter
        let predicate: NSPredicate
        if let isCompleted = completed {
            if isCompleted {
                predicate = eventStore.predicateForCompletedReminders(
                    withCompletionDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            }
        } else {
            predicate = eventStore.predicateForReminders(in: calendars)
        }

        let allReminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // Filter by keywords in Swift layer (for proper Unicode support)
        // Empty keywords = return all (useful for tag-only filtering)
        if keywords.isEmpty {
            return allReminders
        }

        let lowercasedKeywords = keywords.map { $0.lowercased() }

        return allReminders.filter { reminder in
            let searchableText = [
                reminder.title?.lowercased(),
                reminder.notes?.lowercased()
            ].compactMap { $0 }.joined(separator: " ")

            if matchMode == "all" {
                return lowercasedKeywords.allSatisfy { searchableText.contains($0) }
            } else {
                return lowercasedKeywords.contains { searchableText.contains($0) }
            }
        }
    }

    /// Delete multiple reminders at once
    func deleteRemindersBatch(identifiers: [String], onlyCompleted: Bool = false) async throws -> BatchDeleteResult {
        try await ensureReminderAccess()

        var successCount = 0
        var failures: [(String, String)] = []
        // #243: a snapshot per reminder actually removed, so the whole call is one undo entry, as
        // in deleteEventsBatch (#185). Both delete_reminders_batch and cleanup_completed_reminders
        // come through here.
        var undoSnapshots: [ReminderSnapshot] = []
        var mayLandCount = 0

        for id in identifiers {
            do {
                // #236 (PR #259 round 3, finding 1): refreshed, like deleteReminder, so the
                // only-completed check below reads the current completion.
                guard let reminder = freshReminder(id: id) else {
                    failures.append((id, "Reminder not found"))
                    continue
                }
                // #28 F1: when the caller asks for "only completed reminders"
                // (binding mode on cleanup_completed_reminders), honor the
                // invariant the tool schema promises. Without this gate, a
                // reminder un-completed between dry_run and execute would be
                // deleted anyway — silently contradicting the schema line
                // "Any ID that is no longer completed ... surfaces in failures[]".
                //
                // #33: extracted to `BatchDeleteFilter.shouldSkipUncompleted`
                // so the destructive contract has a unit-test-falsifiable
                // surface (the inline form has no TCC-free testable seam).
                if BatchDeleteFilter.shouldSkipUncompleted(
                    isCompleted: reminder.isCompleted,
                    onlyCompleted: onlyCompleted
                ) {
                    failures.append((id, "Reminder is no longer completed"))
                    continue
                }
                let snapshot = ReminderSnapshot(from: reminder)
                try eventStore.remove(reminder, commit: true)
                successCount += 1
                undoSnapshots.append(snapshot)
            } catch {
                // #32: never forward Apple-produced `localizedDescription` to
                // the MCP client — it could in a future macOS interpolate
                // reminder content. Route through the sanitizer so the
                // response carries only stable codes; the raw text still
                // reaches stderr for operator debugging.
                //
                // Spec R3 binds this catch to `sanitize(_:)` directly (NOT
                // `sanitizeForResponse`) — preserves the narrow regex
                // value-domain. #37 verify (Codex) noted the stderr write was
                // missing the control-char escape applied by `writeFailureLog`;
                // we share `escapeForStderr` to keep both paths consistent
                // without violating R3.
                //
                // #69: defensive symmetry with R7's trusted-branch carve-out
                // at writeFailureLog. Note the rationale differs here: R3
                // binds to `sanitize(_:)` directly (NOT `sanitizeForResponse`)
                // so trusted errors at this site receive a framework-style
                // code (e.g. "error_unknown") that does NOT equal `rawLog`.
                // The gate is therefore forward-compat hardening — if a
                // future caller of `deleteRemindersBatch` propagates a
                // `TrustedErrorMessage` conformer through this path, the
                // stderr-amplification window stays closed by construction.
                // In practice today, `eventStore.remove(reminder:commit:)`
                // only throws NSError, so the gate doesn't fire on hot paths.
                let sanitized = EventKitErrorSanitizer.sanitize(error)
                if !(error is TrustedErrorMessage) {
                    let safeId = EventKitErrorSanitizer.escapeForStderr(id)
                    let safeRawLog = EventKitErrorSanitizer.escapeForStderr(sanitized.rawLog)
                    // #70 thread-safety note: this stderr write site shares
                    // the same best-effort posture documented on
                    // `writeFailureLog` — POSIX `write(2)` atomicity holds
                    // only for byte counts ≤ macOS `PIPE_BUF` (512 bytes),
                    // and a `deleteRemindersBatch(<id>) failed: <rawLog>\n`
                    // line can easily exceed 512 bytes when `rawLog` carries
                    // a non-trivial `NSError` description. Concurrent batch
                    // failures CAN interleave on stderr; operators relying
                    // on per-line parsing should use a structured logger
                    // instead. See `writeFailureLog` doc for the full
                    // deferral rationale on the StderrLogger actor option.
                    FileHandle.standardError.write(
                        Data("deleteRemindersBatch(\(safeId)) failed: \(safeRawLog)\n".utf8)
                    )
                }
                failures.append((id, sanitized.code))
                mayLandCount += 1
            }
        }

        markNeedsRefresh()
        // #243: one entry for the call (partial failure: only the reminders actually removed).
        if let undo = UndoOperation.reminderBatchDelete(undoSnapshots) {
            await CalendarUndoManager.shared.record(undo)
        }
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures,
            mayLandCount: mayLandCount
        )
    }

    // MARK: - Helpers

    /// #354: static so `update_reminder`'s write (`ReminderRecurrenceWrite`) builds the same rule.
    static func makeRecurrenceRule(from input: RecurrenceRuleInput) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch input.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }

        var daysOfWeek: [EKRecurrenceDayOfWeek]?
        if let days = input.daysOfWeek {
            daysOfWeek = days.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
        }

        var end: EKRecurrenceEnd?
        if let endDate = input.endDate {
            end = EKRecurrenceEnd(end: endDate)
        } else if let count = input.occurrenceCount {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: input.interval,
            daysOfTheWeek: daysOfWeek,
            daysOfTheMonth: input.daysOfMonth?.map { NSNumber(value: $0) },
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    private func createRecurrenceRule(from input: RecurrenceRuleInput) -> EKRecurrenceRule {
        Self.makeRecurrenceRule(from: input)
    }

    private func parseColor(_ hex: String) -> CGColor {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Undo/Redo Execution

    /// Execute the reverse of an operation (for undo). #236: every arm that writes to an existing
    /// item first gets it from `verifiedEvent` / `verifiedReminder`, which refuse when the item
    /// no longer holds the state the operation left, and writes to that refreshed object.
    func executeUndo(_ operation: UndoOperation) async throws -> String {
        switch operation {
        case .createEvent(_, let title, _):
            // Undo create = delete. #182 verify: the record is already popped, so a
            // missing event MUST surface as an error — silently returning "Undone"
            // reports success for a no-op. `verifiedEvent` throws UndoTargetMissingError,
            // which keeps the record and names discard_id (also for an empty identifier).
            // For a series it also refuses when an occurrence was edited on its own (#236).
            let event = try await verifiedEvent(of: operation, verb: .undo)
            // #182 verify: a recurring master needs .futureEvents to remove the whole
            // series (mirrors deleteEventSeries); .thisEvent strands N-1 occurrences.
            try eventStore.remove(event, span: event.hasRecurrenceRules ? .futureEvents : .thisEvent)
            markNeedsRefresh()
            return "Undone: removed created event '\(undoVisibleTitle(title))'"

        case .deleteEvent(let snapshot):
            // Undo delete = recreate from snapshot, with the series' recorded exceptions (#285);
            // the arm's code is `SeriesExceptionsUndo.undoDeleteEvent` (#322 seam), which reads the
            // calendar through `restoreCalendar(for:kind:)` with `.recreateDeleted` (#269).
            return try await undoDeletedEvent(snapshot).text

        case .deleteOccurrence(let snapshot, let notCarriedOver):
            // #244: a one-off at the occurrence's slot, unless the series already holds it (#285);
            // the arm's code is `SeriesExceptionsUndo.undoDeleteOccurrence` (#322 seam), which
            // resolves the calendar once, before the slot check and the write (#269 verify).
            return try await undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver).text

        case .deleteFollowingOccurrences(let title):
            // #244 D2: refused, never attempted; the record is discarded (UnrecoverableUndoError).
            throw UndoOperation.followingOccurrencesDeleteRefusal(title: title)

        case .updateEvent(_, let oldSnapshot, _):
            // Undo update = restore old values. Only updates of one-off events are recorded this
            // way; an update that touched a recurring event is a marker whose undo is refused
            // (#236, #262), and `verifiedEvent` refuses an event that repeats now. The snapshot
            // holds no rules, so `apply` writes none here (its rules branch serves delete-undo).
            // The calendar is read first (#269, PR #389 round 2): `restoreCalendar` suspends, and
            // after the #236 post-state check nothing may suspend before the write. That is about
            // actor reentrancy only (no other call of this server can run in between); a change
            // another process (Calendar.app, a sync) saves between the check and the save is not
            // excluded. When the calendar is missing, its refusal comes first and the record is kept,
            // whether the event changed, repeats now, is detached or is not found.
            let calendar = try await restoreCalendar(for: oldSnapshot, kind: .revertUpdate)
            let event = try await verifiedEvent(of: operation, verb: .undo)
            oldSnapshot.apply(to: event, calendar: calendar)
            // #274: a failed save leaves nothing pending, with or without this (measured, see
            // `updateEvent`); it clears `hasChanges` on the cached event, as `updateEvent` does.
            do {
                try eventStore.save(event, span: .thisEvent)
            } catch {
                event.rollback()
                throw error
            }
            markNeedsRefresh()
            return "Undone: restored event '\(undoVisibleTitle(oldSnapshot.title))' to previous state"

        case .updateRecurringEvent(_, let title, let kind):
            // #236: refused, never attempted; the record is discarded (UnrecoverableUndoError).
            throw UndoOperation.recurringUpdateRefusal(title: title, kind: kind)

        case .moveEvent(let movedID, let fromCalendarIdentifier, _, let title, let isSeries):
            // Undo an in-place move (#226) = move it back to the recorded calendar, while the
            // event is still in the calendar it was moved to (#236). A series is resolved as the
            // move resolved it, through the stand-in when needed (#369, `seriesMoveUndoTarget`).
            // #269: the original calendar is read as every event undo reads it (`restoreCalendar`),
            // and a missing one is refused with the way on, the record kept. It is read before the
            // #236 post-state check (PR #389 round 2), so nothing suspends between that check and
            // the write (actor reentrancy only; another process's change in between is not
            // excluded). A missing calendar is therefore refused, and the record kept, before a
            // changed, repeating, detached or missing event is.
            let original = try await restoreCalendar {
                try EventSnapshot.calendar(recorded: fromCalendarIdentifier, in: $0, identifier: { $0.calendarIdentifier },
                                           orThrow: { EventKitError.moveBackCalendarMissing(fromCalendarIdentifier: fromCalendarIdentifier, event: title) })
            }
            let event = try await verifiedEvent(of: operation, verb: .undo)
            event.calendar = original
            // #274: as above; rollback() also restores the calendar on the object (checked on device
            // 2026-10-04).
            do {
                try eventStore.save(event, span: isSeries ? .futureEvents : .thisEvent)
            } catch {
                event.rollback()
                throw error
            }
            markNeedsRefresh()
            // #435: on Google a move within one account gave a new identifier, its undo too.
            if let restoredID = event.eventIdentifier, CalendarUndoManager.identifierChanged(from: movedID, to: restoredID) {
                await CalendarUndoManager.shared.replaceEventIdentifier(movedID, with: restoredID)
                return "Undone: moved event '\(undoVisibleTitle(title))' back to its original calendar (new ID: \(restoredID))"
            }
            return "Undone: moved event '\(undoVisibleTitle(title))' back to its original calendar"

        case .moveByCopy(let original, let isSplit, let notCarriedOver, let copyID, let copy):
            // #466: the source first, through the delete-undo's own code (its calendar check, its
            // refusals, its new ID in the text); its error is thrown and nothing of the copy touched.
            // A split's source is one occurrence and goes through the occurrence undo, so #285's slot
            // check writes nothing when the series holds the slot again; a fallback copy's one-off
            // through the event undo. A missing calendar is refused in a move's words (round 2).
            // Then the copy, checked as the undo of a created event checks it (#236), and removed
            // only when found unchanged; otherwise it stays. Nothing after the restore throws
            // (`MoveByCopyUndo.run`), so the record is used up once the source is back.
            // PR #474 round 2: `run` is nonisolated, so the check and the removal are one async
            // closure formed here: it runs on this actor, and nothing suspends between the check
            // and the removal (the guard's only await is its access check, before the comparison;
            // the create-undo arm's order). That excludes this server's other calls, not a change
            // another process saves in between. A synchronous removal closure called from `run`
            // after the check ran off the actor.
            let undone = try await MoveByCopyUndo.run(
                copyID: copyID,
                restoreOriginal: {
                    guard isSplit else { return .written(try await self.undoDeletedEvent(original, kind: .undoMoveByCopy).text) }
                    let undone = try await self.undoDeletedOccurrence(original, notCarriedOver: notCarriedOver, kind: .undoMoveByCopy)
                    // Round 3: a held slot recreated nothing, so the copy is kept (`Restore`).
                    return MoveByCopyUndo.Restore(text: undone.text, outcome: undone.outcome)
                },
                checkAndRemove: {
                    let event = try await self.verifiedEvent(of: .createEvent(id: copyID, title: copy.title, created: copy), verb: .undo)
                    // Round 3: attendees are not in the #236 compare; a copy that has them now is kept.
                    guard !event.hasAttendees else { throw MoveByCopyUndo.CopyHasAttendees() }
                    try MoveByCopyUndo.removing({ try self.removeMoveCopy(event) }, describe: {
                        EventKitErrorSanitizer.writeFailureLog(handler: "undo.moveByCopy", identifier: copyID, error: $0)
                    })
                })
            markNeedsRefresh()
            return MoveByCopyUndo.message(restore: undone.restore, title: original.title, copyID: copyID, copy: undone.copy)

        case .createReminder(_, let title, _):
            // Undo create = delete. #236: a missing reminder is not found (UndoTargetMissingError:
            // the record is kept and the message names discard_id), as for events since #182;
            // this arm used to report "Undone" for a no-op. "Already gone" is not taken as done:
            // the identifier may only be unresolvable (moved to another account, recreated under
            // a new identifier by a delete-undo), and the spec keeps not-found records.
            let reminder = try await verifiedReminder(of: operation, verb: .undo)
            try removeExistingReminder(reminder, handler: "undo")
            markNeedsRefresh()
            return "Undone: removed created reminder '\(undoVisibleTitle(title))'"

        // Undo delete = recreate (`restoreDeletedReminder`, shared with the batch arm).
        case .deleteReminder(let snapshot):
            return Self.restoredReminderMessage(try await restoreDeletedReminder(snapshot))

        case .updateReminder(_, let oldSnapshot, _):
            // Undo update = restore old values
            let reminder = try await applyReminderSnapshot(oldSnapshot, for: .revertUpdate, into: { try await verifiedReminder(of: operation, verb: .undo) })
            try saveExistingReminder(reminder, handler: "undo")
            markNeedsRefresh()
            return "Undone: restored reminder '\(undoVisibleTitle(oldSnapshot.title))' to previous state"

        case .completeReminder(_, let wasCompleted, _, _, let title, _, _):
            let reminder = try await verifiedReminder(of: operation, verb: .undo)
            try apply(operation.completionWrite(undo: true, now: Date()), to: reminder)
            try saveExistingReminder(reminder, handler: "undo")
            markNeedsRefresh()
            return "Undone: set reminder '\(undoVisibleTitle(title))' completion to \(wasCompleted)"

        case .completeRecurringReminder(let before, _, _):
            return try await undoRecurringCompletion(operation, before: before)

        case .calendarOperation(let kind, _):
            // #273: refused, never attempted; the record is discarded (UnrecoverableUndoError).
            throw UndoOperation.calendarOperationRefusal(kind: kind)

        case .batch(let ops):
            return try await undoBatch(ops).message
        }
    }

    /// #287: `undo` with `restore_available`. Only a batch can be restored in part; every other
    /// record runs the plain undo.
    func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String {
        if restoreAvailable, case .batch(let ops) = operation {
            return try await undoBatch(ops, restoreAvailable: true).message
        }
        return try await executeUndo(operation)
    }

    /// #466: removes the copy a move by copy made, after its #236 check passed. The check found it
    /// unchanged, so it has no rules (the copy was saved as a one-off) and span `this` removes it alone.
    func removeMoveCopy(_ copy: EKEvent) throws {
        try eventStore.remove(copy, span: .thisEvent)
    }

    /// The undo of a batch record: its message, and what the stores of the reminders it recreated
    /// hold differently, as data, so a batch nested in another carries them up
    /// (`undoBatchMember`; PR #282 round 6, findings 2, 9).
    func undoBatch(_ ops: [UndoOperation], restoreAvailable: Bool = false) async throws
        -> (message: String, differing: [UndoRestoredDifference], events: [UndoEventOutcome]) {
        // #244 D3 first: a member that can never be restored refuses and discards the record,
        // which must win over #248 B's refusal below, which keeps it (PR #278 round 2, finding 24).
        try verifyBatchMemberRestorable(.batch(ops), verb: .undo)
        // #287: asked to restore what it can, the batch takes the same steps through
        // `UndoBatchPartialRestore` (`undoBatchRestoringAvailable`).
        if restoreAvailable { return try await undoBatchRestoringAvailable(ops) }
        // #248 B: the calendar or list each deleted item is recreated in, read once per batch.
        try await verifyRestoreDestinations(of: ops, verb: .undo)
        // #236 D4: every sub-operation is checked before the first write. #248 A: a failed write
        // keeps only the members not yet restored (`UndoBatchExecution`). #261: a recreated
        // reminder's differing fields come back from `restoreDeletedReminder` as data
        // (`undoBatchMember`) and are collected per member; no member's message text is read back.
        let outcome = try await UndoBatchExecution.run(
            ops, verb: .undo,
            check: { try await self.verifyHistoryTarget(of: $0, verb: .undo) },
            restore: { try await self.undoBatchMember($0) },
            describe: { EventKitErrorSanitizer.writeFailureLog(handler: "undo", identifier: "batch member", error: $0) })
        // #323: what the event members did, from the outcomes they returned (an occurrence's
        // absolute-date alarm, a series' rules or exceptions restore, a slot already held); #261:
        // what a restored reminder's store holds differently (`batchUndoneMessage`).
        return (UndoOperation.batchUndoneMessage(count: outcome.texts.count, events: outcome.events, differing: outcome.differing),
                outcome.differing, outcome.events)
    }

    /// #287: a batch undo with `restore_available`: #248 B's pre-check, and when it refuses, the
    /// members whose calendar or list is in place run and the others are kept
    /// (`UndoBatchKeptUnavailable`, which `handleUndo` turns into a narrowed record and a success).
    /// The members run through `undoBatch` itself, so each gets #236's check and #248 A's part-way
    /// rule, and the restorable ones are checked once more before the first write (a calendar gone
    /// since the split refuses them whole, nothing written).
    func undoBatchRestoringAvailable(_ ops: [UndoOperation]) async throws
        -> (message: String, differing: [UndoRestoredDifference], events: [UndoEventOutcome]) {
        let (outcome, kept) = try await UndoBatchPartialRestore.run(
            ops, restoreAvailable: true,
            verify: { try await self.verifyRestoreDestinations(of: ops, verb: .undo) },
            split: { try await self.splitByRestoreDestination(ops) },
            runMembers: { members in try await self.undoBatch(members) })
        if let kept {
            throw UndoBatchKeptUnavailable(kept: kept.blocked, restored: kept.restorable, message: UndoBatchPartialRestore.keptMessage(restored: outcome.message, kept: kept))
        }
        return outcome
    }

    /// #261: the undo of `delete_reminder`, for the single arm and for each batch member. Reads the
    /// lists first and only then creates the reminder (#277), saves it through `saveNewReminder`,
    /// and returns its recorded title with the compared fields a new store holds differently
    /// (none when the save succeeded or the store holds it as written). A save that threw but that
    /// a new store finds counts as the restore, so a retry cannot make a second copy: a single
    /// undo's record is consumed, and in a batch the member counts as restored and is left out of
    /// the entry that is kept (#248). The names are data: callers build their note from them, never from text.
    func restoreDeletedReminder(_ snapshot: ReminderSnapshot) async throws -> (title: String, storeDiffers: [String]) {
        let reminder = try await applyReminderSnapshot(snapshot, for: .recreateDeleted, into: { EKReminder(eventStore: eventStore) })
        let storeDiffers = try saveNewReminder(reminder, handler: "undo.deleteReminder", restoring: true)
        markNeedsRefresh()
        return (snapshot.title, storeDiffers)
    }

    /// The message of a delete-undo: the restore, then `NewObjectSave.undoSuffix` naming the fields
    /// the store holds differently, if any. The title is shown through `undoShownTitle` (quotes
    /// replaced, control characters dropped, capped at 120 scalars), so it cannot close its quotes
    /// or start a line, and the real note is always outside the quotes (`NewObjectSaveTests`).
    /// Inside its quotes a title can still read like the note, and a literal U+2019 in it looks the
    /// same as a replaced quote.
    static func restoredReminderMessage(_ restored: (title: String, storeDiffers: [String])) -> String {
        "Undone: restored reminder '\(undoShownTitle(restored.title))'" + NewObjectSave.undoSuffix(restored.storeDiffers)
    }

    /// One member of a batch undo (#248). A deleted reminder is recreated through
    /// `restoreDeletedReminder`, and the fields its store holds differently travel as data
    /// (`UndoRestoredDifference`, which shows the title itself), so the batch texts name
    /// them (#261; PR #282 round 5, finding 1). A nested batch passes up its own members'
    /// differences (`undoBatch`, round 6, findings 2, 9; no nested batch is recorded today). A
    /// deleted event or occurrence runs the same arm as `executeUndo`, and what it did travels as
    /// data too (`UndoEventOutcome`, #323). Every other member runs `executeUndo`.
    func undoBatchMember(_ operation: UndoOperation) async throws -> UndoMemberOutcome {
        switch operation {
        case .batch(let inner):
            let undone = try await undoBatch(inner)
            return UndoMemberOutcome(text: undone.message, differing: undone.differing, events: undone.events)
        case .deleteReminder(let snapshot):
            let restored = try await restoreDeletedReminder(snapshot)
            return UndoMemberOutcome(text: Self.restoredReminderMessage(restored),
                                     differing: [UndoRestoredDifference(title: restored.title, storeDiffers: restored.storeDiffers)])
        case .deleteEvent(let snapshot):
            // #323: the same arm as `executeUndo`'s, with what it did as data.
            let undone = try await undoDeletedEvent(snapshot)
            return UndoMemberOutcome(text: undone.text, differing: [], events: undone.outcome.map { [$0] } ?? [])
        case .deleteOccurrence(let snapshot, let notCarriedOver):
            let undone = try await undoDeletedOccurrence(snapshot, notCarriedOver: notCarriedOver)
            return UndoMemberOutcome(text: undone.text, differing: [], events: [undone.outcome])
        default:
            return UndoMemberOutcome(text: try await executeUndo(operation), differing: [])
        }
    }

    /// Execute an operation again (for redo). Only completions are written again (#247).
    func executeRedo(_ operation: UndoOperation) async throws -> String {
        switch operation {
        case .createEvent, .deleteEvent, .deleteOccurrence, .deleteFollowingOccurrences, .updateEvent,
             .updateRecurringEvent, .moveEvent, .moveByCopy, .createReminder, .deleteReminder, .updateReminder,
             .calendarOperation:
            // #247: these write nothing on redo. `handleRedo` answers them itself and drops the
            // entry from the redo stack (`CalendarUndoManager.beginRedo`); this is a fallback with
            // the same text, and it writes nothing either.
            return operation.redoInstruction ?? "Nothing to redo"

        case .completeReminder(_, _, let requestedCompleted, _, let title, _, _):
            // Redo re-applies the recorded request (#196: never the opposite of
            // wasCompleted — that reopened an idempotently completed reminder), and only
            // while the reminder is in the state the undo left (#236).
            let reminder = try await verifiedReminder(of: operation, verb: .redo)
            try apply(operation.completionWrite(undo: false, now: Date()), to: reminder)
            try saveExistingReminder(reminder, handler: "redo")
            markNeedsRefresh()
            return "Redone: set reminder '\(undoVisibleTitle(title))' completion to \(requestedCompleted)"

        case .completeRecurringReminder(let before, let requestedCompleted, _):
            return try await redoRecurringCompletion(operation, before: before, requestedCompleted: requestedCompleted)

        case .batch(let ops):
            // #247: a batch of members that write nothing used to answer "Redone batch (N
            // operations)" for a no-op.
            if let instruction = operation.redoInstruction { return instruction }
            let results = try await UndoBatchExecution.run(
                ops, verb: .redo,
                check: { try await self.verifyHistoryTarget(of: $0, verb: .redo) },
                execute: { try await self.executeRedo($0) },
                describe: { EventKitErrorSanitizer.writeFailureLog(handler: "redo", identifier: "batch member", error: $0) })
            return UndoOperation.batchRedoneMessage(count: results.count)
        }
    }

    /// #269 verify: the calendars a single event undo restores into, and the batch pre-check's read
    /// too. Calendar access is checked first: without it the store lists no calendar, and every
    /// recorded calendar would be judged missing. Then the refreshed view, as
    /// `reminderListsForRestore` reads the lists.
    func eventCalendarsForRestore() async throws -> [EKCalendar] {
        try await ensureCalendarAccess()
        refreshIfNeeded()
        return eventStore.calendars(for: .event)
    }

    /// The calendar `match` picks from `eventCalendarsForRestore`; on a miss the view is marked
    /// stale and read once more before `match`'s refusal stands (`EventRestoreCalendar.resolve`, the
    /// batch pre-check's order).
    func restoreCalendar(_ match: ([EKCalendar]) throws -> EKCalendar) async throws -> EKCalendar {
        try await EventRestoreCalendar.resolve(read: { try await self.eventCalendarsForRestore() },
                                               invalidate: { self.markNeedsRefresh() }, match: match)
    }

    /// The recorded calendar of `snapshot`, by its identifier (`resolveCalendar`).
    func restoreCalendar(for snapshot: EventSnapshot, kind: EventRestoreKind) async throws -> EKCalendar {
        try await restoreCalendar { try snapshot.resolveCalendar(in: $0, identifier: { $0.calendarIdentifier }, for: kind) }
    }

    /// A completion record always yields a write (#196); the throw is unreachable by
    /// construction and exists so the arms need no force-unwrap.
    func apply(_ write: ReminderCompletionWrite?, to reminder: EKReminder) throws {
        guard let write else { throw UnrecoverableUndoError(message: "Undo record is not a completion record.") }
        write.apply(to: reminder)
    }

    /// #242: the reminder lists an undo restores into, and the one entry for every caller that
    /// resolves a recorded list with `ReminderSnapshot.resolveList`: `applyReminderSnapshot`, and a
    /// batch undo's pre-check before its first write (PR #282). Reminders access is checked first:
    /// without it the store lists no list, and every recorded list would be judged missing. The
    /// refresh runs only when this server has written since its last refresh (`markNeedsRefresh`);
    /// a list another client or an account sync added in the meantime is not covered by it, which
    /// is what the refusal's retry advice is for. `ReminderUndoWiringTests` pins this body and that
    /// the undo path reads the lists nowhere else.
    func reminderListsForRestore() async throws -> [EKCalendar] {
        try await ensureReminderAccess()
        refreshIfNeeded()
        return eventStore.calendars(for: .reminder)
    }

    /// Apply a ReminderSnapshot to the reminder `target` creates or fetches. The lists are read
    /// first (`reminderListsForRestore`), so the delete-undo arm creates its new reminder only
    /// after the read; then `ReminderSnapshot.apply(to:lists:for:now:)` resolves the list by its
    /// recorded identifier before it writes anything (#242), so a refusal leaves the reminder as
    /// it was. `ReminderUndoWiringTests` pins this body and both arms.
    private func applyReminderSnapshot(_ snapshot: ReminderSnapshot, for kind: ReminderRestoreKind,
                                       into target: () async throws -> EKReminder) async throws -> EKReminder {
        let lists = try await reminderListsForRestore()
        let reminder = try await target()
        try snapshot.apply(to: reminder, lists: lists, for: kind, now: Date())
        return reminder
    }
}

// MARK: - Input Types

struct RecurrenceRuleInput: Sendable {
    enum Frequency: Sendable {
        case daily, weekly, monthly, yearly
    }

    /// PR #420 verify round 1: bounds the parser enforces. EventKit raises an uncatchable
    /// Objective-C exception for an interval below 1 or from 2^31 to 2^32, and for a count of 0.
    static let maxInterval = 1000
    static let maxOccurrenceCount = 10_000

    /// PR #439 verify: the read tools' names for a rule. `parseRecurrenceRule` refuses them beside
    /// `recurrence`, where a caller copying a read result puts them and nothing reads them.
    static let readKeys = ["recurrence_rules", "event_recurrence_rules", "reminder_recurrence_rules"]

    /// #444, measured on iCloud: an event rule of this shape keeps the count and reads back with it,
    /// and the store expands it as a count of years, so 6 gave 22 occurrences. A rule with `interval`
    /// above 1, or with `days_of_month` as well, held its count, and so did every other frequency.
    /// A reminder held it too: completing one with a count of 3 gave three occurrences.
    /// A count of 1 held as well, and is refused on purpose: the rule should not depend on the
    /// value of the count, for a series of one, which needs no rule. An empty `days_of_month` is none.
    static func countsYearsForAnEvent(frequency: Frequency, interval: Int, daysOfWeek: [Int]?, daysOfMonth: [Int]?,
                                      occurrenceCount: Int?) -> Bool {
        frequency == .yearly && interval == 1 && occurrenceCount != nil
            && daysOfWeek?.isEmpty == false && daysOfMonth?.isEmpty != false
    }

    /// #434: the keys a `recurrence` object may have; `parseRecurrenceRule` refuses any other. The
    /// tools that do not take `excluded_occurrence_dates` refuse it with their own message.
    static func inputKeys(allowsExclusions: Bool) -> [String] {
        ["frequency", "interval", "end_date", "occurrence_count", "days_of_week", "days_of_month"]
            + (allowsExclusions ? ["excluded_occurrence_dates"] : [])
    }

    let frequency: Frequency
    let interval: Int
    let endDate: Date?
    let occurrenceCount: Int?
    let daysOfWeek: [Int]?
    let daysOfMonth: [Int]?
    /// #182 — occurrence days to exclude at creation time. Only `create_event` /
    /// `create_events_batch` populate this (parser-level caller gating); EventKit
    /// has no EXDATE, so exclusions execute as post-save occurrence removals.
    let excludedOccurrenceDates: [Date]?
}

struct StructuredLocationInput {
    let title: String
    let latitude: Double?
    let longitude: Double?
    let radius: Double?  // meters, default 100
}

struct LocationTriggerInput: Sendable {
    let title: String
    let latitude: Double
    let longitude: Double
    let radius: Double    // meters, default 100
    let proximity: EKAlarmProximity  // .enter or .leave
}

// MARK: - Errors

enum EventKitError: LocalizedError {
    private static func seriesName(_ series: String?) -> String {
        series.map { "the series' id, \($0)," } ?? "the series' id"
    }

    /// - Parameter deniedByStatus: the TCC status was already `.denied`/`.restricted`
    ///   at the gate, so `requestFullAccess` was skipped (the status-first check only
    ///   requests on `.notDetermined`). Under the `.mcpb` install this is the #154
    ///   signature — a stale Developer-ID TCC row csreq-mismatches and reads back
    ///   denied in the MCP context, while a Terminal `--setup` sees the *lying*
    ///   `.fullAccess` row and no-ops → recommending a bare `--setup` is a dead end. (#158)
    case accessDenied(type: String, isSSH: Bool = false, isNonInteractive: Bool = false, deniedByStatus: Bool = false)
    /// `.writeOnly` partial-access state (macOS 14+). User granted write-only but a read operation was attempted.
    /// Not silently downgradable — caller must surface so user can upgrade in System Settings.
    case insufficientAccess(type: String)
    /// `@unknown default` in the TCC authorization-status switch — guards against future EKAuthorizationStatus enum cases that this build doesn't recognize.
    case unknownAuthState(type: String, statusValue: Int)
    /// `@unknown default` in the `EKEntityType` switch — guards against future Apple-added entities
    /// (e.g. hypothetical `.contact`) being misattributed as a TCC-denied error when the gate
    /// calls `requestFullAccess(for:)`. Surfaces as a build-version mismatch instead. (#118)
    /// `EKEntityType.rawValue` is `UInt`; preserved as-is to avoid lossy narrowing.
    case unsupportedEntityType(rawValue: UInt)
    case calendarNotFound(identifier: String, available: [String] = [])
    case calendarNotFoundWithSource(name: String, source: String, available: [String] = [])
    case multipleCalendarsFound(name: String, sources: String)
    /// #437: `find_duplicate_events` only compares different calendars. A count only.
    /// `canNameMore` is false on a host with fewer than two calendars, where naming more cannot help.
    case tooFewCalendarsToCompare(found: Int, canNameMore: Bool)
    case eventNotFound(identifier: String)
    case reminderNotFound(identifier: String)
    case calendarNameRequired(forType: String)
    case invalidTimeRange(message: String)
    case weekdayMismatch(startDay: String, expectedDays: String)
    /// #454 verify: a stored rule on a numbered weekday, which `recurrence` cannot write.
    case weekdayOffNumberedRule(startDay: String)
    /// #461: the start is not on the rule's `days_of_month` (`MonthDayCheck`).
    case dayOfMonthMismatch(startDay: Int, expectedDays: String)
    /// #461 verify round 1: a series' start moved to another day on a rule with days_of_month.
    /// `unwritable`: the stored rule has a part `recurrence` cannot write, so Calendar is the route.
    /// `spanAll`: the call is span all, the only span the recurrence route was measured on.
    case monthDayMoveRefused(expectedDays: String, unwritable: Bool, spanAll: Bool)
    /// #182 — an excluded date lies outside the recurrence window (before the first
    /// occurrence day, or after end_date). Rejected pre-save: nothing was created.
    case exclusionOutOfWindow(date: String)
    /// #182 pass 1 — an excluded date resolved to no occurrence of the just-created
    /// series. The series was rolled back; no occurrence had been removed.
    case exclusionNoOccurrence(date: String)
    /// #182 pass 2 — removing an occurrence failed. The series was rolled back.
    case exclusionRemoveFailed(date: String)
    /// #182 verify fix — excluding the series' first occurrence is rejected pre-save:
    /// removing the DTSTART occurrence invalidates the rollback anchor, breaks the
    /// duplicate-retry heuristic (start ±30s finds no live event), and leaves the
    /// returned/undo ID pointing at a removed occurrence.
    case exclusionFirstOccurrence(date: String)
    /// #182 verify fix — the exclusion set would remove every occurrence of a
    /// count-bounded series, leaving a "created" response for an empty series.
    case exclusionRemovesAllOccurrences(excludedCount: Int, occurrenceCount: Int)
    /// #182 — the compensating delete itself failed: the series still exists with
    /// `appliedDates` exclusions applied. Partial state MUST be reported, never silent.
    case exclusionRollbackFailed(masterId: String, appliedDates: [String])
    /// #182 — duplicate heuristic matched an existing series whose exclusion set
    /// differs from the request (a requested date still has a live occurrence).
    case exclusionConflict(existingId: String, date: String)
    /// #190 — all-day events are floating calendar days; a timezone would strip
    /// the all-day flag and shift occurrence days (defense-in-depth behind the
    /// handler-level guard).
    case allDayTimezoneConflict
    /// #226: a move the policy refuses. `reason` is one of `EventMovePolicy`'s fixed strings
    /// (no EventKit text, no user input), so it is safe to return verbatim.
    case moveRefused(reason: String)
    /// #326: a write refused because the series resolved through its first remaining occurrence
    /// (the stand-in): saving the whole series from it splits it into a new one with a new event
    /// id, and changing its account or recurrence from it is not supported. `reason` is one of
    /// the fixed strings on `EventKitManager` (`standInSplitReason`, `standInAccountReason`,
    /// `standInSeriesPropertyReason`): no EventKit text, no user input.
    case standInRefused(reason: String)
    /// #274: a save or a removal of an existing reminder failed, and it stays pending in the store,
    /// where the next save of anything can commit it (`ExistingReminderSave`). `code` is sanitized.
    case reminderSaveMayLand(code: String)
    case reminderRemovalMayLand(code: String)
    /// The same for a reminder list. A removal takes every reminder in the list.
    case listChangeMayLand(code: String)
    case listRemovalMayLand(code: String)
    /// #288: the event lookup raised, so it is not known whether the event exists. Not an
    /// `UnrecoverableUndoError`: an undo that meets it keeps its record.
    case eventLookupFailed(identifier: String)
    /// #288: the same, met by undo or redo, with what to do about the record.
    case historyLookupFailed(verb: UndoHistoryVerb)
    /// #416: a whole-series write addressed through the identifier of one occurrence that was
    /// edited on its own (`DetachedOccurrenceSpan`). `reason` is one of its fixed strings.
    case occurrenceAddressRefused(reason: String)
    /// PR #439 verify: `recurrence` or `clear_recurrence` on one occurrence (span this), or
    /// `clear_recurrence` from one occurrence (span future), refused before anything is written by
    /// `refusesRecurrenceChangeOnOccurrence` and `refusesClearRecurrenceFromOccurrence`.
    case recurrenceChangeOnOccurrenceRefused(clearing: Bool, address: EventKitManager.RecurrenceChangeAddress)
    /// #451: an `update_event` shape measured to lose occurrences. `reason` is one of the fixed
    /// strings on `SeriesRuleWrite`.
    case seriesWriteRefused(reason: String)
    /// #285 — restoring the exceptions of a series (undo of a whole-series delete) stopped and was
    /// rolled back: the recreated series and anything created for its exceptions were deleted
    /// again, so nothing of the restore remains and the undo can be retried.
    case seriesExceptionsRestoreFailed(reason: String)
    /// #289: a new reminder or list whose save threw, and whose check could not be answered (a new
    /// store with no sources), was kept: it may already be saved or be written by the next save.
    /// `code` is the save's sanitized code.
    case saveUnchecked(code: String)
    /// #328: `delete_calendar` with `require_empty` found the calendar not empty; nothing deleted.
    case calendarNotEmpty(reason: String)
    /// #253 verify round 2 (D1): saving a copy failed while it carried alarms some calendars
    /// refuse. Raised for any failure of such a save, so the message names the alarms as a
    /// possible cause only and gives no instruction (round 3: a caller that followed one would
    /// delete the user's alarms after a network error). `code` is the sanitized code of the
    /// underlying error and `alarmKinds` are `AlarmSnapshot.kindsSomeCalendarsMayRefuse`
    /// names, so the message holds no EventKit text and no user input.
    case copyRefused(code: String, alarmKinds: [String])
    /// #242: reminder undo found no list under the recorded identifier (the list was deleted, or
    /// its account is turned off or not synced yet), or the record has none. Nothing was written
    /// for this reminder and the record is kept (`UndoFailureDisposition.of` gives `.restore`, the
    /// #206 / #236 D2 posture for not-found). The claim is about this reminder only: in a batch
    /// undo other members may already have been written. `kind` decides what the message says
    /// giving the undo up loses. The message names the reminder through `undoShownTitle` (left out
    /// when it shows as nothing) and neither the list nor its account (#290): a shared list's title
    /// is set by someone else and an account name is often an e-mail address (#37), and this text
    /// is trusted and sits next to the `discard_id` instruction, as the batch pre-check's refusal
    /// names none of them (PR #282).
    case undoListMissing(reminder: String, hasIdentifier: Bool, kind: ReminderRestoreKind)
    /// #269: the event counterpart of `undoListMissing`. An event undo found no calendar under the
    /// recorded identifier (the calendar was deleted, or its account is turned off or not synced
    /// yet), or the record has none: the delete-undo and occurrence-undo restore into the calendar
    /// the event was deleted from, the update-undo into the one it was in before the update, the
    /// move-undo into the one it was moved from (`.moveEvent`, also through the stand-in, #369).
    /// Nothing was written for this event and the record is kept (`.restore`), as for every
    /// not-found. The message names the event through `undoShownTitle` and neither the calendar nor
    /// its account (PR #389 verify round 1, as #290 for lists): a subscribed or shared calendar's
    /// title is set by someone else and an account name is often an e-mail address (#37), and this
    /// text is trusted and sits next to the `discard_id` instruction. So the case carries neither.
    case undoCalendarMissing(event: String, hasIdentifier: Bool, kind: EventRestoreKind)

    var errorDescription: String? {
        switch self {
        case .accessDenied(type: let type, isSSH: let isSSH, isNonInteractive: let isNonInteractive, deniedByStatus: let deniedByStatus):
            return EventKitManager.accessDeniedMessage(
                type: type,
                isSSH: isSSH,
                isNonInteractive: isNonInteractive,
                isMCPB: EventKitManager.isMCPBClaudeDesktopInstall,
                deniedByStatus: deniedByStatus,
                setupHint: EventKitManager.resolvedSetupCommandHint(),
                attribution: EventKitManager.currentAttribution(),
                restrictedByPolicy: deniedByStatus && EventKitManager.currentStatusIsRestricted(typeName: type)
            )
        case .insufficientAccess(let type):
            return """
            \(type) access is write-only — read operations need full access. To upgrade:
            1. Open System Settings → Privacy & Security → \(type)
            2. Find CheICalMCP and switch from "Write only" to "Full access"
            3. Restart Claude Desktop/Code
            (write-only access is a macOS 14+ partial-grant state introduced for privacy-conscious workflows; read operations explicitly cannot fall back silently)
            """
        case .unknownAuthState(let type, let statusValue):
            return """
            \(type) access in unknown authorization state (raw value: \(statusValue)). This build doesn't recognize the EKAuthorizationStatus case macOS returned — likely a future macOS adding a new partial-access state. Workarounds:
            1. Run 'CheICalMCP --setup' from Terminal to force a fresh authorization round-trip
            2. Or \(EventKitManager.switchOnStep(pane: type))
            3. Or update CheICalMCP to a newer release that recognizes the new state
            """
        case .unsupportedEntityType(let rawValue):
            return """
            EventKit entity type \(rawValue) is not recognized by this CheICalMCP build. \
            Likely a future Apple-added EKEntityType case. Update CheICalMCP to a release \
            that supports the new entity, or report the raw value at \
            https://github.com/PsychQuant/che-ical-mcp/issues.
            """
        case .calendarNotFound(let id, _):
            // #37 F1: do NOT interpolate `available` into the trusted-message
            // path. EKCalendar.title comes from CalendarStore which includes
            // shared/subscribed/CalDAV calendars whose titles are set by remote
            // publishers — same threat class as #21/#27 .ics attack. The
            // `available` list stays on the error and reaches no caller.
            return "Calendar not found: \(id)"
        case .calendarNotFoundWithSource(let name, let source, _):
            // Same reasoning as `calendarNotFound`: drop `available:` from the
            // trusted-message body. `name` and `source` are the caller's own
            // input echo (safe by R5).
            return "Calendar '\(name)' not found in source '\(source)'"
        case .multipleCalendarsFound(let name, _):
            // Same reasoning as the calendarNotFound cases above: `sources` is
            // a comma-joined list of EKSource.title (CalDAV-server-controllable
            // for delegated calendars). Caller can re-derive the disambiguation
            // hint via `list_calendars` tool, which goes through the proper
            // UntrustedContentWrapper path.
            return "Multiple calendars found with name '\(name)'. Please specify calendar_source to disambiguate (use list_calendars to enumerate)."
        case .eventNotFound(let id):
            return "Event not found: \(id)"
        case .reminderNotFound(let id):
            return "Reminder not found: \(id)"
        case .calendarNameRequired(let type):
            return "calendar_name is required for creating \(type). Use list_calendars to see available options."
        case .invalidTimeRange(let message):
            return "Invalid time range: \(message)"
        case .weekdayMismatch(let startDay, let expectedDays):
            return "The start falls on \(startDay), which is not in days_of_week [\(expectedDays)]. Pass a start_time on one of those days, or recurrence with the rule's other fields and days_of_week that include that day."
        case .dayOfMonthMismatch(let startDay, let expectedDays):
            return "The start falls on day \(startDay) of the month, which is not in days_of_month [\(expectedDays)]. Pass a start_time on one of those days, or recurrence with the rule's other fields and days_of_month that include that day. Nothing was written."
        case .monthDayMoveRefused(let expectedDays, let unwritable, let spanAll):
            let measured = "This series repeats on days_of_month [\(expectedDays)], and moving its start to another day with no recurrence in the call changes it wrongly: measured on iCloud, a move to a day off the list made that day part of the rule, and a move to another day on it put two occurrences on one day. Nothing was written. To change the time, give start_time on the same day."
            if unwritable {
                return measured + " This series' rule has a part this tool cannot write (a day counted from the end of the month, a numbered weekday or position, or months, weeks or days of the year), so to move it, change the series in Calendar."
            }
            if !spanAll {
                return measured + " From one occurrence on, the recurrence route was not measured, and from a later occurrence a count is refused (#443): to move the whole series use span all, or change the series in Calendar."
            }
            return measured + " To move it, pass recurrence with every field of the series' rule as list_events shows it (frequency, interval, days_of_week, days_of_month and its bound, with days that include the new start's day, and an end_date no earlier than the last occurrence's new start, or the write is refused, #509) together with start_time, on span all: measured clean on iCloud for a monthly series on days_of_month only, within one month; not for yearly series, a rule that also has days_of_week, a move to another month, or a series with an occurrence edited on its own."
        case .weekdayOffNumberedRule(let startDay):
            return "This series repeats on a numbered weekday, such as the first Monday of the month, and the start would fall on \(startDay). This tool cannot write a rule like that, so change the series in Calendar. Nothing was written."
        case .exclusionOutOfWindow(let date):
            return "excluded_occurrence_dates: \(date) is outside the recurrence window (before the first occurrence day or after end_date). Nothing was created."
        case .exclusionNoOccurrence(let date):
            return "excluded_occurrence_dates: no occurrence exists on \(date). The new series was rolled back — no occurrences were removed and no event remains."
        case .exclusionRemoveFailed(let date):
            return "excluded_occurrence_dates: removing the occurrence on \(date) failed. The new series was rolled back — no event remains."
        case .exclusionFirstOccurrence(let date):
            return "excluded_occurrence_dates: \(date) is the first occurrence of the series. Excluding the first occurrence is not supported — adjust start_time so the series begins at the first wanted occurrence instead. Nothing was created."
        case .exclusionRemovesAllOccurrences(let excludedCount, let occurrenceCount):
            return "excluded_occurrence_dates: excluding \(excludedCount) date(s) from a series capped at \(occurrenceCount) occurrence(s) would remove every occurrence. Nothing was created — reduce the exclusions or don't create the series."
        case .exclusionRollbackFailed(let masterId, let appliedDates):
            return "excluded_occurrence_dates: exclusion failed AND the compensating delete failed. The series (event ID \(masterId)) still exists with these exclusions already applied: [\(appliedDates.joined(separator: ", "))]. Delete it manually with delete_event span:\"all\" or retry."
        case .allDayTimezoneConflict:
            return "all_day events are floating calendar days — timezone does not apply. Omit timezone, or set all_day to false for a timed event."
        case .moveRefused(let reason):
            return reason
        case .standInRefused(let reason):
            return reason
        case .reminderSaveMayLand(let code):
            return "The reminder could not be saved (\(code)), but the change may still be written by the next save this server makes, and that write would have no undo record of its own. Reading the reminder back now does not rule this out: an unchanged reminder does not mean the change is gone."
        case .reminderRemovalMayLand(let code):
            return "The reminder could not be deleted (\(code)), but it may still be deleted by the next save this server makes, and that deletion would have no undo record of its own. Reading the reminders back now does not rule this out: seeing it does not mean it stays."
        case .listChangeMayLand(let code):
            return "The reminder list could not be saved (\(code)), but the change may still be written by the next save this server makes, and that change would have no undo record of its own: undo reverts the newest recorded operation, not this one. Reading the list back now does not rule this out: an unchanged list does not mean the change is gone."
        case .listRemovalMayLand(let code):
            return "The reminder list could not be deleted (\(code)), but the list and every reminder in it may still be deleted by the next save this server makes, and that deletion would have no undo record of its own: undo reverts the newest recorded operation, not this one, so do not call undo to cancel it. Reading the lists back now does not rule this out: seeing it does not mean it stays."
        case .eventLookupFailed(let identifier):
            return "\(EventKitManager.eventLookupFailedReason): \(identifier)"
        case .historyLookupFailed(let verb):
            let kept = verb == .undo ? "This history entry was kept" : "This redo entry was kept"
            let giveUp = verb == .undo
                ? "ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id"
                : "ask the user whether to give up this redo; any new change clears the redo history"
            return "Cannot \(verb.rawValue): the event lookup failed, so this event may still exist, and nothing was written. \(kept), so try again. If it keeps failing, \(giveUp)."
        case .occurrenceAddressRefused(let reason):
            return reason
        case .recurrenceChangeOnOccurrenceRefused(let clearing, let address):
            // Not delete_event: it takes the occurrence named as well, and undo refuses it.
            let ending = "To end a series at an occurrence, call update_event with the series' id, span 'all', and recurrence holding the series' whole rule with end_date on that day after the occurrence's start, such as 23:59:59: a bare date ends before that day's occurrence. Later occurrences are deleted, also one edited on its own. On a series that has started, an end_date before now is refused, as one before an occurrence that happened deletes it; on a series with an occurrence_count, only a call with the series' id and span 'all' can tell whether it still has occurrences to come, and other calls pass only the series' own bound (#451)."
            let wholeSeries = "span 'all' leaves one event on the series' first day and deletes the other occurrences"
            switch (clearing, address) {
            case (false, .seriesId):
                return "The recurrence rule belongs to the whole series, so it cannot be changed on one occurrence (occurrence_date with span 'this'). Pass span 'all' for the whole series, or span 'future' with occurrence_date to change it from that occurrence on. Nothing was written."
            case (true, .seriesId):
                return "clear_recurrence removes the rule of the whole series, so it cannot start from one occurrence (occurrence_date with span 'this' or 'future'): \(wholeSeries). \(ending) Nothing was written."
            case (false, .occurrenceOwnId(let series)):
                return "This id is one occurrence edited on its own, and the recurrence rule belongs to the whole series. Call update_event with \(Self.seriesName(series)) instead: span 'all' for the whole series, or span 'future' with the occurrence_date of an occurrence not edited on its own. Nothing was written."
            case (true, .occurrenceOwnId(let series)):
                return "This id is one occurrence edited on its own, and clear_recurrence removes the rule of the whole series. Call update_event with \(Self.seriesName(series)) instead: \(wholeSeries). \(ending) Nothing was written."
            }
        case .seriesWriteRefused(let reason):
            return reason
        case .seriesExceptionsRestoreFailed(let reason):
            return reason
        case .saveUnchecked(let code):
            return "The save failed (\(code)), and a new store could not be read to check whether it was saved, so the item was not removed. It may already be saved. If it was not, it stays pending in this server's store, and the next save by this server writes it: a later row of the same batch, or a retry, which would then leave two. If it can never be written, later saves by this server may fail until it restarts (not tried), and it is dropped if the server restarts first (not tried). A check made right away proves nothing: a new store did not see such an item on device, while through this server a pending item may be listed, and a pending reminder list may be reported as existing by create_calendar, without being saved (not tried). Do not create it again until another save by this server has written it or the server has restarted. This item has no undo entry: undo removes the newest recorded operation, not this item; delete it by hand if it is not wanted."
        case .tooFewCalendarsToCompare(let found, let canNameMore):
            let needs = "find_duplicate_events compares events in different calendars, so it needs at least two"
            guard canNameMore else { return "\(needs); this host has \(found). Nothing was returned." }
            return "\(needs); \(found) found. Nothing was returned. Name two or more in calendar_names (list_calendars shows them)."
        case .calendarNotEmpty(let reason):
            return reason
        case .copyRefused(let code, let alarmKinds):
            return "Saving the copy failed (\(code)); the original event was not removed. The copy carries \(alarmKinds.joined(separator: ", ")), which some calendars refuse, so they are one possible cause."
        case .undoListMissing(let reminder, let hasIdentifier, let kind):
            let shown = undoShownTitle(reminder)
            let named = shown.isEmpty ? "" : " (reminder '\(shown)')"
            let which = kind == .recreateDeleted
                ? "the deletion of a reminder\(named): the list it was in when it was deleted"
                : "the update of a reminder\(named): the list it was in before the update"
            let state = hasIdentifier
                ? "is not available (deleted, or its account turned off or still syncing); it was not found under its recorded identifier"
                : "was recorded without an identifier, so it cannot be found"
            // Without an identifier the entry can never be undone, only given up.
            let blocked = hasIdentifier ? "until it is undone or given up" : "until it is given up"
            let retry = hasIdentifier
                ? " Run undo again if the list's account may be turned off or still syncing; if the list was deleted, no retry can find it."
                : ""
            let loss = kind == .recreateDeleted
                ? "Giving up this undo cannot be reversed, and this tool cannot recover the deleted reminder afterwards"
                : "Giving up this undo cannot be reversed; the reminder stays as it is now"
            return "Cannot undo \(which) \(state). Undo does not use another list of the same name. Nothing was written for this reminder and the history entry was kept; older undo entries stay blocked \(blocked).\(retry) \(loss): ask the user whether to give it up; if they agree, read undo_history and call undo with discard_id set to its id."
        case .undoCalendarMissing(let event, let hasIdentifier, let kind):
            let shown = undoShownTitle(event)
            let named = shown.isEmpty ? "" : " (event '\(shown)')"
            let which: String
            let loss: String
            switch kind {
            case .recreateDeleted:
                which = "the deletion of an event\(named): the calendar it was in when it was deleted"
                loss = "Giving up this undo cannot be reversed, and this tool cannot recover the deleted event afterwards"
            case .recreateDeletedOccurrence:
                which = "the deletion of an occurrence of an event\(named): the calendar it was in when it was deleted"
                loss = "Giving up this undo cannot be reversed, and this tool cannot recover the deleted occurrence afterwards"
            case .revertUpdate:
                which = "the update of an event\(named): the calendar it was in before the update"
                loss = "Giving up this undo cannot be reversed; the event stays as it is now"
            case .moveBack:
                which = "the move of an event\(named): the calendar it was moved from"
                loss = "Giving up this undo cannot be reversed; the event stays in the calendar it was moved to"
            case .undoMoveByCopy:
                which = "the move of an event\(named): the calendar it was moved from"
                loss = "Giving up this undo cannot be reversed; the copy the move made stays in the calendar it was moved to, if it is still there"
            }
            let state = hasIdentifier
                ? "is not available (deleted, or its account turned off or still syncing); it was not found under its recorded identifier"
                : "was recorded without an identifier, so it cannot be found"
            // Without an identifier the entry can never be undone, only given up.
            let blocked = hasIdentifier ? "until it is undone or given up" : "until it is given up"
            let retry = hasIdentifier
                ? " Run undo again if the calendar's account may be turned off or still syncing; if the calendar was deleted, no retry can find it."
                : ""
            // The way on in `UndoTargetChangedError`'s words: the user is asked and the entry
            // discarded; no other tool is named (#377).
            return "Cannot undo \(which) \(state). Undo does not use another calendar of the same name. Nothing was written for this event and this history entry was kept; older undo entries stay blocked \(blocked).\(retry) \(loss). To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id."
        case .exclusionConflict(let existingId, let date):
            return "An existing series (event ID \(existingId)) matches this event but still has an occurrence on \(date) — its exclusion set differs from the request. Not modifying the existing series; adjust it explicitly or change the request."
        }
    }
}

extension EventKitError: TrustedErrorMessage {}

extension EventKitError {
    /// The sanitized code a may-land error carries (#274), for a log line that outlives the error.
    var mayLandCode: String? {
        if case .reminderSaveMayLand(let code) = self { return code }
        return nil
    }
}

extension EventKitError {
    /// #269: the refusal of a move-undo whose original calendar no longer resolves, from what the
    /// `.moveEvent` record holds.
    static func moveBackCalendarMissing(fromCalendarIdentifier: String, event: String) -> EventKitError {
        EventSnapshot.calendarMissing(recordedIdentifier: fromCalendarIdentifier, event: event, for: .moveBack)
    }
}

extension UndoOperation {
    /// #269: `EventKitError.moveBackCalendarMissing` for a `.moveEvent` record; nil for any other
    /// record, which has no calendar it was moved from.
    var moveBackCalendarMissing: EventKitError? {
        guard case .moveEvent(_, let from, _, let title, _) = self else { return nil }
        return .moveBackCalendarMissing(fromCalendarIdentifier: from, event: title)
    }
}

// MARK: - Batch Operation Results

/// Result of a batch EventKit mutation surfaced to MCP responses.
///
/// `failures[].error` is forwarded verbatim into the wire response; the value
/// is therefore part of the MCP contract. The `failures[].error` string is
/// produced by **one of three paths** — two are catch-handlers, one is a
/// raise-without-catch — pick by call site:
///
/// 1. **Pre-catch raise (no catch needed)** — author-controlled English
///    strings (e.g. `"Reminder not found"`, `"Reminder is no longer
///    completed"`) appended directly to `failures` before the catch path
///    runs. These are guard-style invariants, not error wraps; no sanitizer
///    is applied because no `Error` was thrown.
/// 2. **`EventKitErrorSanitizer.sanitize(_:)`** — direct binding inside the
///    `deleteRemindersBatch` catch (this file only) for the
///    `cleanup_completed_reminders` flow per spec R3 (preserves the narrow
///    `[0-9]+` value-domain).
/// 3. **`EventKitErrorSanitizer.writeFailureLog(handler:identifier:error:)`**
///    — spec R7 helper used at 10 non-cleanup catch sites across the
///    project (1 in `EventKitManager.deleteEventsBatch`, 9 in `Server.swift`
///    handlers). Combines `sanitizeForResponse(_:)` + stderr write + the
///    response token in one call.
///
/// Catch-block paths that wrap `error.localizedDescription` MUST route
/// through (2) or (3) so Apple-produced text never reaches the client
/// (see #32, #37). Spec R3/R7 numbering originates from the archived change
/// proposal `2026-04-26-extend-error-sanitizer-dispatch`; current
/// `openspec/specs/eventkit-error-sanitization/spec.md` carries the
/// requirements as prose, not as `R<N>` anchors. See
/// [`EventKitErrorSanitizer`](EventKitErrorSanitizer.swift) for the full
/// sanitizer surface.
struct BatchDeleteResult {
    /// #274: the response field for `mayLandCount`, shared by `delete_reminders_batch` and
    /// `cleanup_completed_reminders`, whose rows are bound to stable codes (spec R3).
    static let failedRowsNote = "Rows that failed with a code may already be deleted by a later row of this call, or may be deleted by the next save this server makes, with no undo record of their own. Reading the reminders back now does not rule this out: seeing one does not mean it stays."

    /// The field to add to a response: nothing when no row can still land.
    var failedRowsNoteField: [String: Any] {
        mayLandCount > 0 ? ["failed_rows_note": Self.failedRowsNote] : [:]
    }

    let successCount: Int
    let failedCount: Int
    let failures: [(identifier: String, error: String)]
    /// #274: rows whose removal threw: unlike a row that was not found or was refused, it can still
    /// land with the next save (`ExistingReminderSave`). The row itself keeps its stable code.
    var mayLandCount: Int = 0
    /// Span "future" items an earlier removal of their series already reached (#325).
    var coveredCount: Int = 0
    /// #452 review r1 item 3: rows named by id that deleted an occurrence and the later ones of its
    /// series (span future on `<series>/RID=...`); their undo refuses the whole batch's undo.
    var followingOccurrencesDeleted: [String] = []
    /// #436 (PR #465 verify r1): series rows deleted from their first occurrence edited on its own,
    /// with span future. That delete cannot be undone, so it is kept out of the batch's undo record
    /// (which it would make refused as a whole) and reported per row instead.
    var throughFirstOccurrence: [(identifier: String, occurrenceID: String)] = []
}

struct DuplicatePair: Sendable {
    let event1Id: String
    let event1Title: String
    let event1Calendar: String
    let event1CalendarSource: String
    let event1StartDate: Date
    let event2Id: String
    let event2Title: String
    let event2Calendar: String
    let event2CalendarSource: String
    let event2StartDate: Date
    let timeDifferenceSeconds: Int
}
