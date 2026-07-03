# che-ical-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**macOS Calendar & Reminders MCP server** - Native EventKit integration for complete calendar and task management.

[English](README.md) | [繁體中文](README_zh-TW.md)

---

> ## ✅ Claude Desktop `.mcpb` — working end-to-end as of v1.14.0 (2026-07-03)
>
> Two earlier Claude Desktop regressions broke the `.mcpb` install; **both are now fixed** — install the latest `.mcpb` from [Releases](https://github.com/PsychQuant/che-ical-mcp/releases/latest) and read + write + tool-injection all work.
>
> | Past symptom | Cause | Fixed in |
> |--------------|-------|----------|
> | Write tools returned `Calendar access denied` (reads worked) on Desktop 1.6608.2+ | the hardened-runtime binary shipped no `com.apple.security.personal-information.*` entitlements | **v1.11.0** ([#154](https://github.com/PsychQuant/che-ical-mcp/issues/154)) |
> | The **entire** 29-tool server silently dropped from every conversation on Desktop 1.18286.0 | a literal `&` in the manifest `display_name` (`"macOS Calendar & Reminders"`) tripped Desktop's tool-injection layer | **v1.14.0** ([#166](https://github.com/PsychQuant/che-ical-mcp/issues/166)) |
>
> Empirically confirmed on the previously-failing Desktop install 2026-07-03 (removing only the `&` flipped the server from dropped → injecting real EventKit data). Historical detail: [`#132`](https://github.com/PsychQuant/che-ical-mcp/issues/132) / [`#166`](https://github.com/PsychQuant/che-ical-mcp/issues/166) / upstream [`anthropics/claude-code#58239`](https://github.com/anthropics/claude-code/issues/58239). The Claude Code plugin path was unaffected throughout.

---

## Why che-ical-mcp?

| Feature | Other Calendar MCPs | che-ical-mcp |
|---------|---------------------|--------------|
| Calendar Events | Yes | Yes |
| **Reminders/Tasks** | No | **Yes** |
| **Reminder #Tags** | No | **Yes** (MCP-level) |
| **Multi-keyword Search** | No | **Yes** |
| **Duplicate Detection** | No | **Yes** |
| **Conflict Detection** | No | **Yes** |
| **Batch Operations** | No | **Yes** |
| **Local Timezone** | No | **Yes** |
| **Source Disambiguation** | No | **Yes** |
| Create Calendar | Some | Yes |
| Delete Calendar | Some | Yes |
| Event Reminders | Some | Yes |
| Location & URL | Some | Yes |
| Language | Python | **Swift (Native)** |

---

## Quick Start

### For Claude Desktop

#### Option A: MCPB One-Click Install (Recommended)

Download the latest `.mcpb` file from [Releases](https://github.com/PsychQuant/che-ical-mcp/releases) and double-click to install.

#### Option B: Manual Configuration

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-ical-mcp": {
      "command": "/usr/local/bin/che-ical-mcp"
    }
  }
}
```

### For Claude Code (CLI)

#### Option A: Install as Plugin (Recommended)

The plugin includes slash commands (`/today`, `/week`, `/quick-event`, `/remind`), skills, and **a PreToolUse hook that automatically verifies day-of-week** when creating or updating events — preventing date/weekday mismatch errors.

Two steps — register the marketplace once, then install the plugin. This repo is its
own self-hosted marketplace (the plugin definition lives in `plugin/`):

```bash
# 1. Register the marketplace (one-time)
claude plugin marketplace add PsychQuant/che-ical-mcp

# 2. Install the plugin
claude plugin install che-ical-mcp@che-ical-mcp
```

> **Inside Claude Code?** The slash-command equivalents `/plugin marketplace add PsychQuant/che-ical-mcp` and `/plugin install che-ical-mcp@che-ical-mcp` work the same way.
>
> **Add via git, not a raw URL.** The marketplace's plugin `source` is a same-repo relative path (`./plugin`), which only resolves when the marketplace is added through its Git repo (GitHub `owner/repo`, as above) — not via a direct URL to `marketplace.json`.
>
> The plugin is also still bundled in the `psychquant-claude-plugins` aggregator (`claude plugin install che-ical-mcp@psychquant-claude-plugins`); both serve the same versioned binary.

> **Note:** The plugin wraps the MCP binary with auto-download. If the binary is not found at `~/bin/CheICalMCP`, it will be downloaded from GitHub Releases on first use.

#### Option B: Install as standalone MCP

If you only need the MCP server without plugin features:

```bash
# Create ~/bin if needed
mkdir -p ~/bin

# Download the latest release
# Note: if upgrading from an older version, `rm -f ~/bin/CheICalMCP` first.
# Without this, on macOS 26 the kernel may kill the new binary with a stale
# code-signature cache from the old inode (which running MCP processes might
# still be holding open).
rm -f ~/bin/CheICalMCP
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# Add to Claude Code
# --scope user    : available across all projects (stored in ~/.claude.json)
# --transport stdio: local binary execution via stdin/stdout
# --              : separator between claude options and the command
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **💡 Tip:** Always install the binary to a local directory like `~/bin/`. Avoid placing it in cloud-synced folders (Dropbox, iCloud, OneDrive) as file sync operations can cause MCP connection timeouts.

### Build from Source (Optional)

```bash
git clone https://github.com/PsychQuant/che-ical-mcp.git
cd che-ical-mcp
make release && make install
```

> **⚠️ Swift 6 / Xcode 18 users:** Do not use `swift build` directly — upstream MCP SDK has a concurrency error ([swift-sdk#214](https://github.com/modelcontextprotocol/swift-sdk/issues/214)). The Makefile auto-detects this and falls back to Swift 5 language mode.

On first use, macOS will prompt for **Calendar** and **Reminders** access - click "Allow".

### CLI Mode (No MCP Server)

All 29 tools can be invoked directly from the command line without running the MCP server:

```bash
# Flag-based: --key value pairs
CheICalMCP --cli list_events --start_date 2026-03-29 --end_date 2026-03-30

# JSON via stdin
echo '{"tool":"list_calendars","arguments":{}}' | CheICalMCP --cli

# Use with Claude Code via shell
claude -p "Run: ~/bin/CheICalMCP --cli list_events_quick --range today"
```

Useful for launchd jobs, shell scripts, CI pipelines, and agents that prefer subprocess over MCP protocol. TCC permissions still required — run `CheICalMCP --setup` first if needed.

### Upgrading an existing install

The plugin wrapper auto-downloads on **fresh** installs, but does NOT replace an existing binary. To upgrade in place:

```bash
~/bin/CheICalMCP --self-update
```

This queries GitHub Releases for the latest tag, downloads the new binary, and atomically replaces the current one. If the binary is currently running as an MCP server, restart your MCP host (Claude Desktop / Claude Code) afterward to pick up the new version. Manual alternative if `--self-update` is unavailable: `rm -f ~/bin/CheICalMCP && curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP && chmod +x ~/bin/CheICalMCP`.

---

## All 29 Tools

<details>
<summary><b>Calendars (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_calendars` | List all calendars and reminder lists (includes source_type) |
| `create_calendar` | Create a new calendar |
| `delete_calendar` | Delete a calendar |
| `update_calendar` | Rename a calendar or change its color (v0.9.0) |

</details>

<details>
<summary><b>Events (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_events` | List events with filter/sort/limit (v1.0.0) |
| `create_event` | Create an event (with reminders, location, URL, per-event timezone) |
| `update_event` | Update an event (including timezone, recurrence, span for recurring) |
| `delete_event` | Delete an event (with occurrence support for recurring) |

</details>

<details>
<summary><b>Reminders (8)</b></summary>

| Tool | Description |
|------|-------------|
| `list_reminders` | List reminders with filter/sort/limit, tags extraction (v1.0.0) |
| `create_reminder` | Create a reminder with due date, tags (v1.3.0) |
| `update_reminder` | Update a reminder (including tags, `clear_due_date`) (v1.3.0) |
| `complete_reminder` | Mark as completed/incomplete |
| `delete_reminder` | Delete a reminder |
| `search_reminders` | Search reminders by keyword(s) or tag (v1.3.0) |
| `list_reminder_tags` | List all unique tags with usage counts (v1.3.0) |
| `cleanup_completed_reminders` | Delete all completed reminders in one call, dry_run preview by default (v1.7.2) |

</details>

<details>
<summary><b>Advanced Features (10)</b> ✨ New in v0.3.0+</summary>

| Tool | Description |
|------|-------------|
| `search_events` | Search events by keyword(s) with AND/OR matching |
| `list_events_quick` | Quick shortcuts: `today`, `tomorrow`, `this_week`, `next_7_days`, etc. |
| `create_events_batch` | Create multiple events at once (with per-event timezone) |
| `check_conflicts` | Check for overlapping events in a time range |
| `copy_event` | Copy an event to another calendar (with optional move) |
| `move_events_batch` | Move multiple events to another calendar |
| `delete_events_batch` | Delete events by IDs or date range, with dry-run preview (v1.0.0) |
| `find_duplicate_events` | Find duplicate events across calendars (v0.5.0) |
| `create_reminders_batch` | Create multiple reminders at once (v0.9.0) |
| `delete_reminders_batch` | Delete multiple reminders at once (v0.9.0) |

</details>

<details>
<summary><b>Undo/Redo (3)</b> ✨ New in v1.4.0</summary>

| Tool | Description |
|------|-------------|
| `undo` | Undo the most recent calendar/reminder operation |
| `redo` | Redo the last undone operation |
| `undo_history` | List undoable operations with timestamps |

</details>

---

## Installation

### Requirements

- macOS 14.0+ (Sonoma or later — required since cluster v1.11.0+ for full TCC permission API support)
- Xcode Command Line Tools (only if building from source)

### For Claude Desktop

#### Method 1: MCPB One-Click Install (Recommended)

1. Download the latest `che-ical-mcp-<version>.mcpb` from [Releases](https://github.com/PsychQuant/che-ical-mcp/releases)
2. Double-click the `.mcpb` file to install
3. Restart Claude Desktop

#### Method 2: Manual Configuration

1. Download the binary:
   ```bash
   curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o /usr/local/bin/che-ical-mcp
   chmod +x /usr/local/bin/che-ical-mcp
   ```

2. Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:
   ```json
   {
     "mcpServers": {
       "che-ical-mcp": {
         "command": "/usr/local/bin/che-ical-mcp"
       }
     }
   }
   ```

3. Restart Claude Desktop

### For Claude Code (CLI)

```bash
# Create ~/bin if needed
mkdir -p ~/bin

# Download the binary
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# Register with Claude Code (user scope = available in all projects)
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

### Build from Source (Optional)

```bash
git clone https://github.com/PsychQuant/che-ical-mcp.git
cd che-ical-mcp
make release && make install

# Register with Claude Code
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **⚠️ Swift 6 / Xcode 18 使用者：** 不要直接使用 `swift build` — 上游 MCP SDK 有 concurrency 錯誤（[swift-sdk#214](https://github.com/modelcontextprotocol/swift-sdk/issues/214)）。Makefile 會自動偵測並回退到 Swift 5 語言模式。

### Grant Permissions

On first use, macOS will prompt for **Calendar** and **Reminders** access. Click **Allow** for both.

> **⚠️ macOS Sequoia (15.x) Note:** The permission dialog is attributed to the **parent application** that launched the MCP server, not the binary itself. This means:
>
> | Environment | Permission Attributed To |
> |-------------|------------------------|
> | Claude Desktop | Claude Desktop.app ✅ (works automatically) |
> | Claude Code in **Terminal.app** | Terminal.app ✅ (works automatically) |
> | Claude Code in **VS Code** | VS Code ❌ (may not show dialog) |
> | Claude Code in **iTerm2** | iTerm2 ✅ (works automatically) |
>
> **If the permission dialog doesn't appear** (common with VS Code), you need to add `NSCalendarsFullAccessUsageDescription` to VS Code's Info.plist:
>
> ```bash
> # Add calendar usage description to VS Code
> /usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string 'VS Code needs calendar access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
> /usr/libexec/PlistBuddy -c "Add :NSRemindersFullAccessUsageDescription string 'VS Code needs reminders access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
>
> # Re-sign VS Code (required after Info.plist modification)
> codesign -s - -f --deep "/Applications/Visual Studio Code.app"
>
> # Restart VS Code, then the permission dialog will appear
> ```
>
> **Note:** This modification will be overwritten when VS Code updates. You'll need to re-apply it after each VS Code update.

---

## v1.0.0 Features

### Flexible Date Parsing

All date parameters now accept 4 formats:

| Format | Example | Interpretation |
|--------|---------|----------------|
| Full ISO8601 | `"2026-02-06T14:00:00+08:00"` | Exact date and time (offset preserved) |
| Without timezone | `"2026-02-06T14:00:00"` | Uses event `timezone` if provided, otherwise system timezone |
| Date only | `"2026-02-06"` | Midnight in event `timezone` or system timezone |
| Time only | `"14:00"` | Today at that time |

### Per-Event Timezone (v1.5.0)

Set the display timezone for individual events — essential for multi-timezone travel itineraries.

```
"Create a flight departure at 09:14 Berlin time"
→ create_event(title: "Flight LH123", start_time: "2026-04-08T09:14:00", timezone: "Europe/Berlin", ...)

"Update the hotel check-in to Dubai time"
→ update_event(event_id: "...", timezone: "Asia/Dubai")

"Remove the custom timezone from an event"
→ update_event(event_id: "...", clear_timezone: true)
```

- **`timezone`** parameter accepts IANA identifiers (e.g., `Europe/Berlin`, `America/New_York`, `Asia/Taipei`)
- When `timezone` is provided, naive datetimes (without offset) are interpreted in that timezone
- Event output includes the event's own timezone in `timezone` field and formats `start_date_local`/`end_date_local` accordingly
- Available on `create_event`, `update_event`, and `create_events_batch`
- Undo/redo preserves per-event timezone

### Attendees & Organizer (Read-Only)

Event responses include participant information when available. These fields are **read-only** due to EventKit limitations — they cannot be set or modified through the MCP.

Available in: `list_events`, `search_events`, `list_events_quick`, `check_conflicts`

**`attendees`** (array, optional) — Present when the event has participants. Each attendee object contains:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string or null | Display name, null if not in Address Book |
| `email` | string | Email address extracted from participant URL |
| `role` | string | One of: `unknown`, `required`, `optional`, `chair`, `non_participant` |
| `status` | string | One of: `unknown`, `pending`, `accepted`, `declined`, `tentative`, `delegated`, `completed`, `in_process` |
| `type` | string | One of: `unknown`, `person`, `room`, `resource`, `group` |
| `is_current_user` | boolean | Whether this participant is the current user |

**`organizer`** (object, optional) — Present when the event has an organizer. Contains:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string or null | Display name |
| `email` | string | Email address |
| `is_current_user` | boolean | Whether the organizer is the current user |

> **Note:** Both fields are omitted when the event has no participants or organizer (e.g., local calendar events created without invitees).

### Fuzzy Calendar Matching

Calendar names are now matched **case-insensitively**. If not found, the error message lists all available calendars.

### Enhanced list/delete Tools

- **`list_events`**: `filter` (all/past/future/all_day), `sort` (asc/desc), `limit`
- **`list_reminders`**: `filter` (all/incomplete/completed/overdue), `sort` (due_date/creation_date/priority/title), `limit`
- **`delete_events_batch`**: date range mode (`before_date`/`after_date`) + `dry_run` preview

> **Breaking Change**: `list_events` and `list_reminders` now return `{events/reminders: [...], metadata: {...}}` instead of a plain array.

---

## Usage Examples

### Calendar Management

```
"List all my calendars"
"What's on my schedule next week?"
"Create a meeting tomorrow at 2 PM titled 'Team Sync'"
"Add a dentist appointment on Friday at 10 AM with location '123 Main St'"
"Delete the meeting called 'Cancelled Meeting'"
```

### Reminder Management

```
"List my incomplete reminders"
"Show all reminders in my Shopping list"
"Add a reminder: Buy milk"
"Create a reminder to call mom tomorrow at 5 PM"
"Mark 'Buy milk' as completed"
"Delete the reminder about groceries"
```

### Reminder Management (v1.5.0)

```
"Remove the due date from 'Buy groceries'"
→ update_reminder(reminder_id: "...", clear_due_date: true)
```

### Advanced Features (v0.3.0+)

```
"Search for events containing 'meeting'"
"Search for events with both 'project' AND 'review'"
"What do I have today?"
"Show me this week's schedule"
"Are there any conflicts if I schedule a meeting from 2-3 PM?"
"Create 3 weekly team meetings for the next 3 weeks"
"Copy the dentist appointment to my Work calendar"
"Move all events from 'Old Calendar' to 'New Calendar'"
"Delete all the cancelled events"
"Find duplicate events between 'IDOL' and 'Idol' calendars"
```

### DX Improvements (v1.0.0)

```
"Show my next 5 upcoming events"
→ list_events(start_date: "2026-02-06", end_date: "2026-12-31", filter: "future", sort: "asc", limit: 5)

"Show my overdue reminders"
→ list_reminders(filter: "overdue")

"Preview which events would be deleted from 'Old Calendar' before 2025"
→ delete_events_batch(calendar_name: "Old Calendar", before_date: "2025-01-01", dry_run: true)

"Create an event at 2 PM" (no need for full ISO8601!)
→ create_event(start_time: "14:00", end_time: "15:00", ...)
```

---

## Supported Calendar Sources

Works with any calendar synced to macOS Calendar app:

- iCloud Calendar
- Google Calendar
- Microsoft Outlook/Exchange
- CalDAV calendars
- Local calendars

### Same-Name Calendar Disambiguation (v0.6.0+)

If you have calendars with the same name from different sources (e.g., "Work" in both iCloud and Google), use the `calendar_source` parameter:

```
"Create an event in my iCloud Work calendar"
→ create_event(calendar_name: "Work", calendar_source: "iCloud", ...)

"Show events from my Google Work calendar"
→ list_events(calendar_name: "Work", calendar_source: "Google", ...)
```

If ambiguity is detected, the error message will list all available sources.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Server disconnected | Rebuild with `make release && make install` |
| Permission denied | Grant Calendar/Reminders access in System Settings > Privacy & Security |
| Permission dialog never appears | See [Grant Permissions](#grant-permissions) for macOS Sequoia workaround |
| **Permission denied over SSH** | See [SSH Access](#ssh-access) below |
| **Permission denied under launchd** | See [launchd / Automation](#launchd--automation) below |
| **One service denied while every diagnostic reports green** | See [Silent permanent denial after upgrade](#silent-permanent-denial-after-upgrade-154) below |
| Calendar not found | Ensure the calendar is visible in macOS Calendar app |
| Reminders not syncing | Check iCloud sync in System Settings |

### Silent permanent denial after upgrade (#154)

If one service (typically Calendar) returns `access denied` while the other works, **and** `--print-tcc-path` and System Settings report the permission as granted, you are likely hitting the [#154](https://github.com/PsychQuant/che-ical-mcp/issues/154) signature: a TCC row created by a pre-v1.7.1 (ad-hoc-signed) build is pinned to that old build's code hashes. The upgraded Developer ID binary can never match it, and on macOS 26.5+ the OS only allows the healing re-prompt when the binary carries the matching `com.apple.security.personal-information.*` entitlement.

As of **v1.14.0+ the startup banner surfaces this directly** — a `[drift] TCC.db <service> entry pins a code requirement this binary no longer satisfies` line ([#155](https://github.com/PsychQuant/che-ical-mcp/issues/155)) — when the Security-framework check can confirm the csreq mismatch. Before that, *every* status-API diagnostic (including the banner) reported green, which is exactly what made this class silent. If you hit the denial through Claude Desktop's `.mcpb` install, the denial message itself now names the real blocker and the working paths instead of the dead-end `--setup` ([#158](https://github.com/PsychQuant/che-ical-mcp/issues/158)).

**Fix**: upgrade to **v1.11.0 or later** (the binary now ships both entitlements), restart the host app (full `Cmd+Q` for Claude Desktop), and approve the permission dialog that appears on the first Calendar/Reminders access. Approving rewrites the TCC row keyed to the Developer ID requirement, so it survives all future upgrades. If you accidentally **deny** the dialog, re-enable the corresponding toggle in System Settings → Privacy & Security → Calendars or Reminders.

> ⚠️ **Erratum for the #108-era workaround**: `tccutil reset Calendar com.checheng.CheICalMCP` does **not** work for a bare (non-bundled) binary — it fails with `OSStatus error -10814` because the binary has no LaunchServices registration. And do **not** run a bare `tccutil reset Calendar` (without a bundle ID): it wipes Calendar grants for *every* app on the machine and, on a pre-entitlements binary, leaves CheICalMCP permanently unable to re-prompt.

### SSH Access

macOS TCC (Transparency, Consent, and Control) grants privacy permissions **per-application**. SSH sessions run under `sshd`, which is a different security context — so permissions granted to Terminal or Claude Code locally do **not** carry over to SSH.

**Workaround A — Run locally first (recommended):**
1. Run `CheICalMCP` once on the target Mac **locally** (not over SSH)
2. Grant Calendar and Reminders access when the TCC dialog appears
3. SSH sessions should then inherit the grant for the `CheICalMCP` binary

**Workaround B — Grant Full Disk Access to sshd:**
1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**, press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>, type `/usr/sbin/sshd`, and add it
3. Restart the SSH session

> ⚠️ Workaround B grants `sshd` broad file access — only use this on machines you fully control.

### launchd / Automation

When running CheICalMCP from `launchd`, cron, or other non-interactive automation, macOS TCC cannot show permission dialogs. Use `--setup` to pre-grant permissions:

```bash
# Step 1: Run once from Terminal (triggers TCC permission dialog)
CheICalMCP --setup

# Step 2: Grant Calendar & Reminders access in the dialog that appears
# Step 3: The binary now has permission — launchd jobs can use it
```

> **Detection**: CheICalMCP automatically detects non-interactive sessions (missing `TERM` env var or direct launchd child) and provides targeted error messages with `--setup` instructions. This works even for indirect launch chains (launchd → Claude Code → CheICalMCP).
>
> **`--setup` in non-interactive sessions** (#143): if you run `--setup` itself from a non-interactive session (no `TERM` / direct launchd child) and permission is still undetermined, `--setup` now **skips the request and exits non-zero** instead of hanging — a TCC dialog can't appear there, so it prints manual-grant instructions rather than blocking. Run `--setup` from a real Terminal to trigger the dialog. (An already-granted binary still reports success even when re-run non-interactively.)
>
> **Note**: If `--setup` grants permission but the MCP still fails under launchd, TCC may have associated the permission with the parent process. In that case, manually add CheICalMCP in **System Settings → Privacy & Security → Calendar/Reminders**.

---

## Technical Details

- **Current Version**: v1.14.0
- **Framework**: [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.12.0
- **Calendar API**: EventKit (native macOS framework)
- **Transport**: stdio
- **Platform**: macOS 14.0+ (Sonoma and later — bumped from 13.0 in the post-1.10 cluster per [#119](https://github.com/PsychQuant/che-ical-mcp/issues/119))
- **Tools**: 29 tools for calendars, events, reminders, tags, undo/redo, cleanup, and advanced operations

---

## Version History

| Version | Changes |
|---------|---------|
| v1.14.0 | **Claude Desktop tool-injection drop fixed** (#166): a literal `&` in `mcpb/manifest.json` `display_name` made Desktop 1.18286.0 silently drop the whole 29-tool server from every conversation (Claude Code unaffected); changed `&` → `and`, confirmed by single-variable intervention on the failing install + a `ManifestParityTests` regression guard. Also aligned `serverInfo.name` to the kebab manifest id (hygiene; empirically refuted as the cause). **#154 sister batch**: csreq-mismatch TCC drift signal (#155, `SecCodeCheckValidity` self-check for the silent-denial class), `.mcpb` denial message no longer dead-ends on `--setup` for the already-`.denied` signature (#158), macOS badge 13.0 → 14.0 (#157), swift-nio 2.96 → 2.101 (#159). 454 tests. |
| v1.13.0 | **SwiftUI SetupWindow** (#164): interactive `--setup` presents a live-status window (per-entity Grant buttons + resolved binary path) inside the #163 foreground `NSApplication`. **Desktop Calendar-denied fix** (#165): `isNonInteractive` misfired on `TERM == nil` for GUI-app-spawned servers → fast-failed before `requestFullAccess`, so the first-grant dialog never appeared through Claude Desktop; now uses a `CGSession` GUI-session signal. 429 tests. |
| v1.12.0 | **Foreground `--setup`** (#163): interactive `--setup` now runs inside a foreground `NSApplication` so EventKit's Calendar TCC modal actually presents (previously silently denied from a bare CLI async context). Denial messages + startup banner surface the resolved binary path + a copy-pasteable `"<path>" --setup` command for the buried `.mcpb` binary. |
| v1.11.1 | **`create_event` time-range validation** (#160): symmetric with `update_event` — rejects inverted / zero-duration timed events via a shared `validateTimeRange` guard. 405 tests. |
| v1.11.0 | **TCC healing re-prompt unblocked** (#154): `Entitlements.plist` ships `personal-information.calendars` + `.reminders` — long-lived pre-v1.7.1 installs could hit silent permanent Calendar denial on macOS 26.5 (TCC row pinned to old cdhashes, healing re-prompt policy-blocked because the binary shipped no entitlements, every diagnostic reporting green); signed-binary release gate verifies both keys. **Non-interactive EventKit hardening** (#131 / #143 / #144 + #146–#150). **BREAKING**: deploy floor raised to macOS 14.0 (#119). 401 tests. |
| v1.10.0 | **TCC drift detector + startup banner** (#122): single-shot stderr banner at MCP-server startup with version/path/PID + drift signals (TCC.db path mismatch per-service, stale processes); opt-out via `CHE_ICAL_MCP_NO_BANNER=1`. Pipe-deadlock fix in subprocess helpers; CWE-117 stderr-injection defense on all interpolated banner values. |
| v1.9.0 | **TCC access gate refactor** (#108 Phase 2, closes #109): removed the process-lifetime `has*Access` cache anti-pattern; per-call `EKEventStore.authorizationStatus(for:)` via new `AuthorizationGate` + `AuthorizationStatusSource` seam (Apple TN3153 pattern) — state changes surface immediately instead of silent stale-grant fail. Adds `--print-tcc-path` diagnostic flag. |
| v1.8.1 | **Docs**: `mcpb/README.md` post-install / upgrade TCC permission setup guide (#108 Phase 1). |
| v1.8.0 | **Wire-format consistency wave + response-shape parameters** (#101 cluster — 5 issues closed in 3 days, all `Refs #N` IDD + 6-AI ensemble verify). **Event listing response-shape params** (#47 / #101): `detail_level` (`summary`/`standard`), `fields` allow-list, `display_timezone` (strict IANA), `limit` (cap 10000) — LLM verbosity tuning. **Envelope unification** (#102 / #107, **breaking wire-format**): `list_events.metadata.returned` + `list_reminders.metadata.returned` removed; all 5 list/search envelopes use top-level `<entity>_count` with pre-limit semantic; `search_reminders.result_count` → `reminder_count`; `search_reminders` gains `limit` parameter (mirror `search_events`). MCP clients reading `metadata.returned` or `result_count` must update. **Validator hardening** (#101 F1–F3): `requireOptionalInt` uses `Int(exactly:)` closing the `Int.max` DoS trap; `detail_level` / `display_timezone` validators distinguish absent vs. non-string (no silent coerce). **Runtime-anchored drift detection** (#103, strengthening #101 M3): `formatEventDict` ↔ `validEventFields` divergence test now via `EventFormattingSource` seam + `FakeFormattableEvent`. **CHANGELOG reclass** (#106): wire-format renames moved from `Fixed` to `Changed` (Keep a Changelog 1.1.0). **Release pipeline fix**: pre-pack defense check now derives Team ID from `DEVELOPER_ID` cert (was comparing SHA hash against human-readable `Authority=` string). |
| v1.7.2 | **Hardening + features wave** (30+ commits over v1.7.1, all `Refs #N` IDD with 6-AI verify). **`--self-update`** (#49) + **SHA-256 binary verify** (#98): existing-install upgrade path with cryptographic guarantee against corrupted releases. **`make install-signed`** (#50): maintainer dev TCC flow on macOS 26 — fail-fast on missing Developer ID + force codesign verification. **CI test workflow** (#51): PR-time `swift build` + `swift test` on macos-latest. **Sanitizer hardening cluster**: `escapeForStderr` full C0+DEL coverage (#73), `sanitizeForInterpolation` for executeUndo/executeRedo title interpolation (#74), CLIRunner stderr delegated to `writeFailureLog` for trusted-branch carve-out (#80), `writeFailureLog` 1024-char DoS cap (#86), `CLIError.invalidJSON` author-controlled-only contract doc (#85), `FileHandle.standardError.write` thread-safety + macOS PIPE_BUF=512 documented (#70 / #94). **Distribution polish**: stale-codesign-cache install snippets get `rm -f` preamble (#90 zh-TW parity for #62). **Post-v1.7.1 polish** (#46 #57 #58 #60): redo error interpolation parity, `build-mcpb.sh` step renumbering, `Entitlements.plist` documentation, `Makefile release-signed:` cwd note. **`cleanup_completed_reminders` tool** (#21): single-call cleanup of all completed reminders, `dry_run=true` default. |
| v1.7.1 | **Security hardening** (#20 #26): input validation (length limits + URL scheme allowlist) at all event/reminder entry points, prompt-injection wrapper on MCP read responses, parse-boundary validation for `days_of_week` / `days_of_month` / `alarms_minutes_offsets` (throws instead of silent-dropping invalid values), `Info.plist` catch-up, 42 new regression tests. |
| v1.7.0 | **Attendee & organizer info** (#17): read-only `attendees` array and `organizer` object in event responses. Refactored shared `formatEventDict` method. |
| v1.6.0 | **`--setup` flag** (#13): pre-authorize TCC permissions for launchd/automation. Non-interactive session detection (TERM + ppid). Combined SSH+launchd error messages. **`--cli` mode** (#14): invoke all 28 tools directly from command line without MCP server. Flag-based (`--key value`) and JSON stdin modes. Smart type inference for bool/int/double/array params. MCP Swift SDK 0.12.0 (Swift 6.3 compat). |
| v1.5.0 | **Per-event timezone** (#12): `timezone` parameter on `create_event`/`update_event`/`create_events_batch`, event output uses event's own timezone, naive datetimes parsed in event timezone. **Clear due date** (#9): `clear_due_date` on `update_reminder`. **Weekday validation** (#5): `create_event`/`update_event` validate `start_time` weekday against `days_of_week`. **Undo/redo** (#8): 3 new tools (`undo`, `redo`, `undo_history`). **Recurring event fixes** (#7): occurrence-level delete/update with `occurrence_date`. **Swift 6 build** (#11): README updated for `make release` workflow |
| v1.4.0 | **LLM reliability**: Fix default search range (±2yr instead of distantPast/Future), `searched_range` metadata in `search_events` response, `similar_events` hints in `create_events_batch`, LLM tips in tool descriptions |
| v1.3.1 | **Docs fix**: Clarified that tags are MCP-level (not native Reminders.app tags); Apple provides no public API for native tags |
| v1.3.0 | **Reminder tags** (MCP-level): `#hashtag` text stored in notes for `create_reminder`/`update_reminder`/`create_reminders_batch`, tag-based filtering in `search_reminders`, new `list_reminder_tags` tool; MCP SDK 0.11.0. Note: tags are searchable via MCP but do not appear as native Reminders.app tags (Apple provides no public API for this) |
| v1.2.0 | **Idempotent writes**: `create_event`, `create_events_batch`, `create_reminder`, `create_reminders_batch`, `create_calendar` now check-before-write to prevent duplicates on retry; responses include `skipped` count |
| v1.1.0 | **Recurrence + Location**: recurring events/reminders (daily/weekly/monthly/yearly), structured locations with coordinates, location-based reminder triggers (geofence enter/leave), rich recurrence output |
| v1.0.0 | **DX improvements**: flexible date parsing (4 formats), fuzzy calendar matching, `list_events`/`list_reminders` filter/sort/limit, `delete_events_batch` dry-run + date range mode |
| v0.9.0 | **4 new tools** (20→24): `update_calendar`, `search_reminders`, `create_reminders_batch`, `delete_reminders_batch` |
| v0.8.2 | **i18n week support**: `week_starts_on` parameter for `list_events_quick` (monday/sunday/saturday/system) |
| v0.8.1 | **Fix**: `update_event` time validation bug, duration preservation when moving events |
| v0.8.0 | **BREAKING**: `calendar_name` now required for create operations (no more implicit defaults) |
| v0.7.0 | **Tool annotations** for Anthropic Connectors Directory, auto-refresh mechanism, improved batch tool descriptions |
| v0.6.0 | **Source disambiguation**: `calendar_source` parameter for same-name calendars |
| v0.5.0 | Batch delete, duplicate detection, multi-keyword search, improved permission errors, PRIVACY.md |
| v0.4.0 | Copy/move events: `copy_event`, `move_events_batch` |
| v0.3.0 | Advanced features: search, quick range, batch create, conflict check, timezone display |
| v0.2.0 | Swift rewrite with full Reminders support |
| v0.1.x | Python version (deprecated) |

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Release Process (for maintainers)

Version numbers live in three places with different semantics:

| File | Role | When to bump |
|------|------|--------------|
| `Sources/CheICalMCP/Version.swift` — `AppVersion.current` | Source of truth; appears in `--version`, `help`, and MCP `serverInfo.version` | Every release |
| `Sources/CheICalMCP/Info.plist` — `CFBundleVersion` | macOS bundle version | Every release; must match `AppVersion.current` |
| `mcpb/manifest.json` — `version` | Claude Desktop bundle manifest shipped inside `.mcpb` | Every release; must match `AppVersion.current` |
| `server.json` — `version` + `packages[].identifier` + `fileSha256` | **MCP Registry submission snapshot** | Only when re-submitting a new `.mcpb` to the MCP Registry (independent cadence) |

`scripts/build-mcpb.sh` enforces the first three match; it will fail the build if any drifts. `server.json` is intentionally decoupled because bumping it requires a rebuilt `.mcpb`, a fresh SHA256, and a re-submission — steps that don't happen every source release.

#### Signing & Notarization (required for macOS 26+)

Starting v1.7.1, release binaries are signed with a Developer ID Application certificate and notarized via Apple's `notarytool`. This is **required** on macOS 26 — ad-hoc signed binaries cannot trigger Calendar / Reminders TCC permission dialogs there.

**Prerequisites** (one-time setup):

1. Apple Developer Program enrollment.
2. Developer ID Application certificate installed in login keychain.
   - Verify with: `security find-identity -p codesigning -v` (must show `Developer ID Application: <Your Name> (<TeamID>)`).
   - Your Team ID is your own — find it at <https://developer.apple.com/account> → Membership Details. (The maintainer's `6W377FS7BS` shown anywhere in this repo is for reference only.)
3. `notarytool` keychain profile (any name; `che-ical-mcp` is the default the build script looks for).
   - Create interactively (recommended — keeps password out of shell history):
     ```bash
     xcrun notarytool store-credentials che-ical-mcp --apple-id <your-apple-id> --team-id <your-team-id>
     # notarytool will prompt for the app-specific password
     ```
   - App-specific password: generate at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords. Use a single-purpose password (e.g. named `che-ical-mcp`); revoke + regenerate if leaked. **Never** pass it via `--password` on the command line — it lands in `~/.zsh_history`.
4. Export your identity for the build script:
   ```bash
   export DEVELOPER_ID='Developer ID Application: <Your Name> (<TeamID>)'
   export NOTARY_PROFILE='che-ical-mcp'   # match what you set up in step 3
   ```
   Persist these in `~/.zshrc` or a project-local `.envrc` (gitignored). The script intentionally has **no defaults** for these, so a fresh fork doesn't fail with errors referring to the maintainer's identity.

**Per-release flow**:

```bash
make release-signed     # builds universal binary → signs + notarizes → packages .mcpb
gh release create vX.Y.Z mcpb/server/CheICalMCP mcpb/server/CheICalMCP.sha256 mcpb/che-ical-mcp-X.Y.Z.mcpb mcpb/che-ical-mcp-X.Y.Z.mcpb.sha256 --notes "..."
```

`make release-signed` runs `scripts/build-mcpb.sh`, which after creating the universal binary calls `scripts/sign-and-notarize.sh`. The signing script does pre-flight checks (cert + notarytool profile) and fails fast with friendly messages if anything's missing. Notarization typically takes 1–15 minutes (`notarytool submit --wait` blocks until Apple finishes).

**Verification** after build (run all three to confirm end-to-end):

```bash
# 1. Signature properties (cert + hardened runtime + team ID)
codesign -dv --verbose=2 mcpb/server/CheICalMCP
# Expected:
#   Authority=Developer ID Application: <Your Name> (<TeamID>)
#   TeamIdentifier=<TeamID>
#   flags=0x10000(runtime)
#   Signature size in the few thousand bytes range (varies by cert chain)

# 2. Signature integrity
codesign --verify --deep --strict --verbose=2 mcpb/server/CheICalMCP
# Expected: exit 0, no warnings

# 3. Notarization end-to-end (this is the real "Gatekeeper would accept" gate)
spctl -a -vvv -t install mcpb/server/CheICalMCP
# Expected: <binary>: accepted; source=Notarized Developer ID
#
# Note on flag choice (verified empirically on macOS 26.4.1, 2026-05-04):
#   -t execute → rejected "code is valid but does not seem to be an app"
#                (Apple's "execute" type expects a .app bundle structure,
#                 not raw Mach-O CLI binaries)
#   -t install → accepted; source=Notarized Developer ID  ← use this
#   -t open    → rejected "Insufficient Context"
#
# Apple's Code Signing Guide describes -t execute as the assessment type for
# "applications and tools", but on macOS 26 raw Mach-O binaries fall through
# the .app bundle check. -t install is the documented assessment type for
# software being installed (which describes how a CLI binary lands in ~/bin),
# and is the type that returns the actual notarization verdict in practice.
# Re-test if Apple changes this behavior in a future macOS update.
```

**Local dev iteration** without signing latency:

```bash
SKIP_CODESIGN=1 ./scripts/build-mcpb.sh   # ad-hoc signed; do NOT ship the result
make install                              # installs ad-hoc to ~/bin (dev only)
```

The `build-mcpb.sh` script also **auto-skips signing** when `DEVELOPER_ID` is unset OR the cert isn't in your keychain — so contributors / CI / forks can build a working unsigned `.mcpb` for testing without manually setting `SKIP_CODESIGN`. (You'll see a clear "Skipping codesign" warning when this happens.)

**Signing identity environment**:

| Env var | Default | Required for |
|---------|---------|--------------|
| `DEVELOPER_ID` | _(unset — auto-skip signing)_ | Signed release |
| `NOTARY_PROFILE` | _(unset — fail-fast in `sign-and-notarize.sh`)_ | Signed release |
| `ENTITLEMENTS` | `Sources/CheICalMCP/Entitlements.plist` | Custom entitlements file |
| `SKIP_CODESIGN` | _(unset)_ | Force-skip signing even with cert present (set to `1` or `true`) |
| `REQUIRE_CODESIGN` | _(unset)_ | Fail-fast if signing prerequisites missing (set to `1` by `make release-signed` — canonical release path must not silently produce unsigned artifacts; do not set when running `./scripts/build-mcpb.sh` directly for fork-friendly dev builds) |

**Known limitation — no stapling**: `stapler staple` does not support raw Mach-O binaries (only `.app` / `.pkg` / `.dmg` bundles). After notarization, Gatekeeper will online-check the binary on first launch instead of reading a stapled ticket. End users behind air-gapped networks may see "cannot verify developer" warnings; one launch with network resolves it (Apple caches the verdict). Mitigation: `xcrun stapler staple` on a future `.pkg` wrapper if needed.

**Troubleshooting**:

- Notarization rejected? `xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE` shows Apple's reason. The signing script prints the submission ID on every run.
- `codesign` complains about missing identity? `security find-identity -p codesigning -v` to confirm cert is present + valid; `xcrun notarytool history --keychain-profile $NOTARY_PROFILE` to confirm the profile works.
- Cert expired? Re-issue at <https://developer.apple.com/account/resources/certificates>, install, re-export `DEVELOPER_ID`.
- Security warning: don't unlock signing keychain on shared / untrusted machines. The cert + private key signing artifact is supply-chain critical.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))

If you find this useful, please consider giving it a star!
