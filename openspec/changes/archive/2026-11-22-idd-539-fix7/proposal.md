# Whole-series delete forecast, round 7

## Problem

A batch preview can misidentify a prior deletion, spend multiple store listings on a forecast that cannot run, and abstain for an open daily rule at the exact end of its delete window. The rule model and the store's actual restore listing can differ.

## Proposed Solution

- Abstain after a successful row of unknown series identity, including the first-edited-occurrence route. Preserve provider identifier suffixes up to a RID marker.
- Admit dry-run captures only when the event and capture windows permit a forecast and the planned store listings fit a 16-listing call budget.
- Defer batch anchor parsing and expansion until the call has recorded a whole-series delete and no recorded member structurally refuses undo.
- Exclude the exact window end and abstain on uncertain window and rule-end boundaries. Describe the rule model in the tools and exercise forecast-to-undo agreement on a signed build.

## Scope

This supersedes the forecast requirements of `idd-539-rid-slot-readings` and `idd-539-fix1` through `idd-539-fix6`, including fix5's withdrawn dry-run capture filter. The existing delete, preview and restore decisions remain those of main. This also qualifies the `clear_timezone` description for timed and all-day RIDs.

## Impact

- Modified capability: `undo-history-discard`.
- Delete forecast admission, identity, projection and evidence, the two delete tool descriptions and manifest summaries, the two READMEs, changelog and release gate.
