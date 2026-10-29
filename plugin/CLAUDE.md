# che-ical-mcp — Plugin Overview

macOS Calendar & Reminders MCP server with native EventKit integration. Binary shipped as `.mcpb` bundle (Claude Desktop) and via wrapper auto-download (Claude Code plugin).

## Components

### Skills (`skills/`)

- **calendar-management** — Primary guide for using the 29 MCP tools (event CRUD, reminder CRUD, batch operations, search, conflict detection, duplicate finding, --cli mode). Reference for what each tool does and when to use it.
- **troubleshoot-tcc** — TCC permission diagnostic walkthrough. Use when user reports calendar tools failing silently / permission denied / missing dialog after upgrade. Wraps the v1.9.0 `--print-tcc-path` diagnostic flag into a 6-step fix flow (covers both the binary layer and the host-app / responsible-process layer, #168; from v1.23.0, the server is its own responsible process whenever the host has no full Calendar and Reminders access of its own, #343).

### Commands (`commands/`)

- `/today` — Today's events + pending reminders, grouped by time
- `/week` — This week's events overview
- `/quick-event` — Fast event creation flow
- `/remind` — Quick reminder creation
- `/check-tcc` — Print current TCC state + ready-to-paste reset / re-prompt commands (v1.9.1+)

### Rules (`rules/`)

- **eventkit-error-debugging.md** — TCC-first rule: when EventKit tools return `accessDenied` / `insufficientAccess` / `unknownAuthState`, always suspect TCC state before code bugs. Routes Claude to `troubleshoot-tcc` skill rather than retry-and-hope or premature code investigation.

### Hooks (`hooks/`)

- `check-mcp.sh` — Validate MCP server availability on session start
- `verify-weekday.sh` — Sanity-check weekday calculations

### Binary distribution (`bin/`)

`che-ical-mcp-wrapper.sh` auto-downloads the notarized binary from GitHub releases on first install. See `mcpb/README.md` in the source repo for `.mcpb` bundle installation.

## Version history (recent)

- **v1.9.0** (2026-05-11) — TCC access gate refactor (#108 Phase 2): removed `hasCalendarAccess` / `hasReminderAccess` cache anti-pattern; replaced with per-call `EKEventStore.authorizationStatus(for:)` check via new `AuthorizationGate` + `AuthorizationStatusSource` test seam. Bundles `--print-tcc-path` diagnostic flag (#109).
- **v1.8.1** (2026-05-11) — Phase 1: `mcpb/README.md` post-install / upgrade TCC permission setup guide.
- **v1.8.0** (2026-05-11) — Wire-format consistency wave (#101 cluster): `detail_level` / `fields` / `display_timezone` / `limit` response-shape parameters.

See `CHANGELOG.md` in source repo for full history.

## Source

https://github.com/PsychQuant/che-ical-mcp

## Working with this plugin

### When user reports calendar / reminder issues

1. **First**: read the error. If it's TCC-flavored (`accessDenied` / `insufficientAccess` / `unknownAuthState` / "permission denied"), apply `rules/eventkit-error-debugging.md` — invoke `troubleshoot-tcc` skill or suggest `/check-tcc` command.
2. **Second**: if TCC is verified healthy and the tool still fails, then debug the tool itself per normal investigation (re-read the relevant tool's MCP schema, check arguments, look for `calendarNotFound` / `invalidTimeRange` / etc.).
3. **Never**: blindly retry a TCC-flavored error or suggest reinstall as first action.

### When user wants to work with calendar / reminders

Use `calendar-management` skill as the entry point — it covers tool selection, argument shapes, common workflows. Use slash commands for shortcuts (`/today`, `/week`, `/quick-event`, `/remind`).

### When making bulk operations

- Prefer batch tools (`create_events_batch`, `delete_events_batch`, `move_events_batch`) over loops, except where reminders are needed: `create_events_batch` cannot set them, so an event module (`rules/event-modules.md`) creates events one by one with `create_event`
- Always use `--dry-run` first for destructive ops (see `delete_events_batch` schema)
- Check `find_duplicate_events` before mass-creating

### TCC permission model (mental model)

- TCC binds grants to **binary path + Developer ID + signing requirement**, NOT cdhash
- Same Developer ID + same path = grant survives binary upgrades (verified across v1.7.x → v1.9.0)
- v1.9.0+ checks status per-call so user-driven changes (System Settings toggle / `tccutil reset` / future macOS policy shifts) surface immediately
- `--mcpb` install path: `~/Library/Application Support/Claude/Claude Extensions/local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP`
- `tccutil reset SERVICE bundleID` may silently no-op against path-keyed entries — `--setup` is the reliable re-prompt path
- **Two-layer authorization (#168)**: besides the binary's own grant, macOS TCC may attribute access to the **responsible process** (host app). Claude Desktop spawns `.mcpb` servers via `Helpers/disclaimer` → the `.mcpb` binary is its own TCC client (one layer). Claude Code spawns `~/bin/CheICalMCP` directly; on v1.21.0 and earlier, with `CHE_ICAL_MCP_NO_DISCLAIM=1`, or (v1.23.0+) when the host context already has full access, there is no disclaim → attribution follows the host context, whose System Settings entry shows as a bare version number (e.g. `2.1.202` = `~/.local/share/claude/versions/<version>`). Operative rule: keep BOTH the `CheICalMCP` entry AND the host-layer entry ON for the host you use — both-ON is a **sufficient** condition; whether the binary layer is *also* strictly necessary (AND-gated vs. only the responsible-process layer mattering) is not conclusively established (#168), so this says "keep both ON", not "both are required"
- **Self-disclaim (#343; v1.22.0 under Claude Code only, v1.23.0+ status-aware)**: From v1.23.0 the rule depends on the grant macOS checks for this binary, that of its responsible process (which is not always the process that starts it), and it is the same for every host: before any dispatch the binary reads that context's authorization status. If it already has full access to both Calendar and Reminders (Terminal, VS Code, a Claude Code version-number entry, any host), that grant is kept and nothing is re-exec'd. Otherwise, including a host with only one of the two, one the user denied, or one a policy restricts, the binary re-execs in place as its own responsible process (`posix_spawn` + `POSIX_SPAWN_SETEXEC` + disclaim, the call Claude Desktop's `disclaimer` makes; pid and stdio unchanged), so macOS checks the `CheICalMCP` grant, the one `--setup` creates. This covers the MCP server, `--cli`, `--print-tcc-path` and `--setup`; `--setup` re-execs under any host, because it is the action that creates CheICalMCP's own grant. (v1.22.0 re-exec'd only when Claude Code was the responsible process.) Trade-off: once CheICalMCP's own grant is allowed, any process that runs this binary from a context without full access of its own (another app, a script, a launchd or cron job, a Claude Code session, `--cli` included, and a host the user denied Calendar or Reminders to, or that a policy restricts) reads Calendar and Reminders under that grant without a separate consent. v1.22.0 did this by default only under Claude Code, and for any caller that set `CHE_ICAL_MCP_FORCE_DISCLAIM`, without a notice. `CHE_ICAL_MCP_NO_DISCLAIM=1` keeps host attribution for the environment that sets it; it does not stop another process from running the binary without it. `CHE_ICAL_MCP_FORCE_DISCLAIM=1` re-execs even under a host with a grant of its own (the opt-out wins; a forced re-exec prints one stderr line). Not verified: CI does not cover reading the calendar through the re-exec. On 2026-10-28 v1.22.0 read the calendar through a forced re-exec with `--cli`; a re-exec that a Claude Code worker launched through `ClaudeCode.app` triggers by itself, and server mode after the re-exec, have not been observed yet. `--print-tcc-path` prints the kernel's answer as `TCC attribution`; the parent chain is not what TCC checks
- **`EKEventStore.authorizationStatus(for:)` is context-dependent (#168)**: it reports the attribution of the *calling context*, not an absolute property of the binary — two different binaries return identical status from the same Claude Code shell. Diagnose a host's tool calls from that host's own context (Claude Code → its Bash tool; Desktop → the startup-banner lines in its MCP log)
- **Claude Code updates rotate the versioned binary path** → on v1.21.0 and earlier, or with `CHE_ICAL_MCP_NO_DISCLAIM=1`, the host-layer grant can silently go stale after an update (#170); re-check the version-number entry when calendar tools break right after a Claude Code upgrade (from v1.23.0 the rotated path has no grant, so the binary re-execs and uses CheICalMCP's own grant)
