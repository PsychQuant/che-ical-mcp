## 1. Date-only parse

- [ ] 1.1 `FlexibleDate.firstInstant(ofDay:in:)` and its use in the date-only branch after the zone formatter returns nil. Verify: `SkippedMidnightDateTests` (red first), marker `spec-example: all-day-skipped-midnight / a date on the skipped-midnight day`; `FlexibleDateParsingTests` stays green (#299 refusals).

## 2. Stored all-day pair

- [ ] 2.1 `AllDayRange.storedDays(start:end:calendar:)`. Verify: `AllDayStoredDaysTests` (red first with an identity stub), marker `spec-example: all-day-skipped-midnight / a one-day event on the day reads as that day`; ordinary, long-day and far-pair cases unchanged.
- [ ] 2.2 `planUpdate` reads the stored all-day pair through it. Verify: `AllDayStoredDaysTests`, marker `spec-example: all-day-skipped-midnight / moving that event by its start keeps one day`; `AllDayRangeTests` green.
- [ ] 2.3 `formatEventDict` prints an all-day event's dates through it (`allDayZone`, default the host zone). Verify: `AllDayStoredDaysTests`, marker `spec-example: all-day-skipped-midnight / list_events gives that day`; a timed event unchanged.

## 3. Texts and device

- [ ] 3.1 `CHANGELOG.md` `[Unreleased]`, `README.md`, `README_zh-TW.md`, a release-gate section in `.claude/rules/mcp-binary-version-testing.md`. Verify: read against the code and the device rows.
- [ ] 3.2 Device cells on a Developer ID signed release build of the head, `--cli`, `TZ=America/Havana`, disposable iCloud calendars named with `#546`. Verify: rows 1 to 5 and the start-only move as in the release gate; calendars deleted by id, two counts a minute apart.
