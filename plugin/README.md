# che-ical-mcp Plugin

Claude Code plugin for macOS Calendar & Reminders management using native EventKit.

> ## ℹ️ Why use this plugin instead of the `.mcpb` Claude Desktop install?
>
> Claude Desktop **1.6608.2+** (2026-05-09 release) **broke Calendar / Reminders write access for `.mcpb` extension installs** — see [`PsychQuant/che-ical-mcp#132`](https://github.com/PsychQuant/che-ical-mcp/issues/132) and [`anthropics/claude-code#58239`](https://github.com/anthropics/claude-code/issues/58239). This Claude Code plugin path is **not affected** — it spawns the binary via a different process chain that doesn't go through the broken `disclaimer` wrapper. If you tried `.mcpb` and hit "Calendar access denied", install this plugin instead.

## Features

- **29 MCP Tools**: Complete calendar and reminder management with attendees / organizer support, batch operations, undo/redo, and one-call cleanup
- **Skills**: Guided calendar management workflow
- **Commands**: Quick shortcuts for common operations
- **Auto-detection**: Automatically finds installed MCP binary
- **Setup check**: Warns if MCP is not installed on session start (version-aware auto-download since v1.7.2)
- **i18n Week Support**: Configurable week start day (Monday/Sunday/Saturday/System)
- **Per-event timezone**: Each event can carry its own timezone instead of relying on the system default
- **Day-of-week verification hook** (PreToolUse): catches "Friday 2026-04-26" mismatches before they reach Calendar.app
- **Flexible date parsing + fuzzy matching**: natural-language date strings + close-match suggestions when calendar / event names don't exactly match

## Installation

### Step 1: Install MCP Server (if not already installed)

```bash
# Download the binary
mkdir -p ~/bin
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP
```

Or download `.mcpb` from [Releases](https://github.com/PsychQuant/che-ical-mcp/releases) for one-click install.

On first use, macOS will prompt for **Calendar** and **Reminders** access - click "Allow".

### Step 2: Install Plugin

#### Method A: Plugin Directory (Development)

```bash
claude --plugin-dir /path/to/che-ical-mcp/plugin
```

#### Method B: Add to Settings

Add to `~/.claude/settings.json`:

```json
{
  "plugins": [
    "/path/to/che-ical-mcp/plugin"
  ]
}
```

## How It Works

The plugin automatically detects your MCP installation from these locations:
- `~/bin/CheICalMCP`
- `/usr/local/bin/che-ical-mcp`
- `~/Library/Application Support/Claude/mcp-servers/che-ical-mcp/` (MCPB)

A **SessionStart hook** checks if the MCP is properly installed and shows setup instructions if needed.

## Included Components

### MCP Server

| Server | Description |
|--------|-------------|
| `che-ical-mcp` | macOS Calendar & Reminders via EventKit |

### Skills

| Skill | Description |
|-------|-------------|
| `calendar-management` | Comprehensive guide for calendar operations |

### Commands

| Command | Description |
|---------|-------------|
| `/today` | Show today's events and pending tasks |
| `/week` | Show this week's calendar overview |
| `/quick-event` | Create event from natural language |
| `/remind` | Create reminder from natural language |

## Usage Examples

```
/today                           → See today's schedule
/week                            → Weekly overview
/quick-event Meeting at 2pm      → Create event quickly
/remind Buy groceries tomorrow   → Create reminder
```

Or just ask naturally:
- "What's on my calendar next week?"
- "Create a meeting with John tomorrow at 3pm"
- "Show my pending reminders"
- "Add a reminder to call mom"

## Available Tools (29)

### Calendars (4)
- `list_calendars` - List all calendars
- `create_calendar` - Create new calendar
- `update_calendar` - Update calendar metadata
- `delete_calendar` - Delete calendar

### Events (12)
- `list_events` / `list_events_quick` — list by range or shortcut
- `search_events` — keyword search
- `create_event` / `update_event` / `delete_event` — single ops
- `copy_event` — copy or move event across calendars
- `check_conflicts` — time-overlap detection
- `create_events_batch` / `move_events_batch` / `delete_events_batch` — batch ops
- `find_duplicate_events` — surface duplicates for cleanup

### Reminders (10)
- `list_reminders` / `search_reminders` / `list_reminder_tags`
- `create_reminder` / `update_reminder` / `complete_reminder` / `delete_reminder`
- `create_reminders_batch` / `delete_reminders_batch` — batch ops
- `cleanup_completed_reminders` — single-call cleanup of all completed reminders (`dry_run=true` default; new in v1.7.2)

### Undo / Redo (3, process-local)
- `undo` / `redo` / `undo_history`

## Permissions

This plugin requires macOS permissions:
- **Calendar**: Read/write access to Calendar.app events
- **Reminders**: Read/write access to Reminders.app tasks

## Version

Plugin version: 1.11.0 (matches MCP server version)

### Changelog

**1.11.0** (2026-06-10)
- **TCC healing re-prompt unblocked** (#154): `Entitlements.plist` now ships `com.apple.security.personal-information.calendars` + `.reminders`. Long-lived installs upgraded from the pre-v1.7.1 ad-hoc era could hit silent permanent Calendar denial on macOS 26.5 — the TCC row stays pinned to the old build's cdhashes while the healing re-prompt was policy-blocked (binary had no entitlements), with every diagnostic reporting green. First launch of this build is finally allowed to re-prompt; approving rewrites the row keyed to the Developer ID requirement. New `EntitlementsPlistTests` + value-aware signed-binary release gate.
- **BREAKING**: deploy floor raised to macOS 14.0 (Sonoma) (#119)
- Non-interactive EventKit access hardening (#131/#143/#144) + verify follow-ups (#146–#150); 401 tests

**1.10.0** (2026-05-12)
- **TCC drift detector + startup banner** (#122): single-shot `[banner]` line on MCP-server-mode startup with version/path/PID + drift signals (TCC.db path mismatch per-service, stale running processes). Banner is advisory, stderr-only, opt-out via `CHE_ICAL_MCP_NO_BANNER=1`. Hardened against CWE-117 stderr-injection on every interpolated value (R1 sanitization).
- **R3.3 production POSIX hygiene fix**: parent pipe write-end fd close in `LiveTCCDatabaseSource` + `LiveProcessInventorySource`. R1's read-before-wait order fix was complementary; R3.3 completes the POSIX EOF contract that local macOS 26 masked via aggressive fd scheduling but GHA macos-15-arm64 reliably deadlocked on.
- **#131 CI hardening**: 8 tests (5 binary-spawn banner + 3 real-server dispatch) compile-time excluded on CI via `#if !CI_BUILD` + `-Xswiftc -DCI_BUILD` workflow flag. Root cause: EventKit framework blocks on TCC prompt in macOS 15 (Sequoia) headless CI sandbox, where macOS 26 (Tahoe) returns `.denied` synchronously. CI runs 330/330; local runs 338/338. Tracked in #131.

**1.9.1** (2026-05-11, plugin shell only)
- 4 plugin-shell additions exposing v1.9.0 TCC features: `troubleshoot-tcc` skill (5-step diagnostic), `/check-tcc` slash command, `eventkit-error-debugging` rule (routes accessDenied/insufficientAccess/unknownAuthState investigations to TCC-first), CLAUDE.md plugin overview.

**1.9.0** (2026-05-11)
- **TCC access gate refactor** (#108 Phase 2, closes #109): removes process-lifetime `hasCalendarAccess`/`hasReminderAccess` cache anti-pattern; replaces with per-call `EKEventStore.authorizationStatus(for:)` cheap check via new `AuthorizationGate` + `AuthorizationStatusSource` test seam. Aligns with Apple TN3153 documented per-call pattern — TCC state changes surface immediately as actionable `accessDenied`/`insufficientAccess`/`unknownAuthState` errors instead of silent fail.
- **`--print-tcc-path` diagnostic flag** (#109): prints binary path, bundle identifier, EventKit authorization status, `tccutil reset` snippet (with bundle ID interpolated), `sqlite3` TCC.db query snippet, and System Settings paths. Designed for `.mcpb` installed users who need to locate the extracted binary path before running `--setup` from Terminal.

**1.8.1** (2026-05-11, documentation only)
- `mcpb/README.md` post-install / upgrade TCC permission setup guide (#108 Phase 1). Diagnoses the silent-failure mode where reinstalling `.mcpb` invalidates the existing TCC grant.

**1.8.0** (2026-05-11)
- **Wire-format consistency wave** — closes #101 cluster (5 issues: #102 #103 #104 #106 #107) in 3 days, full IDD lifecycle + 6-AI ensemble verify per issue
- **Event listing response-shape parameters** (#47/#101): `detail_level` (`summary`/`standard`), `fields` allow-list, `display_timezone` (strict IANA), `limit` (cap 10000) — LLM token-usage tuning
- **Envelope unification — BREAKING wire-format** (#102/#107): `list_events`/`list_reminders` `metadata.returned` removed; all 5 list/search envelopes use top-level `<entity>_count` with pre-limit semantic; `search_reminders.result_count` → `reminder_count`; `search_reminders` gains `limit` parameter
- **Validator hardening** (#101 F1–F3): `Int.max` DoS trap closed, `detail_level`/`display_timezone` validators no longer silent-coerce non-string inputs, `UTC` echo round-trips verbatim
- **Runtime-anchored drift detection** (#103, strengthening #101 M3): `formatEventDict` ↔ `validEventFields` divergence test now via `EventFormattingSource` test seam + `FakeFormattableEvent`
- **CHANGELOG reclass** (#106): wire-format renames moved from `Fixed` → `Changed` (Keep a Changelog 1.1.0)
- **Release pipeline fix**: `build-mcpb.sh` pre-pack defense now derives Team ID from `DEVELOPER_ID` cert via `security find-identity` (was incorrectly comparing SHA hash against `Authority=` human-readable string)

**1.7.2** (2026-05-07)
- **Tool count 28 → 29**: `cleanup_completed_reminders` (#21) — single-call cleanup of all completed reminders, `dry_run=true` default
- **`--self-update` flag** (#49): existing-install upgrade path with SHA-256 verification (#98). Wrapper auto-download covers fresh-install only; this fills the gap
- **Sanitizer hardening cluster** (#73 #74 #80 #85 #86 #94): full C0+DEL escape coverage, executeUndo/executeRedo title interpolation guard, CLIRunner stderr trusted-branch carve-out, DoS amplification cap, thread-safety doc with macOS PIPE_BUF=512
- **CI test workflow** (#51): PR-time `swift build` + `swift test` on macos-latest
- **`make install-signed`** (#50): maintainer dev TCC flow on macOS 26
- **Distribution polish**: README install snippets `rm -f` preamble (#90), zh-TW v1.7.1 sync (#75)
- All 30+ commits with `Refs #N` IDD discipline + 6-AI parallel verify before merge

**1.7.2-pre** (2026-04-22, pre-release plugin shell bump only)
- Plugin wrapper now version-aware: re-downloads `~/bin/CheICalMCP` when binary lags upstream Release

**1.7.1** (2026-04-20)
- Repo URL migration: kiki830621 → PsychQuant org (no behavior change)

**1.7.0** (2026-04-01)
- Attendee + organizer info exposed on read paths
- Tool count reaches 28 (added `find_duplicate_events`, batch operations, etc.)

**1.6.0** (2026-03-30)
- Tool surface broadened to cover full reminders CRUD + tag listing

**1.5.0** (2026-03-29)
- Per-event timezone support (no longer pinned to system locale)
- Undo / redo on calendar mutations
- 28 tools total

**1.3.x – 1.4.x** (2026-02-22 – 2026-03-23)
- Day-of-week verification PreToolUse hook (catches "Friday 2026-04-26" mismatches)
- i18n SessionStart / current-time helper
- Alarms support on `update_event`

**1.0.0 – 1.2.x** (2026-02-06 – 2026-02-23)
- Initial stable release; iCal binary auto-install + update check

**0.8.x – 0.9.x** (2026-01-30)
- Week boundary calculation fix; `week_starts_on` parameter (`system` / `monday` / `sunday` / `saturday`)
- `update_event` time validation fix; `all_day` parameter

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))
