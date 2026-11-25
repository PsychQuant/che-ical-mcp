## 1. End of day

- [ ] 1.1 `FlexibleDate.endOfDay(ofDateOnly:in:)`. Verify: `RecurrenceEndOfDayTests` (red first), marker `spec-example: recurrence-end-date / stored end`.
- [ ] 1.2 `parseRecurrenceRule` stores a date-only end as that end of day. Verify: `RecurrenceEndDateHandlerTests` for the five tools (red first); `EventCreateHandlerTests` Havana refusal still green.

## 2. Texts

- [ ] 2.1 The four `recurrence.end_date` descriptions, the PR #439 refusal, both READMEs, pinned phrases, `CHANGELOG.md` `[Unreleased]` BREAKING (behavior), release gate.

## 3. Checks

- [ ] 3.1 Suite in three zones, removed-test check, mutants, device cells (`--cli`, disposable calendar and list named with `#584`).
