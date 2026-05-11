# che-ical-mcp — `.mcpb` Installation Guide

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
