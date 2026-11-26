## 1. Guard

- [x] 1.1 `LiveStoreGuard` (DEBUG-only, keyed on XCTest being loaded) checked on each use of `EventKitManager.shared`, `CalendarUndoManager.shared`, `LiveAuthorizationStatusSource` and `SetupRunner.requestBoth`; opt-in `allowingLiveStore`. Verify: `LiveStoreGuardTests`; mutants removing a check or the guard go red.
- [x] 1.2 `Server.eventKitManager` read on use; `forTesting(probe:)` gets a fresh undo history.

## 2. Migration

- [x] 2.1 `TestServer.make` and every server-building test moved to it; `CalendarUndoManager.shared` uses in tests replaced by fresh histories. Verify: the suite runs to the end with the guard in; a migrated file that keeps a default stops the suite (mutants).

## 3. Checks

- [x] 3.1 Suite in three zones, removed-test check, the list of tests that reached a filled-in source, CI.
