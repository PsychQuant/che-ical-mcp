## 1. Date-only parse

- [x] 1.1 `FlexibleDate.firstInstant(ofDay:in:)` and its use in the date-only branch after the zone formatter returns nil. Verify: `SkippedMidnightDateTests` (red first), marker `spec-example: all-day-skipped-midnight / a date on the skipped-midnight day`; `FlexibleDateParsingTests` stays green (#299 refusals). (Added: a day Pacific/Apia skipped whole stays refused.)

## 2. Stored all-day pair

- [x] 2.1 `AllDayRange.storedDays(start:end:calendar:)`. Verify: `AllDayStoredDaysTests` (red first with an identity stub), marker `spec-example: all-day-skipped-midnight / a one-day event on the day reads as that day`; ordinary, long-day, far-pair and no-length cases unchanged; the issue's Google shape over two days (derived) added to kill the rounded-down mutant.
- [x] 2.2 `planUpdate` reads the stored all-day pair through it. Verify: `AllDayStoredDaysTests`, marker `spec-example: all-day-skipped-midnight / moving that event by its start keeps one day`; `AllDayRangeTests` green.
- [x] 2.3 `formatEventDict` prints an all-day event's dates through it (`allDayZone`, default the host zone). Verify: `AllDayStoredDaysTests`, marker `spec-example: all-day-skipped-midnight / list_events gives that day`; a timed event unchanged.

## 3. Texts and device

- [x] 3.1 `create_event` and `list_events` descriptions in `Server.swift`, their manifest summaries (pinned in `ManifestParityTests`), `CHANGELOG.md` `[Unreleased]`, `README.md`, `README_zh-TW.md`, a release-gate section in `.claude/rules/mcp-binary-version-testing.md`. Verify: read against the code and the device rows.
- [x] 3.2 Device cells on a Developer ID signed release build of the head, `--cli`, `TZ=America/Havana`, disposable iCloud calendars named with `#546`. Verify: rows 1 to 5 and the start-only move as in the release gate; calendars deleted by identifier, with two absence checks a minute apart limited to the identifiers this lane created. (Done on the build of `57f5d642`, 2026-11-22: rows 1 to 5, the start-only and end-only moves and the ordinary controls as expected; row 6 still one day, as the release gate says.)
