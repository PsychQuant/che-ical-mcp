## Problem

`update_event` through a series' id with span `all` and a new start, end or zone on a series with a rule end (or #513's month-end shape) lists the series twice over the same calendar, series and ranges: once for the #509 rule-end check's first slot, once for the #503 baseline, because the #527 stretch that shares listings opens after the #509 check (PsychQuant/che-ical-mcp#533).

## Root Cause

The #509 block calls `wholeSeriesBaseline(of: masterEvent, id: identifier, viaStandIn: resolved.viaStandIn)` before `seriesListings.sharing` opens; on that route the #503 baseline makes the same call inside the stretch.

## Proposed Solution

Open the stretch at the top of the #509 block, so the #509 first-slot read and the #503 baseline share one listing. Between them nothing awaits, writes, saves or replaces the store; the two refreshes in the longer stretch run on the own-id route only, where #509 makes no shared listing, and before the first shared listing.

## Non-Goals

`ruleEndShiftRefusal` keeps its own listing of the range around the rule end (another range). No response, refusal or write changes.

## Impact

- Affected specs: new capability `series-listing-sharing`.
- Affected code: `EventKitManager.swift` (`updateEvent`).
