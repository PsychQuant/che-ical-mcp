# che-ical-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**macOS Calendar & Reminders MCP server** - Native EventKit integration for complete calendar and task management.

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## Why che-ical-mcp?

| Feature | Other Calendar MCPs | che-ical-mcp |
|---------|---------------------|--------------|
| Calendar Events | Yes | Yes |
| **Reminders/Tasks** | No | **Yes** |
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

Download the latest `.mcpb` file from [Releases](https://github.com/kiki830621/che-ical-mcp/releases) and double-click to install.

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

```bash
# Create ~/bin if needed
mkdir -p ~/bin

# Download the latest release
curl -L https://github.com/kiki830621/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
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
git clone https://github.com/kiki830621/che-ical-mcp.git
cd che-ical-mcp
swift build -c release
```

On first use, macOS will prompt for **Calendar** and **Reminders** access - click "Allow".

---

## All 24 Tools

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
| `create_event` | Create an event (with reminders, location, URL) |
| `update_event` | Update an event |
| `delete_event` | Delete an event |

</details>

<details>
<summary><b>Reminders (6)</b></summary>

| Tool | Description |
|------|-------------|
| `list_reminders` | List reminders with filter/sort/limit (v1.0.0) |
| `create_reminder` | Create a reminder with due date |
| `update_reminder` | Update a reminder |
| `complete_reminder` | Mark as completed/incomplete |
| `delete_reminder` | Delete a reminder |
| `search_reminders` | Search reminders by keyword(s) with AND/OR matching (v0.9.0) |

</details>

<details>
<summary><b>Advanced Features (10)</b> ✨ New in v0.3.0+</summary>

| Tool | Description |
|------|-------------|
| `search_events` | Search events by keyword(s) with AND/OR matching |
| `list_events_quick` | Quick shortcuts: `today`, `tomorrow`, `this_week`, `next_7_days`, etc. |
| `create_events_batch` | Create multiple events at once |
| `check_conflicts` | Check for overlapping events in a time range |
| `copy_event` | Copy an event to another calendar (with optional move) |
| `move_events_batch` | Move multiple events to another calendar |
| `delete_events_batch` | Delete events by IDs or date range, with dry-run preview (v1.0.0) |
| `find_duplicate_events` | Find duplicate events across calendars (v0.5.0) |
| `create_reminders_batch` | Create multiple reminders at once (v0.9.0) |
| `delete_reminders_batch` | Delete multiple reminders at once (v0.9.0) |

</details>

---

## Installation

### Requirements

- macOS 13.0+
- Xcode Command Line Tools (only if building from source)

### For Claude Desktop

#### Method 1: MCPB One-Click Install (Recommended)

1. Download `che-ical-mcp.mcpb` from [Releases](https://github.com/kiki830621/che-ical-mcp/releases)
2. Double-click the `.mcpb` file to install
3. Restart Claude Desktop

#### Method 2: Manual Configuration

1. Download the binary:
   ```bash
   curl -L https://github.com/kiki830621/che-ical-mcp/releases/latest/download/CheICalMCP -o /usr/local/bin/che-ical-mcp
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
curl -L https://github.com/kiki830621/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# Register with Claude Code (user scope = available in all projects)
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

### Build from Source (Optional)

```bash
git clone https://github.com/kiki830621/che-ical-mcp.git
cd che-ical-mcp
swift build -c release

# Copy to ~/bin and register
cp .build/release/CheICalMCP ~/bin/
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

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
| Full ISO8601 | `"2026-02-06T14:00:00+08:00"` | Exact date and time |
| Without timezone | `"2026-02-06T14:00:00"` | Uses system timezone |
| Date only | `"2026-02-06"` | Midnight, system timezone |
| Time only | `"14:00"` | Today at that time |

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
| Server disconnected | Rebuild with `swift build -c release` |
| Permission denied | Grant Calendar/Reminders access in System Settings > Privacy & Security |
| Permission dialog never appears | See [Grant Permissions](#grant-permissions) for macOS Sequoia workaround |
| Calendar not found | Ensure the calendar is visible in macOS Calendar app |
| Reminders not syncing | Check iCloud sync in System Settings |

---

## Technical Details

- **Current Version**: v1.2.0
- **Framework**: [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.10.2
- **Calendar API**: EventKit (native macOS framework)
- **Transport**: stdio
- **Platform**: macOS 13.0+ (Ventura and later)
- **Tools**: 24 tools for calendars, events, reminders, and advanced operations

---

## Version History

| Version | Changes |
|---------|---------|
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

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))

If you find this useful, please consider giving it a star!
