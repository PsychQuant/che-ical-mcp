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

**Why this is needed** (corrected #114; original cdhash framing was disproved by #108 Phase 1 smoke test): macOS Calendar / Reminders access is gated by TCC (Transparency, Consent & Control). TCC entries are keyed by a designated requirement (csreq) — for our notarized, Developer-ID-signed binary the csreq survives cdhash changes across releases, so a previously-granted permission keeps working on upgrade as long as the binary's signing identity stays stable. (Verified empirically: TCC grants for `~/bin/CheICalMCP` survived 5 consecutive binary swaps in #108 Phase 1.)

The silent-failure mode users hit pre-v1.9.0 was instead an in-process cache anti-pattern: `EventKitManager` used to short-circuit on actor-private `hasCalendarAccess` / `hasReminderAccess` booleans set on first successful access. If TCC state later changed (manual revoke in System Settings, fresh install in a parallel context, or any state shift outside the running process), the cached booleans stayed `true` and the next call returned a stale-grant `accessDenied` from EventKit — without re-prompting and without surfacing the underlying revocation. This violated Apple's documented "call `authorizationStatus(for:)` every time" pattern (TN3153 + `EKEventStore.authorizationStatus(for:)` API docs).

**v1.9.0 (#108 Phase 2) replaced the cache with a per-call `AuthorizationGate.ensureAccess(...)`** — every Calendar/Reminders operation now reads fresh TCC state via `EKEventStore.authorizationStatus(for:)` before the underlying call. Any subsequent state change surfaces as an immediate `accessDenied` with the appropriate `EventKitError.accessDenied` workaround text (SSH / launchd / interactive variants).

For **first install** on a machine that has never granted TCC to this binary, the steps below are still required — you'll see `notDetermined` from the diagnostic query and need to trigger the initial prompt via Terminal. Subsequent upgrades from v1.9.0+ generally don't need re-running `--setup` unless the system surfaces `denied` (manual revoke or framework-layer reset). The `che-ical-mcp 1.10.0` startup banner (#122) prints current TCC state on every spawn so you can verify without manual SQL.

### Step 1 — verify current TCC state

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%CheICalMCP%'"
```

Interpret the result:

| `auth_value` | Meaning | Action |
|---|---|---|
| `2` | Granted | No action needed — calendar tools should work. If they don't, the v1.9.0 per-call gate (#108 Phase 2) will surface the underlying reason as an explicit `accessDenied` error in tool output rather than silently masking it. |
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

### Symptom: tool calls fail with `accessDenied` after upgrade

> **Corrected #114**: pre-v1.9.0 this section claimed cdhash invalidation was the cause. That hypothesis was disproved by #108 Phase 1 smoke (TCC grants survived 5 binary swaps because csreq is stable across cdhash for the same Developer-ID identity). The real silent-failure mode was the in-process `has*Access` cache anti-pattern, structurally fixed in v1.9.0 (#108 Phase 2): every Calendar/Reminders call now reads fresh TCC state instead of trusting a cached boolean.

If you see `accessDenied` after upgrade on v1.9.0+, the underlying TCC state actually IS denied (System Settings toggle, framework-layer reset, etc.). Run the Step 1 SQL query to confirm `auth_value` — if `0`, follow the troubleshooting `tccutil reset` snippet to re-grant. Stale-cache silent failures cannot happen with the per-call gate.

If you're on **v1.8.x or earlier** AND seeing this symptom, upgrading to v1.9.0+ is the structural fix; the manual Steps 1–4 remediation is a stopgap for that older release line. See [#108](https://github.com/PsychQuant/che-ical-mcp/issues/108) for the full root-cause analysis and the disproved-hypothesis audit trail.

### Verifying the fix worked

After Step 4, run the Step 1 SQL query again. You should now see two rows with `auth_value=2` and a recent `last_modified` timestamp matching today's date. If the timestamp didn't update, Step 3 didn't actually trigger the prompt — reset via the troubleshooting snippet and retry.

## See also

- [`PRIVACY.md`](PRIVACY.md) — what data this extension accesses and how
- [Repo README](../README.md) — full feature list, tool reference, development setup
- [Issue #108](https://github.com/PsychQuant/che-ical-mcp/issues/108) — RCA of the upgrade-time TCC behavior this guide addresses
