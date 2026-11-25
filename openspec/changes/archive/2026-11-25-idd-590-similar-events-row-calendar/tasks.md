## 1. Search scope

- [x] 1.1 `findSimilarEvents(title:calendarIdentifier:excluding:limit:)` queries `calendars: [calendar]` and chooses through the pure `SimilarEvents.select`, which leaves out `excluding` (the rows' own and answered identifiers) before the one-per-title rule and the limit (verify round 1); `EventWriteValue` carries the saved event's calendar identifier; `handleCreateEventsBatch` searches each distinct (title, calendar) of the created and skipped rows. Verify: `BatchSimilarEventsHandlerTests` with a counting fake (red first), marker `spec-example: batch-similar-events / what is searched`. (Red first: the four handler tests failed on a stub that kept the per-title search.)
- [x] 1.2 Guards: `NoUnrequestedAllCalendarQueryWiringTests` (no `calendars:` argument written as `nil`, `.none`, `Optional.none` or `[]`, and no `predicateForReminders(in: nil`, in the code of `Sources/`, widened in verify round 1; `findSimilarEvents` passes `[calendar]`; `enumerateDayWindow` named exactly three times in `EventKitManager.swift`, #591). (Added: the adapter pin for the saved calendar and the forwarded identifier, after two mutants survived without it.)

## 2. Texts

- [x] 2.1 `create_events_batch` description and manifest summary (pinned), both READMEs, `CHANGELOG.md` `[Unreleased]`.

## 3. Checks

- [x] 3.1 Full suite in three zones, removed-test check, mutation table. No device cells (the old binary reads every calendar on this path). (Round 0: 3561 tests, 9 mutants. Round 1: 3567 tests, 0 failures in each zone; no test removed; 11 more mutants; all red.)
