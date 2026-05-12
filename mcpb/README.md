# che-ical-mcp — `.mcpb` Installation Guide

> ## ⚠️ Known broken on Claude Desktop 1.6608.2+ (as of 2026-05-12)
>
> **The `.mcpb` extension install path cannot write to Calendar or Reminders on Claude Desktop 1.6608.2 and later.** Read paths (e.g. `list_events`, `search_events`) still work. All write tools (`create_event` / `update_event` / `create_reminder` / etc.) return `Calendar access denied` regardless of TCC.db state.
>
> **Cause**: regression in Claude Desktop 1.6608.2 (released ~2026-05-09). Verified by 94 successful `.mcpb` writes pre-1.6608.2 versus 10 consecutive failures starting 2026-05-11. Same binary continues to work via Terminal context. The structural gap is missing `com.apple.security.personal-information.calendars` entitlement + missing `NSCalendarsFullAccessUsageDescription` in `Claude.app/Contents/Info.plist`.
>
> **Use one of these workarounds until Anthropic ships a fix:**
>
> | Path | Status | How |
> |------|--------|-----|
> | **Claude Code plugin** | ✓ Works | Install via `claude plugin install che-ical-mcp@psychquant-claude-plugins` — binary auto-downloads to `~/bin/CheICalMCP`, spawn context bypasses the broken `.mcpb` wrapper |
> | **Legacy `claude_desktop_config.json`** | ⚠ Untested | Manually edit `~/Library/Application Support/Claude/claude_desktop_config.json` to point at the binary directly; may bypass the `disclaimer` wrapper |
> | **Google Calendar API** | ✓ Works | Bypass macOS Calendar entirely; manually move to target calendar afterwards |
>
> **Tracking**: upstream report at [`anthropics/claude-code#58239`](https://github.com/anthropics/claude-code/issues/58239), local tracker at [`PsychQuant/che-ical-mcp#132`](https://github.com/PsychQuant/che-ical-mcp/issues/132). Once Anthropic restores `.mcpb` Calendar access, this section will be removed and the install steps below will work end-to-end again.

---

This directory ships the Claude Desktop `.mcpb` bundle for che-ical-mcp (macOS Calendar & Reminders MCP server). The bundle contains a signed, notarized binary that runs as a local subprocess of Claude Desktop and accesses Calendar / Reminders via Apple's EventKit framework.

## Install

1. Download the latest `che-ical-mcp-<VERSION>.mcpb` from the [GitHub release page](https://github.com/PsychQuant/che-ical-mcp/releases/latest).
2. Open the `.mcpb` file. Claude Desktop will recognize it and prompt to install.
3. Restart Claude Desktop after installation.

The binary lives under `~/Library/Application Support/Claude/Claude Extensions/local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP`.

## Post-install / Upgrade (TCC permissions)

**Why this is needed**: macOS Calendar / Reminders access is gated by TCC (Transparency, Consent & Control). TCC binds permission grants to the binary's path **and** code signature (cdhash). When a new release ships, the cdhash changes — TCC invalidates the existing grant and expects to re-prompt. But the MCP server is launched by Claude Desktop without a terminal session, so the re-authorization dialog cannot reliably appear (it gets attributed to the wrong process or suppressed). Result: calendar tool calls silently fail with `accessDenied`.

The fix is a one-time manual setup, triggered from Terminal, that lets macOS surface the TCC dialog properly. You only need to do this on first install **and** after each version upgrade.

### Step 1 — verify current TCC state

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%CheICalMCP%'"
```

Interpret the result:

| `auth_value` | Meaning | Action |
|---|---|---|
| `2` | Granted | No action needed — calendar tools should work. If they don't, proceed to Step 2 anyway (cdhash may have changed silently). |
| `0` | Denied | Reset and re-grant via Step 2 + the troubleshooting `tccutil reset` snippet below. |
| _(empty / no row)_ | Never asked | Proceed to Step 2 to trigger the dialog. |

### Step 2 — locate the installed binary

```bash
find ~/Library/Application\ Support/Claude -name CheICalMCP 2>/dev/null
```

This should print one path under `local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP`. Copy that path for Step 3.

If `find` returns nothing, the bundle hasn't been installed correctly — re-do the `.mcpb` install via Claude Desktop.

### Step 3 — run `--setup` from Terminal

> **Important**: Run this from `Terminal.app` directly, **not** over SSH. macOS TCC cannot show dialogs in SSH sessions.

```bash
BINARY=$(find ~/Library/Application\ Support/Claude -name CheICalMCP 2>/dev/null | head -1)
"$BINARY" --setup
```

Expected output:

```
CheICalMCP Setup — Requesting Calendar & Reminders permissions...
(This triggers macOS TCC permission dialogs for this binary)

Calendar access: ✓ granted
Reminders access: ✓ granted
```

macOS will pop up two dialogs (one for Calendar, one for Reminders). Click **Allow** on both.

### Step 4 — restart Claude Desktop

Quit and reopen Claude Desktop. Calendar tool calls should now succeed.

## Troubleshooting

### Dialog doesn't appear at all

TCC may have a stale `denied` record blocking the new prompt. Reset and retry:

```bash
tccutil reset Calendar com.checheng.CheICalMCP
tccutil reset Reminders com.checheng.CheICalMCP
```

Then re-run Step 3.

### Alt method — manually toggle in System Settings

If `--setup` keeps failing, you can grant access manually:

1. Open **System Settings → Privacy & Security → Calendar**
2. Look for **CheICalMCP** in the list; toggle it on. If it's not listed, click **+** and navigate to the path from Step 2.
3. Repeat for **Privacy & Security → Reminders**.
4. Restart Claude Desktop.

### Symptom: tool calls fail silently after upgrade

This is the canonical post-upgrade scenario. The binary at the same path now has a different cdhash, so the stored TCC grant doesn't validate. Re-run Steps 1–4. See [#108](https://github.com/PsychQuant/che-ical-mcp/issues/108) for the full root-cause analysis.

### Verifying the fix worked

After Step 4, run the Step 1 SQL query again. You should now see two rows with `auth_value=2` and a recent `last_modified` timestamp matching today's date. If the timestamp didn't update, Step 3 didn't actually trigger the prompt — reset via the troubleshooting snippet and retry.

## See also

- [`PRIVACY.md`](PRIVACY.md) — what data this extension accesses and how
- [Repo README](../README.md) — full feature list, tool reference, development setup
- [Issue #108](https://github.com/PsychQuant/che-ical-mcp/issues/108) — RCA of the upgrade-time TCC behavior this guide addresses
