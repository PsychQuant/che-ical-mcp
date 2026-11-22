<!--
No [P]: every task ends in a build or a test run, and this machine runs one build at a time (the shared build lock).
Tests first; every new branch has a mutant seen red (PR body).
-->

## 1. Target (pure, `ExclusionRetryTarget.swift`)

- [x] 1.1 `ExclusionRetryTarget.resolve(matchID:matchIsDetached:matchHasRules:matchZone:series:)` and `seriesUnreadReason(occurrenceID:)`, with the `exclusionSeriesUnread` error. Verify: `ExclusionRetryTargetTests` (each branch, the raise passed on, the text and its echo shape).

## 2. Wiring (`EventKitManager.createEvent`, `EventWriteSource`, `Server`)

- [x] 2.1 `createEvent` resolves the target before the presence loop, reads the series through `storedEvent`, checks and names the series, and returns its identifier on the skipped retry; `create_event` and `create_events_batch` answer `answeredIdentifier`. Verify: `ExclusionRetryTargetWiringTests` and `ExclusionRetryTargetHandlerTests` red before, green after; the #534 pin rewritten to the series' identifier.

## 3. Texts

- [x] 3.1 `CHANGELOG.md` `[Unreleased]` Fixed entry with what was measured and what was not; README and README_zh-TW where the #182 retry is described. Verify: content review; `ManifestParityTests`.

## 4. Proof

- [x] 4.1 Full `swift test` in the host zone, `TZ=UTC`, `TZ=America/Los_Angeles`; removed-test check by (file, name) against `origin/main`; mutation table (one mutant per branch and text, each seen red).
- [x] 4.2 Device cells (`--cli`, signed release build of the head and of `main`, iCloud, a `#544` calendar): rows 1 to 5 of the PR body; calendar deleted by id; `probecount.py` twice a minute apart.
