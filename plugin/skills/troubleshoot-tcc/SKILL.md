---
name: troubleshoot-tcc
description: Diagnose and fix macOS TCC (Calendar/Reminders) permission issues for che-ical-mcp. Use when user reports calendar tools failing silently, "permission denied" errors, missing TCC dialog after reinstall/upgrade, or asks "為什麼 calendar 不能用". Walks through TCC db inspection, --print-tcc-path diagnostic, tccutil reset, and --setup re-prompt flow.
allowed-tools:
  - Bash
  - Read
---

# Troubleshoot TCC permissions for che-ical-mcp

This skill is the **first thing to try** when calendar / reminder tools fail. Most "calendar tools don't work" reports are TCC (Transparency, Consent & Control) state issues rather than code bugs.

## When to invoke

User-reported symptoms that map to TCC issues:
- "Calendar 工具沒回應 / 失敗 / permission denied"
- "重新安裝 / 升級 mcpb 後不能用"
- "TCC 對話框沒彈出來"
- 收到 `accessDenied` / `insufficientAccess` / `unknownAuthState` error
- Tool calls return blank results despite valid arguments

## Diagnostic flow (4 steps)

### Step 1: Locate the binary

```bash
find ~/Library/Application\ Support/Claude -name CheICalMCP 2>/dev/null | head -1
```

Expected: a path under `local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP`.

If empty → `.mcpb` not installed in Claude Desktop. Send user to https://github.com/PsychQuant/che-ical-mcp/releases/latest

### Step 2: Run `--print-tcc-path` (v1.9.0+ diagnostic flag)

```bash
BINARY=$(find ~/Library/Application\ Support/Claude -name CheICalMCP 2>/dev/null | head -1)
"$BINARY" --print-tcc-path
```

The output is the single source of truth — read it carefully:

| Output line | Meaning |
|---|---|
| `Calendar: fullAccess (granted)` | OK, this side is fine |
| `Calendar: notDetermined` | Never asked → go to Step 4 (run `--setup`) |
| `Calendar: denied` | Explicitly denied → go to Step 3 (reset) |
| `Calendar: writeOnly` | Partial access (macOS 14+) → user must manually upgrade in System Settings → Privacy & Security → Calendar |
| `Calendar: restricted` | System policy (Screen Time / MDM) — outside our control |

Same logic applies to `Reminders` line.

### Step 3: Reset stale TCC entries (only if `denied` or post-upgrade silent fail)

```bash
tccutil reset Calendar com.checheng.CheICalMCP
tccutil reset Reminders com.checheng.CheICalMCP
```

> **Caveat**: TCC stores `.mcpb` clients by **binary path** rather than bundle ID. `tccutil reset SERVICE BUNDLE_ID` may report "Successfully reset" but actually no-op when the underlying entry is path-keyed. If the issue persists after reset + Step 4, fall back to manual System Settings toggle (Step 5).

### Step 4: Trigger re-prompt via `--setup`

```bash
"$BINARY" --setup
```

Two macOS dialogs should appear (Calendar + Reminders) — user clicks **Allow** on both.

If running over SSH or in a non-interactive shell, dialogs **cannot** appear — instruct user to run this in `Terminal.app` directly.

### Step 5: Manual fallback (when --setup keeps failing)

System Settings → Privacy & Security → Calendar:
- Look for CheICalMCP, toggle on
- If not listed, click `+`, navigate to the binary path from Step 1

Repeat for Reminders.

Restart Claude Desktop after granting.

## Verifying the fix worked

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%CheICalMCP%'"
```

Expected: 2 rows with `auth_value=2` (granted) and `last_modified` matching today's date.

Then trigger a tool call to confirm:

```
list 我今天的 events
```

## Why not just retry the failing tool?

Pre-v1.9.0 binary cached the granted state in `hasCalendarAccess` / `hasReminderAccess` flags for process lifetime. After v1.9.0 the cache is removed — every tool call freshly reads `EKEventStore.authorizationStatus(for:)`, so TCC state changes surface immediately. Per-call status check means **the error you see is the current truth**, not a stale cached signal — fix the TCC state, retry the tool.

## When this is NOT a TCC issue

If `--print-tcc-path` shows both `fullAccess (granted)` but tools still fail with `accessDenied` or other errors:
- TCC state is healthy → real bug, file an issue at https://github.com/PsychQuant/che-ical-mcp/issues
- Include full error message + `--print-tcc-path` output + the failing tool name + arguments

## References

- mcpb/README.md (v1.8.1+): user-facing setup guide same workflow
- Issue #108: full diagnosis of the cache anti-pattern + cdhash invalidation hypothesis (falsified) + corrected root cause
- Issue #109: `--print-tcc-path` diagnostic flag (closed in v1.9.0)
- Apple TN3153: per-call `authorizationStatus(for:)` recommended pattern
