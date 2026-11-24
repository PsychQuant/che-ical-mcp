## Problem

The #503 deleted-occurrence check expands a series' rule up to `maxSlots` (20,000) slots and answers unknown (`tooManySlots`) when a 20,001st slot is in range (#506). A rule counted at exactly 20,001 slots stopped at its count before the cap was looked at and returned all 20,001 slots, while an open rule and a count of 20,002 reaching the same slot answered too many (#576).

## Root Cause

In `DeletedOccurrenceCheck.expand`, `take(_:)` ran the count's end (`slots.count >= occurrenceCount`) before the cap (`slots.count > maxSlots`).

## Proposed Solution

Check the cap before the count's end. Counts of 19,999 and 20,000 expand as before; a count of 20,001 or more, and an open rule, reaching a 20,001st slot in range answer too many.

## Non-Goals

- The #539 forecast's own guard (`slots.count <= maxSlots`, PR #558) stays; it is redundant after this change.
- The value of the cap.

## Success Criteria

- Pure tests: counts 19,999 and 20,000 expand; 20,001, 20,002 and an open rule give `tooMany`; a count of 20,001 cut at 20,000 slots expands; the verdict over a count of 20,001 fully listed answers `unknown(tooManySlots)` and over 20,000 answers `none`. Red on `main`, green after.

## Capabilities

### New Capabilities

- `deleted-occurrence-check`: the expansion cap of the #503 check.

### Modified Capabilities

(none)

## Impact

- Affected specs: `deleted-occurrence-check` (new)
- Affected code: `Sources/CheICalMCP/EventKit/DeletedOccurrenceCheck.swift`, `Tests/CheICalMCPTests/DeletedOccurrenceHorizonTests.swift`, `CHANGELOG.md`
