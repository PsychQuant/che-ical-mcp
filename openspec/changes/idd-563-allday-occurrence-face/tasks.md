## 1. Slot comparison

- [ ] 1.1 `UndoPostState.onItsSlot(start:slot:slotFromRID:allDay:zone:)` and `differsFromSeries(_:series:zone:)`. Verify: `AllDayOccurrenceSlotTests` (red first in all three process zones), markers `spec-example: create-undo-edited-occurrences / set back at its slot, by host zone` and `/ shapes compared as before`; a grid against `main`'s comparison.
- [ ] 1.2 `OccurrenceFace.init(_ event:)` sets `slotFromRID` from the identifiers. Verify: `AllDayOccurrenceSlotWiringTests` source pin; full suite in three zones.

## 2. Texts and gate

- [ ] 2.1 `CHANGELOG.md` `[Unreleased]` Fixed entry and doc comments. Verify: read against the code.
- [ ] 2.2 Release-gate step in `.claude/rules/mcp-binary-version-testing.md` (session MCP, create-undo; #573 blocks a `--cli` setup).

## 3. Checks

- [ ] 3.1 Removed-test check and mutation table.
