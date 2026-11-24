<!-- No [P]: every task ends in a build or a test run under the shared build lock. -->

## 1. Tests (red)

- [x] 1.1 `testACountOfMoreThanTheCapIsTooManyLikeAnOpenRule` in `DeletedOccurrenceHorizonTests`: counts 19,999 / 20,000 / 20,001 / 20,002 and an open rule, a count of 20,001 cut at the cap, and the verdict over 20,001 and 20,000 listed slots. Verify: red on `main` (two failures: the 20,001 expansion and its verdict).

## 2. Fix

- [x] 2.1 `DeletedOccurrenceCheck.expand`: check the cap before the count's end. Verify: the test green; mutant restoring the old order seen red.

## 3. Texts

- [x] 3.1 `CHANGELOG.md` `[Unreleased]` Fixed entry. README, README_zh-TW and the `update_event` description already say more than 20,000 occurrences are refused; unchanged.

## 4. Proof

- [x] 4.1 Full `swift test` in the host zone, `TZ=UTC`, `TZ=America/Los_Angeles`; removed-test check by (file, name) against `origin/main`.
