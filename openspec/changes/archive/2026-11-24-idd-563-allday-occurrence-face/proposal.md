## Problem

The create-undo of a series refuses with `modified_occurrences` when an occurrence edited on its own differs from the series (#236). The scan compares the occurrence's start with the `/RID=` digits read as an instant. For an occurrence edited on its own while its series was all-day the digits are a floating date (the day at 00:00 read as UTC, iCloud, 2026-10-14), and its start is midnight of that day in this Mac's zone, so off a UTC host every such occurrence counts as moved, even when its fields are back at the series' values (PsychQuant/che-ical-mcp#563).

## Root Cause

`UndoPostState.OccurrenceFace.init(_ event:)` takes the slot from `UndoPostState.originalSlot`, and `differsFromSeries` requires `sameInstant(start, slot)`. What the digits mean depends on the series when the occurrence was first edited, which cannot be read later: digits at exactly 00:00 UTC can also be a timed slot of a series later made all-day.

## Proposed Solution

Keep `main`'s instant comparison and add one pass: when the occurrence and the series are both all-day, the slot came from `/RID=` and is exactly 00:00 UTC, the start is midnight of that UTC date in the host zone, and the instant's day in the host zone is that same date (the two readings name one day), the occurrence is on its slot. This holds on hosts at or east of UTC; west of UTC the readings name different days and the occurrence still counts.

## Non-Goals

Hosts west of UTC (the issue's "on any host") stay as on `main`; nothing readable tells the two encodings apart. The conversions tracked in #564 and #570 are not addressed. An all-day occurrence with an explicit time zone is not excluded: it goes through the same check and passes only if its start is the host zone's midnight of that date, which was not measured.

## Impact

- Affected specs: new capability `create-undo-edited-occurrences`.
- Affected code: `Sources/CheICalMCP/EventKit/UndoPostStateGuard.swift` (`OccurrenceFace`, `differsFromSeries`).
