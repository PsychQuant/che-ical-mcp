## 1. Slot comparison

- [x] 1.1 `UndoPostState.onItsSlot(start:slot:slotFromRID:allDay:zone:)` and `differsFromSeries(_:series:zone:)`. Verify: `AllDayOccurrenceSlotTests` (red first in all three process zones), markers `spec-example: create-undo-edited-occurrences / set back at its slot, by host zone` and `/ shapes compared as before`; a grid against `main`'s comparison. (Red first on the stub: all 9 new tests in Asia/Taipei; 8 of 9 in UTC and America/Los_Angeles, where the scan test passes on the stub, as its expectation follows the process zone and the instant comparison already gives it there.)
- [x] 1.2 `OccurrenceFace.init(_ event:)` sets `slotFromRID` from the identifiers. Verify: `AllDayOccurrenceSlotWiringTests` source pin; full suite in three zones. (Suite: 3531 tests, 0 failures in each zone.)

## 2. Texts and gate

- [x] 2.1 `CHANGELOG.md` `[Unreleased]` Fixed entry and doc comments. Verify: read against the code.
- [x] 2.2 Release-gate step in `.claude/rules/mcp-binary-version-testing.md` (session MCP, create-undo; #573 blocks a `--cli` setup).

## 3. Checks

- [x] 3.1 Removed-test check and mutation table. (No test removed against origin/main; 12 mutants, all red.)
