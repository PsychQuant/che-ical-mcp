## 1. Isolation

- [x] 1.1 `DispatchProbe` (test helper) conforming to every source protocol; both dispatch tests build the server with it and a fresh `CalendarUndoManager`. Verify: the tests keep their properties (no `unknownTool`; cleanup dispatched) and check the probe's calls. (Mutants T1, T3 red.)
- [x] 1.2 Source pin: one direct `eventKitManager.` call in `Server.swift`, after the `reminder_id` guard; `delete_reminder` with empty arguments throws `invalidParameter`. (Mutant T2 red.)

## 2. Checks

- [x] 2.1 Suite in three zones, removed-test check (old → new), mutants, the tests run with this host's authorization status recorded and on CI. (This host's test process: full access to events and reminders; CI: see the PR.)
