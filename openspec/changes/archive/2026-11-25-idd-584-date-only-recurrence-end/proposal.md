## Problem

A date-only `recurrence.end_date` (`YYYY-MM-DD`) is stored as 00:00 of that day, so an occurrence later on the end day is not in the series (PsychQuant/che-ical-mcp#584). A caller who writes "end on 12-14" loses the 12-14 occurrence with no note. `update_event` documents this (PR #439); the other tools do not say.

## Root Cause

`parseRecurrenceRule` reads `end_date` with `parseFlexibleDate`, whose date-only case gives 00:00:00 of the day, and the rule stores it as a fixed instant (`EKRecurrenceEnd(end:)`).

## Proposed Solution

After the same parse (same refusals, including #546's strict reading on a skipped midnight), a date-only value becomes the last instant of that day in the zone it was read in: the first instant of the next day minus one second. A date-time value is unchanged. This applies to `create_event`, `create_events_batch`, `update_event`, `create_reminder` and `update_reminder`, which share the parser. Decided by the maintainer on #584 (Decision comment 7156253185). On `update_event` without `timezone` the day is read in the event's stored zone (PR #596 verify round 1).

## Non-Goals

Rules already stored are not rewritten. The zone a reminder's end date is read in stays the host's.

## Impact

- Affected specs: new capability `recurrence-end-date`.
- Affected code: `FlexibleDate.swift`, `Server.swift` (`parseRecurrenceRule`, the `end_date` descriptions), `EventKitManager.swift` (the PR #439 refusal text).
