## Problem

`DispatchRoundTripTests` builds `CheICalMCPServer()` with every source at `EventKitManager.shared` and dispatches every declared tool with empty arguments; `list_calendars`, `cleanup_completed_reminders` and the other tools that need no argument read the developer's real Calendar and Reminders stores where the test process has access (PsychQuant/che-ical-mcp#575).

## Root Cause

The test passes no sources; the defaults are the live manager.

## Proposed Solution

A test-only probe conforming to every source protocol of the server, which records each call and throws; both dispatch tests build the server with it and a fresh undo manager, keep their properties, and also check that the probe saw the calls of the no-argument tools. A source pin keeps the server's one direct `eventKitManager` call behind a required argument.

## Non-Goals

Other test files that build the default server (#600). No `Sources/` change.

## Impact

- Affected specs: new capability `test-store-isolation`.
- Affected code: `Tests/` only.
