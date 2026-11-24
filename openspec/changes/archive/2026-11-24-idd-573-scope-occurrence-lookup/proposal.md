## Problem

`findOccurrence` and `dayReadings` asked EventKit for the requested day's window in every event calendar (`calendars: nil`) and kept the series' events afterwards. Every lookup of one occurrence of a known series therefore read that day in every calendar (#573).

## Root Cause

The two helpers built their predicate with no calendar, although each caller holds an object whose calendar is the series'.

## Proposed Solution

- A pure `OccurrenceLookup` (`find`, `dayReadings`, `scope`) with the store query injected: the window and the selection are moved unchanged, and the query names `[calendar]`, or every calendar only when the calendar is unknown.
- `findOccurrence(…, calendar:)` and `dayReadings(…, calendar:)` take a calendar with no default; each caller passes the series object's calendar (the new series' for its exclusions, the duplicate lookup's calendar for a retry).
- No retry in every calendar after a miss.

## Non-Goals

- Measuring non-iCloud sources (release-gate note).
- Other event queries: every other one already names a calendar or is a listing the caller asks for.

## Success Criteria

- A fake store over two calendars records `[series calendar]` for each query, the right occurrence is found, the answer equals the query of every calendar's for occurrences in the series' calendar, and every calendar is queried only for an unknown calendar.
- Pins: each caller passes the named object's calendar; the helpers have no default calendar; no predicate of every calendar is left in them.

## Capabilities

### New Capabilities

- `occurrence-lookup`: the calendars an occurrence lookup reads.

### Modified Capabilities

(none)

## Impact

- Affected specs: `occurrence-lookup` (new)
- Affected code: `Sources/CheICalMCP/EventKit/OccurrenceLookup.swift` (new), `Sources/CheICalMCP/EventKit/EventKitManager.swift`, tests, `CHANGELOG.md`, `.claude/rules/mcp-binary-version-testing.md`
