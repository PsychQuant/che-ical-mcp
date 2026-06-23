# che-ical-mcp — Plugin Overview

macOS Calendar & Reminders MCP server with native EventKit integration. Binary shipped as `.mcpb` bundle (Claude Desktop) and via wrapper auto-download (Claude Code plugin).

## Components

### Skills (`skills/`)

- **calendar-management** — Primary guide for using the 29 MCP tools (event CRUD, reminder CRUD, batch operations, search, conflict detection, duplicate finding, --cli mode). Reference for what each tool does and when to use it.
- **troubleshoot-tcc** — TCC permission diagnostic walkthrough. Use when user reports calendar tools failing silently / permission denied / missing dialog after upgrade. Wraps the v1.9.0 `--print-tcc-path` diagnostic flag into a 5-step fix flow.

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

- Prefer batch tools (`create_events_batch`, `delete_events_batch`, `move_events_batch`) over loops
- Always use `--dry-run` first for destructive ops (see `delete_events_batch` schema)
- Check `find_duplicate_events` before mass-creating

### TCC permission model (mental model)

- TCC binds grants to **binary path + Developer ID + signing requirement**, NOT cdhash
- Same Developer ID + same path = grant survives binary upgrades (verified across v1.7.x → v1.9.0)
- v1.9.0+ checks status per-call so user-driven changes (System Settings toggle / `tccutil reset` / future macOS policy shifts) surface immediately
- `--mcpb` install path: `~/Library/Application Support/Claude/Claude Extensions/local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP`
- `tccutil reset SERVICE bundleID` may silently no-op against path-keyed entries — `--setup` is the reliable re-prompt path
