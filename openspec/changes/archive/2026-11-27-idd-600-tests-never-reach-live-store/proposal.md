## Problem

Test files build `CheICalMCPServer` with some or all sources at their default, `EventKitManager.shared`, and most pass no `undoManager:`, so they share `CalendarUndoManager.shared`. Where the test process has Calendar and Reminders access, a handler that reaches a defaulted source reads or writes the developer's real stores, and one test's undo records can reach another test's live undo (PsychQuant/che-ical-mcp#600). The #575 text pins see only some spellings.

## Root Cause

Nothing stops a test from reaching the live manager or the shared history; isolation depends on each test injecting the right doubles.

## Proposed Solution

- A DEBUG-only `LiveStoreGuard`, active when XCTest is loaded in the process: each use of `EventKitManager.shared`, `CalendarUndoManager.shared`, `LiveAuthorizationStatusSource` and `SetupRunner.requestBoth` stops the process with the call stack, unless the test opted in with `LiveStoreGuard.allowingLiveStore`. Release builds carry an empty check.
- The server reads its `eventKitManager` on use, so building a server does not reach the live manager; `forTesting(probe:)` managers get an undo history of their own.
- `TestServer.make`: the init's parameters, every one left out given a `DispatchProbe` or a fresh `CalendarUndoManager()`. Every test that builds a server goes through it.

## Non-Goals

`EventKitManager.forTesting`'s real store and the EventKit read paths with no access gate in their own file (follow-up). Binaries a test spawns (XCTest is not loaded there).

## Impact

- Affected specs: `test-store-isolation`.
- Affected code: `Tests/`; DEBUG-only code in `Sources/CheICalMCP/EventKit/LiveStoreGuard.swift`, the two `shared` accessors, `LiveAuthorizationStatusSource.init`, `SetupRunner.requestBoth`, `Server.eventKitManager`, `EventKitManager.forTesting`.
