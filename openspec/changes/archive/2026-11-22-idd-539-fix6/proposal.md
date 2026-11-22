# Whole-series delete forecast

## Why

A delete forecast should preserve the existing dry-run answers and stay silent when it cannot reproduce the slots used to check the exceptions at restore.

## What Changes

- Preserve the requested identifiers in the ordinary dry run. Skip the forecast after an earlier successful row from the same series and limit additional preview captures.
- Forecast only from a proven stored anchor and a recurrence whose restore-window listings can be modelled. Reuse the delete's recorded capture.
- Document abstentions and distinguish device observations from store-level comparisons.

## Impact

The existing delete, dry run and undo outcomes remain as on main. The optional forecast, batch preview field descriptions and the clear_timezone description change.

## Non-Goals

No change to undo records, slot readers, exception restoration or ordinary preview answers. This forecast superseded `idd-539-rid-slot-readings` and `idd-539-fix1` through `idd-539-fix5`. It withdrew fix5’s dry-run capture filter. `idd-539-fix7` supersedes this forecast.
