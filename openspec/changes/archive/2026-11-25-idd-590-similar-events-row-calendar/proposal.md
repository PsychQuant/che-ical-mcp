## Problem

`create_events_batch` returns `similar_events` hints from a search over every calendar's events for about two years either side of now (`findSimilarEvents`, `calendars: nil`), though each row names one calendar and the caller asked for no search (PsychQuant/che-ical-mcp#590). The response can carry titles, calendar names and dates of events in calendars the caller never named.

## Root Cause

`EventKitManager.findSimilarEvents(title:limit:)` queries `events(from:to:calendars: nil)`, and `handleCreateEventsBatch` calls it once per distinct title of the batch.

## Proposed Solution

Search only the calendar each row was written to (the saved event's calendar, for a created or a skipped row), once per distinct title and calendar; a row that failed gets no hint. Guard the rest of `Sources/` with a source pin that no literal `calendars: nil` is left, and pin the callers of `enumerateDayWindow` by count (#591).

## Non-Goals

An opt-in option naming other calendars to search (left for later; recorded on #590 as the alternative). Hints for failed rows. Callers lose hints for similar events in other calendars.

## Impact

- Affected specs: new capability `batch-similar-events`.
- Affected code: `EventKitManager.swift` (`findSimilarEvents`), `EventWriteSource.swift`, `Server.swift` (`handleCreateEventsBatch`, the description), `mcpb/manifest.json`.
