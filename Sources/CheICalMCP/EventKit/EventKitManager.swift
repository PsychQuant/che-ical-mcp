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
    // Internal for same-actor feature extensions; still actor-isolated.
    let eventStore: EKEventStore
    private let authorizationSource: AuthorizationStatusSource
    private var needsRefresh = false

    static let shared = EventKitManager()

    /// Singleton invariant: production code MUST go through `EventKitManager.shared`.
    /// Tests inject a mock probe via `EventKitManager.forTesting(probe:)` (DEBUG-only
    /// factory below). The init itself is `fileprivate` so only `shared` and the
    /// test factory in this file can construct instances. (#115)
    ///
    /// - Parameter authorizationSource: Probe for TCC state reads + access requests.
    ///   Default wires `LiveAuthorizationStatusSource` sharing the same `EKEventStore`
    ///   instance so request attribution matches data-ops.
    fileprivate init(authorizationSource: AuthorizationStatusSource? = nil) {
        let store = EKEventStore()
        self.eventStore = store
        self.authorizationSource = authorizationSource ?? LiveAuthorizationStatusSource(store: store)
    }

    #if DEBUG
    /// Test-only factory for injecting a custom `AuthorizationStatusSource` (e.g. a mock
    /// that returns `.notDetermined` without prompting). Production callers must use
    /// `EventKitManager.shared` — see fileprivate `init` above for the singleton invariant. (#115)
    static func forTesting(probe: AuthorizationStatusSource) -> EventKitManager {
        EventKitManager(authorizationSource: probe)
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
        let argv0 = CommandLine.arguments.first ?? ""
        let resolved = BinaryPathResolver.resolveArgv0(argv0)
        return resolved.contains("Claude Extensions/local.mcpb.")
    }()

    /// Pure formatter for the binary-specific `--setup` remediation hint (#163).
    /// The path is injected (not read from globals) so denial-message wiring is
    /// unit-testable deterministically; control chars in the path are escaped so the
    /// hint is safe to surface in a response or a terminal.
    static func setupCommandHint(binaryPath: String) -> String {
        let safe = EventKitErrorSanitizer.escapeForStderr(binaryPath)
        return "\"\(safe)\" --setup"
    }

    /// Resolve the running binary's canonical path (argv[0] via `BinaryPathResolver`, the
    /// same realpath(3) path `--print-tcc-path` / the banner use) and format the `--setup`
    /// remediation hint. The `.mcpb` install's binary lives at a buried path users can't
    /// easily locate, so denial messages surface the exact command to grant THIS binary's
    /// TCC permission — the foreground `--setup` is what makes the dialog present (#163).
    static func resolvedSetupCommandHint() -> String {
        let argv0 = CommandLine.arguments.first ?? AppVersion.name
        return setupCommandHint(binaryPath: BinaryPathResolver.resolveArgv0(argv0))
    }

    /// Pure formatter for the `EventKitError.accessDenied` remediation message. Every
    /// environment signal (`isMCPB`, `deniedByStatus`) and the resolved `--setup` hint are
    /// injected — not read from globals — so branch selection is unit-testable deterministically
    /// (same rationale as `setupCommandHint(binaryPath:)`; `isMCPBClaudeDesktopInstall` is a
    /// path-derived static that a test cannot flip). `deniedByStatus` selects the #154 dead-end
    /// variant that must NOT lead with `--setup`, because a bare `--setup` cannot re-prompt a
    /// status that is already `.denied` (the status-first check only requests on `.notDetermined`). (#158)
    static func accessDeniedMessage(
        type: String,
        isSSH: Bool,
        isNonInteractive: Bool,
        isMCPB: Bool,
        deniedByStatus: Bool,
        setupHint: String
    ) -> String {
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
            2. Or manually add CheICalMCP in: \
            System Settings → Privacy & Security → \(type)
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
            2. Or clear the stale/mismatched row so a fresh grant can be minted: \
            `tccutil reset \(type) com.checheng.CheICalMCP`, then re-run \(setupHint) from Terminal \
            (now first-run → the dialog can present)
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
        return """
        \(type) access denied. Please grant permission:
        1. Open System Settings → Privacy & Security → \(type)
        2. Enable access for the MCP server or Terminal
        3. Or grant this exact binary access by running its setup from Terminal: \
        \(setupHint)
        4. Restart Claude Desktop/Code
        """
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
    }

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

        // 1. Exact match (case-sensitive)
        var calendars = allCalendars.filter { cal in
            cal.title == name &&
            (source == nil || cal.source.title == source)
        }

        // 2. Case-insensitive fallback
        if calendars.isEmpty {
            let lowerName = name.lowercased()
            let lowerSource = source?.lowercased()
            calendars = allCalendars.filter { cal in
                cal.title.lowercased() == lowerName &&
                (lowerSource == nil || cal.source.title.lowercased() == lowerSource)
            }
        }

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

        // 1. Exact match (case-sensitive)
        var calendars = allCalendars.filter { cal in
            cal.title == name &&
            (source == nil || cal.source.title == source)
        }

        // 2. Case-insensitive fallback
        if calendars.isEmpty {
            let lowerName = name.lowercased()
            let lowerSource = source?.lowercased()
            calendars = allCalendars.filter { cal in
                cal.title.lowercased() == lowerName &&
                (lowerSource == nil || cal.source.title.lowercased() == lowerSource)
            }
        }

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
            return CreateCalendarResult(calendar: existing, isDuplicate: true)
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
        // save, so it is discarded unless a new store finds it. An event calendar is saved as
        // before: in the failure classes tried, a failed one was not written by a later save
        // (see NewObjectSave).
        if NewObjectSave.keepsFailedInsert(entityType) {
            try NewObjectSave.run(save: { try eventStore.saveCalendar(calendar, commit: true) },
                                  committed: { NewObjectSave.freshStoreFinds { $0.calendar(withIdentifier: calendar.calendarIdentifier) != nil } },
                                  discard: { try eventStore.removeCalendar(calendar, commit: false) },
                                  report: { Self.logNewObjectOutcome(handler: "createCalendar", identifier: calendar.calendarIdentifier, $0) })
        } else {
            try eventStore.saveCalendar(calendar, commit: true)
        }
        markNeedsRefresh()
        return CreateCalendarResult(calendar: calendar, isDuplicate: false)
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

        if let t = title { calendar.title = t }
        if let c = color { calendar.cgColor = parseColor(c) }

        try eventStore.saveCalendar(calendar, commit: true)
        markNeedsRefresh()
        return calendar
    }

    func deleteCalendar(identifier: String) async throws {
        try await ensureCalendarAccess()
        try await ensureReminderAccess()

        guard let calendar = eventStore.calendar(withIdentifier: identifier) else {
            throw EventKitError.calendarNotFound(identifier: identifier)
        }

        try eventStore.removeCalendar(calendar, commit: true)
        markNeedsRefresh()
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
        return events.first { $0.title == title }
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

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return eventStore.events(matching: predicate)
    }

    /// Validates that a timed event's start is strictly before its end.
    ///
    /// All-day events are exempt (their day-range / same-instant representation is valid).
    /// Shared by `createEvent` and `updateEvent` so both reject inverted / zero-duration
    /// timed events consistently — previously only `updateEvent` guarded this, letting
    /// `createEvent` persist invalid events (#160).
    ///
    /// - Parameter hint: optional caller-specific guidance appended to the error message
    ///   (e.g. `updateEvent`'s "provide both start_time and end_time" advice).
    static func validateTimeRange(start: Date, end: Date, isAllDay: Bool, hint: String? = nil) throws {
        guard start >= end, !isAllDay else { return }
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
        if let existing = findDuplicateEvent(title: title, startDate: startDate, calendar: calendar) {
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
        if let rule = recurrenceRule, rule.frequency == .weekly, let days = rule.daysOfWeek, !days.isEmpty {
            var cal = Calendar.current
            if let tz = timezone { cal.timeZone = tz }
            let weekday = cal.component(.weekday, from: startDate) // 1=Sun, 7=Sat
            if !days.contains(weekday) {
                let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                let startDay = dayNames[weekday]
                let expectedDays = days.compactMap { ($0 >= 1 && $0 <= 7) ? dayNames[$0] : nil }.joined(separator: ", ")
                throw EventKitError.weekdayMismatch(
                    startDay: startDay,
                    expectedDays: expectedDays
                )
            }
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

    func updateEvent(
        identifier: String,
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
    ) async throws -> EKEvent {
        try await ensureCalendarAccess()

        // #236 (PR #259 verify #5): refreshed, so the snapshot undo restores is not a stale copy
        // that would write back over an edit made elsewhere before this call.
        guard let masterEvent = freshEvent(id: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }

        // Snapshot before update for undo
        let oldSnapshot = EventSnapshot(from: masterEvent)
        let hadRules = masterEvent.hasRecurrenceRules

        // For recurring events, resolve the specific occurrence when needed.
        // When applyToAll is true, operate on master event directly (correct for "all" series updates).
        // "this" or "future" on recurring → require occurrence_date to find the right occurrence.
        let event: EKEvent
        if !masterEvent.hasRecurrenceRules {
            event = masterEvent
        } else if applyToAll {
            // "all" = modify entire series via master event + .futureEvents
            event = masterEvent
        } else if let date = occurrenceDate {
            guard let occurrence = findOccurrence(identifier: identifier, on: date, in: timezone ?? masterEvent.timeZone) else {
                throw EventKitError.eventNotFound(identifier: "\(identifier) (no occurrence on \(date))")
            }
            event = occurrence
        } else {
            throw EventKitError.invalidTimeRange(
                message: "For recurring events, occurrence_date is required to identify which occurrence to modify."
            )
        }

        if let t = title { event.title = t }

        // Handle time updates carefully to prevent invalid state (startDate > endDate)
        // When only startDate is provided, preserve the original duration
        if let newStart = startDate {
            let originalDuration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = newStart
            if endDate == nil {
                // Preserve original event duration when only start time changes
                event.endDate = newStart.addingTimeInterval(originalDuration)
            }
        }
        if let newEnd = endDate {
            event.endDate = newEnd
        }

        // Validate time range (shared guard with createEvent — #160)
        try Self.validateTimeRange(
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            hint: "When changing the date, provide both start_time and end_time."
        )

        if let n = notes { event.notes = n }
        if let l = location { event.location = l }
        if let a = isAllDay { event.isAllDay = a }

        // #190 — resolved-state check: whether all-day came from this request or
        // the stored event, pairing it with a non-nil timezone strips the flag.
        // clear_timezone remains legal (nil-ing the tz of an all-day event is fine).
        if event.isAllDay, timezone != nil, !clearTimezone {
            throw EventKitError.allDayTimezoneConflict
        }

        if let urlString = url, let eventURL = URL(string: urlString) {
            event.url = eventURL
        }

        // Update per-event timezone (#12)
        if clearTimezone {
            event.timeZone = nil
        } else if let tz = timezone {
            event.timeZone = tz
        }

        if let name = calendarName {
            event.calendar = try findCalendar(name: name, source: calendarSource, entityType: .event)
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

        // Validate recurrence weekday consistency (#5) — check when:
        // 1. A new recurrence rule is being set, OR
        // 2. start_time or timezone changed on an event that already has weekly recurrence
        // Skip entirely if clearRecurrence is true (event becoming non-recurring)
        let effectiveRule: RecurrenceRuleInput? = clearRecurrence ? nil : recurrenceRule
        let existingWeeklyDays: [Int]? = {
            guard !clearRecurrence, // skip if clearing recurrence
                  recurrenceRule == nil, // only check existing rules if not replacing
                  startDate != nil || timezone != nil, // only if start/tz changed
                  let rules = event.recurrenceRules,
                  let firstRule = rules.first,
                  firstRule.frequency == .weekly,
                  let ekDays = firstRule.daysOfTheWeek, !ekDays.isEmpty
            else { return nil }
            return ekDays.map { $0.dayOfTheWeek.rawValue }
        }()

        let daysToValidate = effectiveRule.flatMap({ $0.frequency == .weekly ? $0.daysOfWeek : nil }) ?? existingWeeklyDays
        if let days = daysToValidate, !days.isEmpty {
            var cal = Calendar.current
            if let tz = timezone ?? event.timeZone { cal.timeZone = tz }
            let weekday = cal.component(.weekday, from: event.startDate)
            if !days.contains(weekday) {
                let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                let startDay = dayNames[weekday]
                let expectedDays = days.compactMap { ($0 >= 1 && $0 <= 7) ? dayNames[$0] : nil }.joined(separator: ", ")
                throw EventKitError.weekdayMismatch(startDay: startDay, expectedDays: expectedDays)
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

        try eventStore.save(event, span: span)
        markNeedsRefresh()
        // #246: a calendar change across accounts changes the identifier, so the record keeps the
        // one the event has now; #236: and the state the update left.
        let savedID = event.eventIdentifier ?? identifier
        // #236: an update that touched a recurring event is recorded only as a marker; its undo is
        // refused (RecurringUpdateKind). The rules after the update come from the request: a
        // detached occurrence reads back with none although its series still repeats. A detached
        // occurrence addressed by its own identifier is an occurrence update (round 5).
        let recurringKind = RecurringUpdateKind.of(
            hadRules: hadRules,
            hasRulesAfter: clearRecurrence ? false : (recurrenceRule != nil || hadRules),
            onOccurrence: event !== masterEvent || masterEvent.isDetached, span: span)
        if let recurringKind {
            await CalendarUndoManager.shared.record(.updateRecurringEvent(id: savedID, title: oldSnapshot.title, kind: recurringKind))
        } else {
            await CalendarUndoManager.shared.record(.updateEvent(id: savedID, oldSnapshot: oldSnapshot,
                                                                 saved: postWriteSnapshot(eventID: savedID, saved: event)))
        }
        return event
    }

    /// Get the timezone of an event by identifier (nil if not found or no timezone set).
    func getEventTimezone(identifier: String) -> TimeZone? {
        return eventStore.event(withIdentifier: identifier)?.timeZone
    }

    /// Find a specific occurrence of a recurring event on a given date.
    /// Returns the occurrence EKEvent (not the master event).
    func findOccurrence(identifier: String, on date: Date, in timeZone: TimeZone? = nil) -> EKEvent? {
        var calendar = Calendar.current
        if let tz = timeZone { calendar.timeZone = tz }
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)

        var target: EKEvent?
        eventStore.enumerateEvents(matching: predicate) { event, stop in
            if event.eventIdentifier == identifier {
                target = event
                stop.pointee = true
            }
        }
        return target
    }

    func deleteEvent(identifier: String, span: EKSpan = .thisEvent, occurrenceDate: Date? = nil) async throws {
        try await ensureCalendarAccess()

        guard let masterEvent = freshEvent(id: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }

        // Snapshot before deletion for undo
        let snapshot = EventSnapshot(from: masterEvent)

        // For recurring events, always resolve the specific occurrence (this/future both need it).
        // Non-recurring events operate on master directly.
        if masterEvent.hasRecurrenceRules, let date = occurrenceDate {
            guard let occurrence = findOccurrence(identifier: identifier, on: date, in: masterEvent.timeZone) else {
                throw EventKitError.eventNotFound(identifier: "\(identifier) (no occurrence on \(date))")
            }
            try eventStore.remove(occurrence, span: span)
        } else if masterEvent.hasRecurrenceRules {
            throw EventKitError.invalidTimeRange(
                message: "For recurring events, occurrence_date is required to identify which occurrence to delete."
            )
        } else {
            try eventStore.remove(masterEvent, span: span)
        }
        markNeedsRefresh()
        await CalendarUndoManager.shared.record(.deleteEvent(snapshot: snapshot))
    }

    /// Delete an entire recurring event series by removing from the earliest occurrence.
    /// Uses .futureEvents on the master event to delete all occurrences.
    func deleteEventSeries(identifier: String) async throws {
        try await ensureCalendarAccess()

        guard let event = freshEvent(id: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }

        // If the event has recurrence rules, it is (or belongs to) a recurring series.
        // eventStore.event(withIdentifier:) returns the master event for recurring series,
        // so calling .futureEvents on it deletes the entire series.
        // If it's a non-recurring event, just delete it normally.
        // #185 — snapshot BEFORE removal (EventSnapshot keeps raw EKRecurrenceRule,
        // so undo rebuilds the whole series), consistent with single deleteEvent.
        let snapshot = EventSnapshot(from: event)
        if event.hasRecurrenceRules {
            try eventStore.remove(event, span: .futureEvents)
        } else {
            try eventStore.remove(event, span: .thisEvent)
        }
        markNeedsRefresh()
        await CalendarUndoManager.shared.record(.deleteEvent(snapshot: snapshot))
    }

    /// #185 — batch series deletion with a single aggregated undo unit, symmetric
    /// with deleteEventsBatch. One undo restores every series actually removed
    /// (partial failure: only the successes). Lives in the manager so undo
    /// bookkeeping never leaks into the server layer.
    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult {
        try await ensureCalendarAccess()

        var successCount = 0
        var failures: [(String, String)] = []
        var undoSnapshots: [EventSnapshot] = []

        for id in identifiers {
            do {
                // #236 (PR #259 round 3, finding 1): refreshed, like deleteEventSeries, so the
                // snapshot undo recreates is not a stale copy; not found stays a per-row failure.
                guard let event = freshEvent(id: id) else {
                    failures.append((id, "Event not found"))
                    continue
                }
                let snapshot = EventSnapshot(from: event)
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
        }
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures
        )
    }

    /// Get a single event by identifier
    func getEvent(identifier: String) async throws -> EKEvent {
        try await ensureCalendarAccess()
        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }
        return event
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
        let now = Date()
        let searchStart = startDate ?? Calendar.current.date(byAdding: .year, value: -2, to: now)!
        let searchEnd = endDate ?? Calendar.current.date(byAdding: .year, value: 2, to: now)!

        var calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = try findCalendars(name: name, source: calendarSource, entityType: .event)
        }

        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: calendars)
        let allEvents = eventStore.events(matching: predicate)

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

        let now = Date()
        let searchStart = Calendar.current.date(byAdding: .year, value: -2, to: now)!
        let searchEnd = Calendar.current.date(byAdding: .year, value: 2, to: now)!

        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let allEvents = eventStore.events(matching: predicate)

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
        span: EKSpan = .thisEvent
    ) async throws -> BatchDeleteResult {
        try await ensureCalendarAccess()

        var successCount = 0
        var failures: [(String, String)] = []
        // #185 — collect a snapshot per successful removal so the whole batch is
        // one undo unit (mirrors the single-delete path at deleteEvent, which
        // snapshots the MASTER before removal — including occurrence-level deletes).
        // Same-identifier dedupe (#185 verify F5): removing several occurrences of
        // ONE recurring master yields progressively-shrunken master snapshots;
        // replaying more than one would rebuild multiple series on undo. Only the
        // FIRST (fullest) snapshot per identifier enters the undo unit — restoring
        // it rebuilds the master as it stood before any of this batch's removals.
        var undoSnapshots: [EventSnapshot] = []
        var undoSeenIdentifiers = Set<String>()

        for item in items {
            do {
                // #236 (PR #259 round 3, finding 1): refreshed, like deleteEvent.
                guard let masterEvent = freshEvent(id: item.identifier) else {
                    failures.append((item.identifier, "Event not found"))
                    continue
                }
                let snapshot = EventSnapshot(from: masterEvent)

                if masterEvent.hasRecurrenceRules, let date = item.occurrenceDate {
                    guard let occurrence = findOccurrence(identifier: item.identifier, on: date, in: masterEvent.timeZone) else {
                        failures.append((item.identifier, "No occurrence found on specified date"))
                        continue
                    }
                    try eventStore.remove(occurrence, span: span)
                } else if masterEvent.hasRecurrenceRules {
                    failures.append((item.identifier, "For recurring events, occurrence_date is required"))
                    continue
                } else {
                    try eventStore.remove(masterEvent, span: span)
                }
                successCount += 1
                if undoSeenIdentifiers.insert(item.identifier).inserted {
                    undoSnapshots.append(snapshot)
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
        if !undoSnapshots.isEmpty {
            await CalendarUndoManager.shared.record(.batch(undoSnapshots.map { .deleteEvent(snapshot: $0) }))
        }
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures
        )
    }

    /// Find duplicate events across calendars
    func findDuplicateEvents(
        calendarNames: [String]?,
        startDate: Date,
        endDate: Date,
        toleranceMinutes: Int = 5
    ) async throws -> [DuplicatePair] {
        try await ensureCalendarAccess()
        refreshIfNeeded()

        // Get specified calendars or all
        var calendars: [EKCalendar]?
        if let names = calendarNames, !names.isEmpty {
            let allCalendars = eventStore.calendars(for: .event)
            calendars = allCalendars.filter { names.contains($0.title) }
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        var duplicates: [DuplicatePair] = []
        let tolerance = TimeInterval(toleranceMinutes * 60)

        for i in 0..<events.count {
            for j in (i + 1)..<events.count {
                let e1 = events[i]
                let e2 = events[j]

                // Skip if same calendar
                if e1.calendar.calendarIdentifier == e2.calendar.calendarIdentifier { continue }

                // Compare titles (case-insensitive)
                guard let t1 = e1.title?.lowercased(), let t2 = e2.title?.lowercased(),
                      t1 == t2 else { continue }

                // Compare times with tolerance
                let startDiff = abs(e1.startDate.timeIntervalSince(e2.startDate))
                let endDiff = abs(e1.endDate.timeIntervalSince(e2.endDate))

                if startDiff <= tolerance && endDiff <= tolerance {
                    duplicates.append(DuplicatePair(
                        event1Id: e1.eventIdentifier ?? "",
                        event1Title: e1.title ?? "",
                        event1Calendar: e1.calendar.title,
                        event1StartDate: e1.startDate,
                        event2Id: e2.eventIdentifier ?? "",
                        event2Title: e2.title ?? "",
                        event2Calendar: e2.calendar.title,
                        event2StartDate: e2.startDate,
                        timeDifferenceSeconds: Int(startDiff)
                    ))
                }
            }
        }

        return duplicates
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

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

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
    /// `moveEvent` / `moveEventForCopyTool` (#226).
    func copyEvent(
        identifier: String,
        toCalendarName: String,
        toCalendarSource: String? = nil
    ) async throws -> EKEvent {
        try await ensureCalendarAccess()
        guard let sourceEvent = freshEvent(id: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }
        let targetCalendar = try writableTargetCalendar(name: toCalendarName, source: toCalendarSource)
        let alarms = (sourceEvent.alarms ?? []).map(AlarmSnapshot.init(from:))
        let newEvent = Self.makeCopy(of: sourceEvent, alarms: alarms, in: targetCalendar, store: eventStore)
        defer { markNeedsRefresh() }
        // #261: no discard for a failed copy (see EventCopyOperation.saveCopy).
        try EventCopyOperation.saveCopy(carrying: alarms,
                                        logFailure: { Self.logCopyFailure(handler: "copyEvent", identifier: identifier, error: $0) }) {
            try eventStore.save(newEvent, span: .thisEvent)
        }
        return newEvent
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
        guard let sourceEvent = freshEvent(id: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }
        if sourceEvent.hasRecurrenceRules {
            throw EventKitError.moveRefused(reason: "copy_event cannot move a recurring event; use move_events_batch with span and occurrence_dates.")
        }
        return try await moveEvent(identifier: identifier, occurrenceDate: nil, span: .this,
                                   toCalendarName: toCalendarName, toCalendarSource: toCalendarSource)
    }

    /// #226: moves an event (or one occurrence) to another calendar. In place first, which
    /// keeps the identifier within an account and every field; see `EventMovePolicy` for when
    /// it splits, falls back to copy + delete, or refuses.
    func moveEvent(
        identifier: String,
        occurrenceDate: Date?,
        span: EventMovePolicy.Span,
        toCalendarName: String,
        toCalendarSource: String?
    ) async throws -> (result: EventMoveResult, title: String?) {
        try await ensureCalendarAccess()
        guard let master = freshEvent(id: identifier) else {
            throw EventKitError.eventNotFound(identifier: identifier)
        }
        let targetCalendar = try writableTargetCalendar(name: toCalendarName, source: toCalendarSource)
        let isRecurring = master.hasRecurrenceRules

        var subject = master
        if isRecurring, span == .this, let date = occurrenceDate {
            guard let occurrence = findOccurrence(identifier: identifier, on: date, in: master.timeZone) else {
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
            let snapshot = EventSnapshot(from: subject, includeRecurrence: false, alarms: planned.alarms)
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
            }, removeSource: {
                try self.eventStore.remove(subject, span: .thisEvent)
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
                try self.eventStore.save(subject, span: isRecurring ? .futureEvents : .thisEvent)
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

    /// The fields a copy keeps. Recurrence and attendees are not among them; the move
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
        if sourceAvailability != copyAvailability { lost.append("availability") }
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
    }

    /// Find an existing incomplete reminder that matches by title on the same list.
    /// Optionally also matches due date if provided.
    private func findDuplicateReminder(
        title: String,
        dueDate: Date?,
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
        return reminders.first { reminder in
            guard reminder.title == title else { return false }
            // If both have due dates, compare them (within 1-minute window)
            if let existingDue = reminder.dueDateComponents,
               let due = dueDate {
                let existingDate = safeDateFromComponents(existingDue)
                if let existingDate = existingDate {
                    return abs(existingDate.timeIntervalSince(due)) < 60
                }
            }
            // If neither has a due date, it's a match by title alone
            if reminder.dueDateComponents == nil && dueDate == nil {
                return true
            }
            // One has due date, the other doesn't — not a duplicate
            return false
        }
    }

    func createReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        alarmOffsets: [Int]? = nil,
        recurrenceRule: RecurrenceRuleInput? = nil,
        locationTrigger: LocationTriggerInput? = nil
    ) async throws -> CreateReminderResult {
        try await ensureReminderAccess()

        // Resolve calendar first (required for both duplicate check and creation)
        guard let name = calendarName else {
            throw EventKitError.calendarNameRequired(forType: "reminders")
        }
        let calendar = try findCalendar(name: name, source: calendarSource, entityType: .reminder)

        // Idempotency: check for existing reminder with same title (+due date) on same list
        if let existing = await findDuplicateReminder(title: title, dueDate: dueDate, calendar: calendar) {
            return CreateReminderResult(reminder: ReminderWriteSnapshot(from: existing), isDuplicate: true)
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority
        reminder.calendar = calendar

        if let due = dueDate {
            // #134: populate dueDateComponents.timeZone so iCloud Web / macOS
            // Today-view render the time at the host's wall clock instead of
            // re-interpreting floating components as UTC. EKReminder's
            // dueDateComponents is NSDateComponents-based which permits
            // timeZone == nil ("floating"); native EventKit on Mac/iPhone
            // resolves floating as local but iCloud Web does not — the spec
            // contract is "always store with explicit timezone".
            var dueComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            dueComponents.timeZone = TimeZone.current
            reminder.dueDateComponents = dueComponents
        }

        // Add alarms
        if let offsets = alarmOffsets {
            for offset in offsets {
                let alarm = EKAlarm(relativeOffset: TimeInterval(-offset * 60))
                reminder.addAlarm(alarm)
            }
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

        try saveNewReminder(reminder, handler: "createReminder")
        markNeedsRefresh()
        let result = CreateReminderResult(reminder: ReminderWriteSnapshot(from: reminder), isDuplicate: false)
        let createdID = result.reminder.calendarItemIdentifier
        await CalendarUndoManager.shared.record(.createReminder(id: createdID, title: result.reminder.title ?? title,
                                                                created: postWriteSnapshot(reminderID: createdID, saved: reminder)))
        return result
    }

    /// #261: saves a reminder that has never been written (`create_reminder`, delete-undo). If
    /// the save fails and a new store does not find the reminder, it is removed from the store
    /// without committing, so the next save by any tool does not write it (`NewObjectSave`).
    private func saveNewReminder(_ reminder: EKReminder, handler: String) throws {
        try NewObjectSave.run(save: { try eventStore.save(reminder, commit: true) },
                              committed: { NewObjectSave.freshStoreFinds { $0.calendarItem(withIdentifier: reminder.calendarItemIdentifier) != nil } },
                              discard: { try eventStore.remove(reminder, commit: false) },
                              report: { Self.logNewObjectOutcome(handler: handler, identifier: reminder.calendarItemIdentifier, $0) })
    }

    /// What a failed new-object save left (#261), on stderr only; the caller reports the save's
    /// error. A failed discard is written as `<handler>.discard(<id>) failed: …` and means the
    /// object may still be written by the next save; the other outcomes are notes.
    private static func logNewObjectOutcome(handler: String, identifier: String, _ outcome: NewObjectSave.Outcome) {
        if case .discardFailed(let error) = outcome {
            _ = EventKitErrorSanitizer.writeFailureLog(handler: "\(handler).discard", identifier: identifier, error: error)
        } else if let note = NewObjectSave.note(for: outcome, at: EventKitErrorSanitizer.escapeForStderr("\(handler)(\(identifier))")) {
            FileHandle.standardError.write(Data(note.utf8))
        }
    }

    func updateReminder(
        identifier: String,
        title: String? = nil,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil,
        calendarName: String? = nil,
        calendarSource: String? = nil,
        locationTrigger: LocationTriggerInput? = nil,
        clearLocationTrigger: Bool = false,
        clearDueDate: Bool = false,
        realignToDue: Bool = false
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
            identifier: identifier, title: title, notes: notes, dueDate: dueDate, priority: priority,
            calendarName: calendarName, calendarSource: calendarSource, locationTrigger: locationTrigger,
            clearLocationTrigger: clearLocationTrigger, clearDueDate: clearDueDate, realignToDue: realignToDue)
        // PR #256 verify round 1: everything that can refuse the call runs before the first write,
        // so a refused call leaves the cached reminder untouched (#235 no-due check, list lookup).
        try ReminderUpdateWrite.checkRealign(request, existingDue: reminder.dueDateComponents)
        let calendar = try calendarName.map { try findCalendar(name: $0, source: calendarSource, entityType: .reminder) }

        let oldSnapshot = ReminderSnapshot(from: reminder)
        let dateSync = try ReminderUpdateWrite.apply(
            request, to: reminder, calendar: calendar,
            save: { try store.save(reminder, commit: true) },
            reload: { reminder.refresh() },
            rollback: { reminder.rollback() })
        markNeedsRefresh()
        let result = ReminderUpdateResult(reminder: ReminderWriteSnapshot(from: reminder), dateSync: dateSync)
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
        try eventStore.remove(reminder, commit: true)
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
                try eventStore.remove(reminder, commit: true)
                successCount += 1
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
            }
        }

        markNeedsRefresh()
        return BatchDeleteResult(
            successCount: successCount,
            failedCount: failures.count,
            failures: failures
        )
    }

    // MARK: - Helpers

    private func createRecurrenceRule(from input: RecurrenceRuleInput) -> EKRecurrenceRule {
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
            // Undo delete = recreate from snapshot. #261: no discard; in the failure classes tried
            // on device, a failed new event was not written by a later save (see NewObjectSave).
            let event = EKEvent(eventStore: eventStore)
            try applySnapshot(snapshot, to: event)
            try eventStore.save(event, span: .thisEvent)
            markNeedsRefresh()
            return "Undone: restored event '\(undoVisibleTitle(snapshot.title))' (new ID: \(event.eventIdentifier ?? "unknown"))"

        case .updateEvent(_, let oldSnapshot, _):
            // Undo update = restore old values. Only updates of one-off events are recorded this
            // way; an update that touched a recurring event is a marker whose undo is refused
            // (#236, #262), and `verifiedEvent` refuses an event that repeats now. The snapshot
            // holds no rules, so `apply` writes none here (its rules branch serves delete-undo).
            let event = try await verifiedEvent(of: operation, verb: .undo)
            try applySnapshot(oldSnapshot, to: event)
            try eventStore.save(event, span: .thisEvent)
            markNeedsRefresh()
            return "Undone: restored event '\(undoVisibleTitle(oldSnapshot.title))' to previous state"

        case .updateRecurringEvent(_, let title, let kind):
            // #236: refused, never attempted; the record is discarded (UnrecoverableUndoError).
            throw UndoOperation.recurringUpdateRefusal(title: title, kind: kind)

        case .moveEvent(_, let fromCalendarIdentifier, _, let title, let isSeries):
            // Undo an in-place move (#226) = move it back to the recorded calendar, while the
            // event is still in the calendar it was moved to (#236).
            let event = try await verifiedEvent(of: operation, verb: .undo)
            guard let original = eventStore.calendar(withIdentifier: fromCalendarIdentifier) else {
                throw EventKitError.calendarNotFound(identifier: fromCalendarIdentifier)
            }
            event.calendar = original
            try eventStore.save(event, span: isSeries ? .futureEvents : .thisEvent)
            markNeedsRefresh()
            return "Undone: moved event '\(undoVisibleTitle(title))' back to its original calendar"

        case .createReminder(_, let title, _):
            // Undo create = delete. #236: a missing reminder is not found (UndoTargetMissingError:
            // the record is kept and the message names discard_id), as for events since #182;
            // this arm used to report "Undone" for a no-op. "Already gone" is not taken as done:
            // the identifier may only be unresolvable (moved to another account, recreated under
            // a new identifier by a delete-undo), and the spec keeps not-found records.
            let reminder = try await verifiedReminder(of: operation, verb: .undo)
            try eventStore.remove(reminder, commit: true)
            markNeedsRefresh()
            return "Undone: removed created reminder '\(undoVisibleTitle(title))'"

        case .deleteReminder(let snapshot):
            // Undo delete = recreate. The new reminder is created only after the lists are read.
            let reminder = try await applyReminderSnapshot(snapshot, for: .recreateDeleted, into: { EKReminder(eventStore: eventStore) })
            try saveNewReminder(reminder, handler: "undo.deleteReminder")
            markNeedsRefresh()
            return "Undone: restored reminder '\(undoVisibleTitle(snapshot.title))'"

        case .updateReminder(_, let oldSnapshot, _):
            // Undo update = restore old values
            let reminder = try await applyReminderSnapshot(oldSnapshot, for: .revertUpdate, into: { try await verifiedReminder(of: operation, verb: .undo) })
            try eventStore.save(reminder, commit: true)
            markNeedsRefresh()
            return "Undone: restored reminder '\(undoVisibleTitle(oldSnapshot.title))' to previous state"

        case .completeReminder(_, let wasCompleted, _, _, let title, _, _):
            let reminder = try await verifiedReminder(of: operation, verb: .undo)
            try apply(operation.completionWrite(undo: true, now: Date()), to: reminder)
            try eventStore.save(reminder, commit: true)
            markNeedsRefresh()
            return "Undone: set reminder '\(undoVisibleTitle(title))' completion to \(wasCompleted)"

        case .completeRecurringReminder(let before, _, _):
            return try await undoRecurringCompletion(operation, before: before)

        case .batch(let ops):
            // #236 D4: every sub-operation is checked before the first write.
            let results = try await UndoBatchRunner.run(
                Array(ops.reversed()),
                check: { try await self.verifyHistoryTarget(of: $0, verb: .undo) },
                execute: { try await self.executeUndo($0) })
            return "Undone batch (\(results.count) operations)"
        }
    }

    /// Execute an operation again (for redo). Same as the original mutation.
    func executeRedo(_ operation: UndoOperation) async throws -> String {
        switch operation {
        case .createEvent(_, let title, _):
            return "Cannot redo creation of event '\(undoVisibleTitle(title))' — please create it again manually"

        case .deleteEvent(let snapshot):
            // Redo delete = delete the restored event
            // The restored event's ID was stored via updateLastRedoEventId
            return "Redo delete: please use delete_event to remove '\(undoVisibleTitle(snapshot.title))'"

        case .updateEvent(let id, _, _):
            return "Redo update: the event \(id) was restored to its previous state. Apply your changes again."

        case .updateRecurringEvent(_, let title, _):
            // Unreachable: its undo always fails and discards the record.
            return "Redo update: the update of the recurring event '\(undoVisibleTitle(title))' was not undone, so there is nothing to redo."

        case .moveEvent(_, _, _, let title, _):
            return "Redo move: use move_events_batch to move '\(undoVisibleTitle(title))' again."

        case .createReminder(_, let title, _):
            return "Cannot redo reminder creation — please create '\(undoVisibleTitle(title))' again manually"

        case .deleteReminder(let snapshot):
            return "Redo delete: please use delete_reminder to remove '\(undoVisibleTitle(snapshot.title))'"

        case .updateReminder(let id, _, _):
            return "Redo update: the reminder \(id) was restored. Apply your changes again."

        case .completeReminder(_, _, let requestedCompleted, _, let title, _, _):
            // Redo re-applies the recorded request (#196: never the opposite of
            // wasCompleted — that reopened an idempotently completed reminder), and only
            // while the reminder is in the state the undo left (#236).
            let reminder = try await verifiedReminder(of: operation, verb: .redo)
            try apply(operation.completionWrite(undo: false, now: Date()), to: reminder)
            try eventStore.save(reminder, commit: true)
            markNeedsRefresh()
            return "Redone: set reminder '\(undoVisibleTitle(title))' completion to \(requestedCompleted)"

        case .completeRecurringReminder(let before, let requestedCompleted, _):
            return try await redoRecurringCompletion(operation, before: before, requestedCompleted: requestedCompleted)

        case .batch(let ops):
            let results = try await UndoBatchRunner.run(
                ops,
                check: { try await self.verifyHistoryTarget(of: $0, verb: .redo) },
                execute: { try await self.executeRedo($0) })
            return "Redone batch (\(results.count) operations)"
        }
    }

    /// Apply an EventSnapshot to an EKEvent: the calendar lookup here, because it needs the
    /// store; every field write in `EventSnapshot.apply` (#253 verify #4, as #228 did for
    /// reminders).
    private func applySnapshot(_ snapshot: EventSnapshot, to event: EKEvent) throws {
        let originalCalendar = try snapshot.resolveCalendar(in: eventStore.calendars(for: .event), identifier: { $0.calendarIdentifier })
        snapshot.apply(to: event, calendar: originalCalendar)
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
    case eventNotFound(identifier: String)
    case reminderNotFound(identifier: String)
    case calendarNameRequired(forType: String)
    case invalidTimeRange(message: String)
    case weekdayMismatch(startDay: String, expectedDays: String)
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
    /// giving the undo up loses. The three titles are store-derived (a shared list's title is set
    /// by someone else, #37 F1), so the message shows them through `undoShownTitle`, as labelled
    /// values ahead of the instructions, and leaves out a title that shows as nothing.
    case undoListMissing(list: String, account: String?, reminder: String, hasIdentifier: Bool, kind: ReminderRestoreKind)

    var errorDescription: String? {
        switch self {
        case .accessDenied(type: let type, isSSH: let isSSH, isNonInteractive: let isNonInteractive, deniedByStatus: let deniedByStatus):
            return EventKitManager.accessDeniedMessage(
                type: type,
                isSSH: isSSH,
                isNonInteractive: isNonInteractive,
                isMCPB: EventKitManager.isMCPBClaudeDesktopInstall,
                deniedByStatus: deniedByStatus,
                setupHint: EventKitManager.resolvedSetupCommandHint()
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
            2. Or 'tccutil reset Calendar com.checheng.CheICalMCP' (and same for Reminders) then re-grant
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
            // operator hint that listed available calendars is preserved on
            // stderr via the `EventKitError.calendarNotFound.operatorHint`
            // computed property, which catch sites can write to stderr
            // separately (untrusted channel).
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
            return "start_time falls on \(startDay), which is not in days_of_week [\(expectedDays)]. Adjust start_time to a matching day."
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
        case .copyRefused(let code, let alarmKinds):
            return "Saving the copy failed (\(code)); the original event was not removed. The copy carries \(alarmKinds.joined(separator: ", ")), which some calendars refuse, so they are one possible cause."
        case .undoListMissing(let list, let account, let reminder, let hasIdentifier, let kind):
            let recorded = [("list", list), ("account", account ?? ""), ("reminder", reminder)]
                .map { ($0.0, undoShownTitle($0.1)) }
                .filter { !$0.1.isEmpty }
                .map { "\($0.0) '\($0.1)'" }
                .joined(separator: ", ")
            let named = recorded.isEmpty ? "" : " (\(recorded))"
            let which = kind == .recreateDeleted
                ? "the deletion of a reminder: the list it was in when it was deleted\(named)"
                : "the update of a reminder: the list it was in before the update\(named)"
            let state = hasIdentifier ? "was not found under its recorded identifier" : "was recorded without an identifier, so it cannot be found"
            // Without an identifier the entry can never be undone, only given up.
            let blocked = hasIdentifier ? "until it is undone or given up" : "until it is given up"
            let retry = hasIdentifier
                ? " Run undo again if the list's account may be turned off or still syncing; if the list was deleted, no retry can find it."
                : ""
            let loss = kind == .recreateDeleted
                ? "Giving up this undo cannot be reversed, and this tool cannot recover the deleted reminder afterwards"
                : "Giving up this undo cannot be reversed; the reminder stays as it is now"
            return "Cannot undo \(which) \(state). Undo does not use another list of the same name. Nothing was written for this reminder and the history entry was kept; older undo entries stay blocked \(blocked).\(retry) \(loss): ask the user whether to give it up; if they agree, read undo_history and call undo with discard_id set to its id."
        case .exclusionConflict(let existingId, let date):
            return "An existing series (event ID \(existingId)) matches this event but still has an occurrence on \(date) — its exclusion set differs from the request. Not modifying the existing series; adjust it explicitly or change the request."
        }
    }
}

extension EventKitError: TrustedErrorMessage {}

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
    let successCount: Int
    let failedCount: Int
    let failures: [(identifier: String, error: String)]
}

struct DuplicatePair {
    let event1Id: String
    let event1Title: String
    let event1Calendar: String
    let event1StartDate: Date
    let event2Id: String
    let event2Title: String
    let event2Calendar: String
    let event2StartDate: Date
    let timeDifferenceSeconds: Int
}
