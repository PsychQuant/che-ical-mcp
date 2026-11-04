---
name: troubleshoot-tcc
description: Diagnose and fix macOS TCC (Calendar/Reminders) permission issues for che-ical-mcp. Use when user reports calendar tools failing silently, "permission denied" errors, missing TCC dialog after reinstall/upgrade, or asks "為什麼 calendar 不能用". Walks through both TCC layers — the CheICalMCP binary's own grant AND the host-app (responsible process) entry — plus TCC db inspection, --print-tcc-path diagnostic, tccutil reset, and --setup re-prompt flow.
allowed-tools:
  - Bash
  - Read
---

# Troubleshoot TCC permissions for che-ical-mcp

This skill is the **first thing to try** when calendar / reminder tools fail. Most "calendar tools don't work" reports are TCC (Transparency, Consent & Control) state issues rather than code bugs.

## v1.23.0+: CheICalMCP uses its own grant whenever the host has none (#343) — read this first

- **TCC checks only the responsible process.** Measured in #343 with one variable changed: the same `~/bin/CheICalMCP --print-tcc-path` read `fullAccess` when spawned under VS Code, although CheICalMCP's own grant was empty at the time, and `notDetermined` when spawned disclaimed (CheICalMCP responsible for itself). The host's grant alone decided the first result; CheICalMCP's own grant alone decided the second.
- **The rule**: From v1.23.0 the rule depends on the grant macOS checks for this binary, that of its responsible process (which is not always the process that starts it), and it is the same for every host: before any dispatch the binary reads that context's authorization status. If it already has full access to both Calendar and Reminders (Terminal, VS Code, a Claude Code version-number entry, any host), that grant is kept and nothing is re-exec'd. A host that a policy (a configuration profile or Screen Time) restricts for either service keeps its attribution too, because CheICalMCP's own grant is not what that policy covers (#367). Otherwise, including a host with only one of the two or one the user denied, the binary re-execs in place as its own responsible process (`posix_spawn` + `POSIX_SPAWN_SETEXEC` + disclaim, the call Claude Desktop's `disclaimer` makes; pid and stdio unchanged), so macOS checks the `CheICalMCP` grant, the one `--setup` creates. This covers the MCP server, `--cli`, `--print-tcc-path` and `--setup`; `--setup` re-execs under any host, because it is the action that creates CheICalMCP's own grant. (v1.22.0 re-exec'd by default only when Claude Code was the responsible process, and under any host when `CHE_ICAL_MCP_FORCE_DISCLAIM` was set.) A host with full access, or one a policy restricts, keeps its entry in System Settings; for every other host only the **`CheICalMCP`** entry matters.
- **Trade-off**: once CheICalMCP's own grant is allowed, any process that runs this binary from a context without full access of its own (another app, a script, a launchd or cron job, a Claude Code session, `--cli` included, and a host the user denied Calendar or Reminders to; not a host a policy restricts, which keeps its attribution, #367) reads Calendar and Reminders under that grant without a separate consent. v1.22.0 did this by default only under Claude Code, and for any caller that set `CHE_ICAL_MCP_FORCE_DISCLAIM`, without a notice. `CHE_ICAL_MCP_NO_DISCLAIM=1` keeps host attribution for the environment that sets it; it does not stop another process from running the binary without it. `CHE_ICAL_MCP_FORCE_DISCLAIM=1` re-execs even under a host with a grant of its own, but not under a host a policy restricts (the opt-out wins over it; a forced re-exec prints one stderr line).
- **First run after upgrading**: CheICalMCP's own grant may start as `notDetermined`. Allow the macOS prompt for CheICalMCP, or run `~/bin/CheICalMCP --setup` in the foreground, which prints `Authorization target: CheICalMCP (...)` before asking, then restart the client. A background Claude Code session can show the prompt: on 2026-10-24 a disclaimed `--setup` run from a background session put up the dialog (#343, S1); if nobody is at the screen, the tool call waits until it times out. **Not verified**: CI does not cover reading the calendar through the re-exec. On 2026-10-28 v1.22.0 read the calendar through a forced re-exec with `--cli`; a re-exec that a Claude Code worker launched through `ClaudeCode.app` triggers by itself, and server mode after the re-exec, have not been observed yet.
- **To see which process macOS checks**, run `--print-tcc-path` and read the `TCC attribution` line. Do not infer it from `ps` ancestry: under the Claude Code daemon the parent chain does not show it. A spare-claimed session inherits the app that launched the daemon (e.g. VS Code), while a worker the daemon launches through `ClaudeCode.app` is its own responsible process, and the two chains look alike. That was measured on Claude Code 2.1.309; on 2.1.312 a background session's shell and every process it started were each their own responsible process (#344), so read the line instead of assuming either case.

## The two-layer authorization model (#168; applies to v1.21.0 and earlier, to a host with full access of its own, or with `CHE_ICAL_MCP_NO_DISCLAIM=1`)

macOS TCC may attribute a Calendar/Reminders access check to the **responsible process** — the host app that (transitively) spawned the binary — not only to the binary itself. Two independent layers can therefore appear in System Settings → Privacy & Security → Calendar / Reminders:

| Layer | Entry looks like | When it exists |
|---|---|---|
| **Binary layer** — CheICalMCP's own grant | `CheICalMCP` with a green `exec` icon | Created by `--setup` dialogs or Claude Desktop's first prompt |
| **Host layer** — the responsible process | Depends on host, see table below | Created when a TCC check is attributed to the host context |

Host-layer entry names:

| Host | Host-layer entry in System Settings | Notes |
|---|---|---|
| **Claude Code** (CLI) | A bare **version-number string**, e.g. `2.1.202`, with a question-mark document icon | That IS the Claude Code native binary — the real executable lives at `~/.local/share/claude/versions/<version>` (`~/.local/bin/claude` is a symlink to it), and TCC displays a path-keyed client by its filename. ⚠️ The path **rotates on every Claude Code update**, so this grant can silently go stale (#170) |
| **Terminal.app / iTerm2 / VS Code** | The app's own name | Applies when you run the binary (or claude) from that app's shell |
| **Claude Desktop** | *(no host entry needed)* | Desktop spawns `.mcpb` servers via `/Applications/Claude.app/Contents/Helpers/disclaimer`, which makes the child its **own** responsible process — the `.mcpb` `CheICalMCP` entry is self-contained. (The disclaimer shim `exec`-replaces itself, so it usually won't show up in a live `ps` ancestry trace — identify Desktop context by the *absence* of a `claude/versions/…` ancestor, not by finding the disclaimer.) |

**Operative rule**: for the host you actually use, make sure **both** the `CheICalMCP` entry and the host-layer entry are toggled ON. (From v1.23.0 the host-layer entry is checked only while it has full access; otherwise the server falls back to the `CheICalMCP` entry, see the top of this skill. #343 settled the AND/OR question: only the responsible process's entry is checked. Both-ON still works, but only one of them is doing anything.)

## When to invoke

User-reported symptoms that map to TCC issues:
- "Calendar 工具沒回應 / 失敗 / permission denied"
- "重新安裝 / 升級 mcpb 後不能用"
- "TCC 對話框沒彈出來"
- 收到 `accessDenied` / `insufficientAccess` / `unknownAuthState` error
- Tool calls return blank results despite valid arguments
- Toggling the `CheICalMCP` switch changes nothing (→ almost certainly the host layer, Step 3)

## Diagnostic flow (6 steps)

### Step 1: Identify the failing host + locate its binary

There are **two independent installs**, each with its own binary path and its own TCC grant. First ask: which host is failing?

```bash
# Claude Desktop (.mcpb install)
find ~/Library/Application\ Support/Claude -name CheICalMCP 2>/dev/null | head -1

# Claude Code (plugin wrapper install)
ls ~/bin/CheICalMCP 2>/dev/null
```

Expected: Desktop → a path under `local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP`; Claude Code → `~/bin/CheICalMCP`.

If the relevant one is empty → not installed. Send user to https://github.com/PsychQuant/che-ical-mcp/releases/latest

> Granting one install does **not** cover the other — they are separate TCC clients.

### Step 2: Run `--print-tcc-path` (v1.9.0+ diagnostic flag) — in the right context

```bash
BINARY=<path from Step 1>
"$BINARY" --print-tcc-path
```

> **⚠️ The output is context-dependent, not an absolute property of the binary (#168).** `EKEventStore.authorizationStatus(for:)` reflects the TCC attribution of the context the command runs in — the responsible process — not (only) the binary path. Empirically: running two *different* CheICalMCP binaries from the same Claude Code shell returns *identical* status, and the same binary can report `notDetermined` from one context while System Settings shows its toggle ON (granted via another context). To diagnose a specific host's tool calls, read the status **from that host's own context**:
>
> | Host you're diagnosing | Where to read the status |
> |---|---|
> | Claude Code | Run `--print-tcc-path` via Claude Code's own Bash tool (inside a Claude Code session) |
> | Claude Desktop | Read the startup banner in Desktop's MCP log (`~/Library/Logs/Claude/mcp-server-macOS Calendar and Reminders.log`) — the banner (#122) prints TCC state on every spawn, inside the disclaimed `.mcpb` context |
> | Terminal | Running it in Terminal reflects Terminal-side attribution — useful for the `--setup` path, but may differ from both hosts above |

Interpreting the status lines:

| Output line | Meaning |
|---|---|
| `Calendar: fullAccess (granted)` | OK, this side is fine |
| `Calendar: notDetermined` | This *context* was never asked → check the host layer (Step 3), then re-prompt (Step 5) |
| `Calendar: denied` | Explicitly denied in this context → go to Step 4 (reset) |
| `Calendar: writeOnly` | Partial access (macOS 14+) → user must manually upgrade in System Settings → Privacy & Security → Calendar |
| `Calendar: restricted` | System policy (Screen Time / MDM) — outside our control |

Same logic applies to `Reminders` line.

### Step 3: Check the host-app (responsible process) layer

Open **System Settings → Privacy & Security → Calendar** (then repeat for **Reminders**) and look for a host-layer entry per the table at the top of this skill:

- Claude Code → a version-number entry like `2.1.202`. From v1.23.0 it is used only while it has full access, otherwise the `CheICalMCP` entry is used, so skip this bullet unless you set `CHE_ICAL_MCP_NO_DISCLAIM=1` or run v1.21.0 and earlier: toggle it **ON**. If it's stale (older version number than `claude --version`), the grant no longer matches the current binary path: trigger a calendar tool call from Claude Code so macOS re-prompts / re-creates the entry, then toggle the new one ON (#170).
- Terminal / VS Code → the app's name — toggle **ON** if you run tools through it.
- Claude Desktop → no host entry needed (disclaimer isolation).

On v1.22.0+, `--print-tcc-path` prints the responsible process directly (the `TCC attribution` line) — use that. The ancestry trace below is the fallback for v1.21.0 and earlier, and it can mislead under the Claude Code daemon (#343).

To approximate **which host context** a running server belongs to on v1.21.0 and earlier, trace its ancestry:

```bash
# Set P to a CheICalMCP pid from: pgrep -fl CheICalMCP
P=<pid>; while [ -n "$P" ] && [ "$P" -gt 1 ] 2>/dev/null; do ps -o pid=,ppid=,comm= -p "$P"; P=$(ps -o ppid= -p "$P" | tr -d ' '); done
```

Read the chain like this:
- Contains `.../claude/versions/<version>` → **Claude Code** context (the version-number binary is the responsible process; this half is reliable — the versioned binary stays resident in the live tree).
- **Claude Desktop** is identified by *absence*: the `Helpers/disclaimer` shim typically `exec`-replaces itself with the server binary, so it usually does **not** appear as a live ancestor. A Desktop-spawned server's chain is roughly `CheICalMCP → Claude → launchd` with **no** `claude/versions/…` segment. So: chain lacks the `claude/versions/…` segment **and** the running binary is the `.mcpb` path (from Step 1) → treat as Desktop / self-responsible.

### Step 4: Reset stale TCC entries (only if `denied` or post-upgrade silent fail)

```bash
tccutil reset Calendar com.checheng.CheICalMCP
tccutil reset Reminders com.checheng.CheICalMCP
```

> **Caveat**: TCC stores `.mcpb` clients by **binary path** rather than bundle ID. `tccutil reset SERVICE BUNDLE_ID` may report "Successfully reset" but actually no-op when the underlying entry is path-keyed. If the issue persists after reset + Step 5, fall back to manual System Settings toggle (Step 6).

### Step 5: Trigger re-prompt via `--setup`

```bash
"$BINARY" --setup
```

Two macOS dialogs should appear (Calendar + Reminders) — user clicks **Allow** on both. From v1.22.0 `--setup` re-execs as its own responsible process, so the grant lands on CheICalMCP whichever app runs it, unless `CHE_ICAL_MCP_NO_DISCLAIM` is set where it runs (then it lands on that app); from v1.23.0, restart the MCP client afterwards so a host without full access re-execs onto that grant (a host a policy restricts keeps its own attribution, #367).

Over SSH, or anywhere without a GUI session (a launchd daemon) or launched directly by launchd, the dialogs **cannot** appear, and `--setup` skips the request for a `notDetermined` status instead of waiting — instruct the user to run this in `Terminal.app` on the Mac itself. A background Claude Code session can show them (#343, S1, see the top of this skill), but only if someone is at the screen.

### Step 6: Manual fallback (when --setup keeps failing)

System Settings → Privacy & Security → Calendar:
- Look for CheICalMCP, toggle on
- If not listed, click `+`, navigate to the binary path from Step 1
- Also confirm the host-layer entry (Step 3) is present and ON

Repeat for Reminders.

Restart Claude Desktop (Cmd+Q, not just window close) after granting.

## 完全打通授權 checklist (fresh install → tools working)

The complete "what to click" list, per host:

**Claude Code (wrapper install, `~/bin/CheICalMCP`)**

> v1.23.0+ (#343): steps 1, 2 and a client restart are enough — `--setup` re-execs as its own responsible process under any host, so the grant lands on CheICalMCP even from Terminal, and every session whose host has no full access of its own uses it. Steps 3–5 apply only with `CHE_ICAL_MCP_NO_DISCLAIM=1` or on v1.21.0 and earlier.

1. In Terminal.app, run `~/bin/CheICalMCP --setup` → click **Allow** on both dialogs (Calendar + Reminders). This creates the `CheICalMCP` binary-layer grant; from v1.22.0 it prints `Authorization target: CheICalMCP (...)`, because `--setup` re-execs as its own responsible process. ⚠️ On v1.21.0 and earlier, or with `CHE_ICAL_MCP_NO_DISCLAIM=1`, the *responsible process* for this grant is Terminal, not Claude Code — then this step only gets the `CheICalMCP` entry created and proves the binary can prompt, and the host-layer grant that gates Claude Code's tool calls is created in step 3, from a Claude Code session.
2. System Settings → Privacy & Security → **Calendar**: confirm `CheICalMCP` toggle **ON**; repeat under **Reminders**
3. In a Claude Code session, trigger a calendar tool call (e.g. "list 我今天的 events") — this is the step that establishes the Claude Code host-layer grant:
   - If a new permission dialog appears → **Allow** (creates the host-layer grant)
   - If the call fails without a dialog → check both panes for the **version-number entry** (e.g. `2.1.202`) and toggle it **ON**
4. Re-run the tool call → should return real data
   - Still failing after clicking Allow in step 1 but not step 3? That's the classic #168 symptom — the step-1 grant landed on Terminal's attribution, not Claude Code's. The step-3 host-layer entry is the one that matters here.
5. **After every Claude Code update**: if calendar tools break again, re-check Step 3's version-number entry — the binary path rotated (#170)

**Claude Desktop (`.mcpb` install)**

1. Install the `.mcpb`, then fully quit Desktop (**Cmd+Q**, not window close) and reopen
2. Trigger a calendar tool call → click **Allow** on both dialogs (attributed directly to the `.mcpb` binary thanks to disclaimer isolation)
   - If no dialog appears: run `"<.mcpb binary path from Step 1>" --setup` from Terminal.app instead
3. System Settings → Privacy & Security → Calendar + Reminders: confirm `CheICalMCP` toggle **ON** (no host-layer entry needed for Desktop)

## Verifying which entry gates your context (toggle-and-observe)

The AND/OR semantics of the two layers are not conclusively established. To determine empirically which entry gates *your* setup — change **one variable at a time** (same single-variable discipline that settled #166):

1. Start from a fully working state (tool call returns real data)
2. Toggle **OFF** exactly one entry (e.g. the host-layer `2.1.202`), leave everything else untouched
3. Re-run the tool call / `--print-tcc-path` **in the host context** (per Step 2's table)
4. Record whether it flipped to `denied` / failed
5. Toggle back **ON**, verify it works again, then repeat for the other entry

If toggling an entry OFF breaks the call, that entry is load-bearing for this context.

## Verifying the fix worked

```bash
# Binary-layer entries
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%CheICalMCP%'"

# Host-layer entries (Claude Code versioned binary / Claude.app)
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value, datetime(last_modified,'unixepoch','localtime') FROM access WHERE client LIKE '%claude%' AND service IN ('kTCCServiceCalendar','kTCCServiceReminders')"
```

Expected: rows with `auth_value=2` (granted) and `last_modified` matching today's date.

> If sqlite3 fails with `unable to open database file`, the shell running the query lacks Full Disk Access — that's a limitation of the *querying* shell, not a signal about the Calendar/Reminders grants. Fall back to reading System Settings directly.

Then trigger a tool call to confirm:

```
list 我今天的 events
```

## Why not just retry the failing tool?

Pre-v1.9.0 binary cached the granted state in `hasCalendarAccess` / `hasReminderAccess` flags for process lifetime. After v1.9.0 the cache is removed — every tool call freshly reads `EKEventStore.authorizationStatus(for:)`, so TCC state changes surface immediately. Per-call status check means **the error you see is the current truth for the calling context** (see Step 2's context-dependence warning), not a stale cached signal — fix the TCC state, retry the tool.

## When this is NOT a TCC issue

If the status read *in the failing host's context* (per Step 2's table) shows both `fullAccess (granted)` but tools still fail with `accessDenied` or other errors:
- TCC state is healthy → real bug, file an issue at https://github.com/PsychQuant/che-ical-mcp/issues
- Include full error message + `--print-tcc-path` output + the failing tool name + arguments

## References

- mcpb/README.md (v1.8.1+): user-facing setup guide same workflow
- Issue #108: full diagnosis of the cache anti-pattern + cdhash invalidation hypothesis (falsified) + corrected root cause
- Issue #109: `--print-tcc-path` diagnostic flag (closed in v1.9.0)
- Issue #168: two-layer (responsible process) authorization model + context-dependence of `--print-tcc-path`
- Issue #169: (open) `--print-tcc-path` should print its own execution context
- Issue #170: (open) Claude Code updates rotate the versioned binary path → host-layer grant goes stale
- Apple TN3153: per-call `authorizationStatus(for:)` recommended pattern
