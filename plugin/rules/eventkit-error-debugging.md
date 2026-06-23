# EventKit Error Debugging — TCC-First Rule

When **any** che-ical-mcp tool returns an EventKit-related error (`accessDenied`, `insufficientAccess`, `unknownAuthState`, or `permission denied`-flavored messages), **do not assume a code bug**. The first hypothesis must be **TCC state**, not the tool's logic.

## Why

Pre-v1.9.0 the binary cached `hasCalendarAccess` / `hasReminderAccess` for the process lifetime. After v1.9.0 the cache is removed — every tool call freshly reads `EKEventStore.authorizationStatus(for:)`. This means: when you see `accessDenied`, **the TCC state at this moment really is denied** (or notDetermined / writeOnly / restricted). The error reflects reality.

Pre-v1.9.0 you could rationalize "maybe the cache is stale, retry will work"; post-v1.9.0 retry produces the same error because TCC reality hasn't changed. Fixing TCC state is the only path forward.

## What to do

1. **Stop**. Do not retry the failing tool.
2. **Invoke the `troubleshoot-tcc` skill** or run the `/check-tcc` slash command (both wrap the v1.9.0 `--print-tcc-path` diagnostic flag).
3. Read the binary's output carefully — it self-describes the current state and the appropriate fix path.
4. Only after `--print-tcc-path` shows `fullAccess (granted)` for both Calendar and Reminders, retry the original tool call.
5. **If the tool still fails after TCC state is verified healthy**, then suspect a real bug:
   - Capture the full error message + `--print-tcc-path` output + tool name + arguments
   - File an issue at https://github.com/PsychQuant/che-ical-mcp/issues

## What NOT to do

- ❌ Don't retry the same tool hoping the cache "refreshes" (post-v1.9.0 there is no cache)
- ❌ Don't immediately suggest user reinstall — reinstall doesn't fix TCC state, it only adds friction
- ❌ Don't blame transient errors — TCC errors are not transient
- ❌ Don't tell user to "restart Claude Desktop" as the first action — that only helps if TCC was just granted (Step 4 of troubleshoot-tcc), not as a generic fix
- ❌ Don't drift into code investigation (re-reading EventKitManager.swift, etc.) until TCC state is ruled out

## When this rule does NOT apply

- Errors that aren't TCC-flavored: `calendarNotFound`, `invalidTimeRange`, `weekdayMismatch`, etc. — those are real validation / lookup issues, debug per usual.
- Build / compile errors — not a runtime TCC issue.
- Errors from non-EventKit tools.

## Reference

- `troubleshoot-tcc` skill — full 4-step diagnostic walkthrough
- `/check-tcc` — quick state read
- `mcpb/README.md` (v1.8.1+) — user-facing setup guide
- Issue #108 (closed) — full RCA + falsified cdhash hypothesis + corrected cache anti-pattern
- Apple TN3153 — per-call `authorizationStatus(for:)` recommended pattern
