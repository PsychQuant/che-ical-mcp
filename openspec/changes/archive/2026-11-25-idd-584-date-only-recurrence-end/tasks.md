## 1. End of day

- [x] 1.1 `FlexibleDate.endOfDay(ofDateOnly:in:)`. Verify: `RecurrenceEndOfDayTests` (red first), marker `spec-example: recurrence-end-date / stored end`. (Red first on a stub returning nil; 23- and 25-hour days added after a fixed-length mutant survived.)
- [x] 1.2 `parseRecurrenceRule` stores a date-only end as that end of day. Verify: `RecurrenceEndDateHandlerTests` for the five tools (red first); `EventCreateHandlerTests` Havana refusal still green. (Red first: the five handler tests failed on main's 00:00.)

## 2. Texts

- [x] 2.1 The four `recurrence.end_date` descriptions, the PR #439 refusal, both READMEs, pinned phrases, `CHANGELOG.md` `[Unreleased]` BREAKING (behavior), release gate.

## 3. Checks

- [x] 3.1 Suite in three zones, removed-test check, mutants, device cells (`--cli`, disposable calendar and list named with `#584`). (Device: iCloud, 2026-11-25, this change and main 37f94bd6; calendar and list deleted by id, 0 named #584 at 14:42:07 and 14:45:20 +08:00. Mutants: 8, all red after two test additions.)
