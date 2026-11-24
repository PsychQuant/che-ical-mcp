## 1. Search scope

- [ ] 1.1 `findSimilarEvents(title:calendarIdentifier:limit:)` queries `calendars: [calendar]`; `EventWriteValue` carries the saved event's calendar identifier; `handleCreateEventsBatch` searches each distinct (title, calendar) of the created and skipped rows. Verify: `BatchSimilarEventsHandlerTests` with a counting fake (red first), marker `spec-example: batch-similar-events / what is searched`.
- [ ] 1.2 Guards: `NoUnrequestedAllCalendarQueryWiringTests` (no literal `calendars: nil` in `Sources/`; `findSimilarEvents` passes `[calendar]`; `enumerateDayWindow` named exactly three times in `EventKitManager.swift`, #591).

## 2. Texts

- [ ] 2.1 `create_events_batch` description and manifest summary (pinned), both READMEs, `CHANGELOG.md` `[Unreleased]`.

## 3. Checks

- [ ] 3.1 Full suite in three zones, removed-test check, mutation table. No device cells (the old binary reads every calendar on this path).
