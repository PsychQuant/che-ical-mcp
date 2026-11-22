## Problem

A `create_event` retry with `excluded_occurrence_dates` that matches an existing series answers `skipped` when every excluded date is already absent (#182). Once the series' first occurrence was edited on its own, the same retry answered the conflict error instead, naming an excluded date on which the series has no occurrence, and gave the edited occurrence's identifier as the existing series' (#544; iCloud, 2026-11-13 on the #532 branch, and 2026-11-23 on `main` `65722b27`).

## Root Cause

The duplicate lookup (`findDuplicateEvent`, title and start) returns the edited first occurrence: same title and start, an identifier of its own (`<series id>/RID=` and digits), no recurrence rules of its own. The exclusion check ran against it, so the guard for a non-recurring match (#182 verify finding 8) threw the conflict with the first excluded date, and the presence loop would have looked dates up under the occurrence's identifier.

## Proposed Solution

- A pure `ExclusionRetryTarget.resolve` chooses what the check runs against: the match when it has rules (as before); for a match that addresses one occurrence (`DetachedOccurrenceSpan.addressesOneOccurrence`), the series object named before `/RID=` (`storedEvent`, no refresh) when it has rules; otherwise the conflict for a one-off match (as before) or a new error saying the series could not be read and the dates were not checked.
- `createEvent` runs the presence loop and both conflicts with the series' identifier and zone, and a skipped retry carries the series' identifier, which `create_event` (`id`) and `create_events_batch` (`event_id`) answer.

## Non-Goals

- #578: the skipped `id` of a retry without exclusions, and a retry whose first occurrence was retitled (the lookup misses and a second series is created).
- Which occurrence of the series matched: the heuristic reads title and start, so any occurrence of a series at the requested start selects that series, as an unedited one does on `main`.

## Success Criteria

- Pure tests of every branch of `resolve` and of the new text; pins that `createEvent` resolves before the presence loop and checks the series; handler tests of the skipped identifier.
- Device (iCloud, `--cli`, Developer ID signed release build, a `#544` calendar): after the first occurrence was edited, the retry answers `skipped` with the series' identifier; an unedited present date conflicts naming it and the series; an edited occurrence on an excluded date gives the #534 text naming the series; the batch row is skipped with the series' identifier. `main` answers the false conflict in each.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `recurrence-excluded-dates`: the idempotent retry checks the series of a matched edited occurrence.

## Impact

- Affected specs: `recurrence-excluded-dates`
- Affected code: `Sources/CheICalMCP/EventKit/ExclusionRetryTarget.swift` (new), `Sources/CheICalMCP/EventKit/EventKitManager.swift` (`createEvent`, `CreateEventResult`, `EventKitError`), `Sources/CheICalMCP/EventWriteSource.swift`, `Sources/CheICalMCP/Server.swift`, tests, `CHANGELOG.md`, README files
