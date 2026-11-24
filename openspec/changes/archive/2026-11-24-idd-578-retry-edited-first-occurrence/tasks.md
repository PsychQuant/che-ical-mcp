<!--
No [P]: every task ends in a build or a test run, and this machine runs one build at a time (the shared build lock).
-->

## 1. Decisions (pure, `CreateRetryIdentity.swift`)

- [x] 1.1 `answeredSeries(recurring:match:request:series:)`, `retitledFirstOccurrence(recurring:candidates:isAllDay:request:series:)`, `retitledReason(seriesID:occurrenceID:)` and the `createRetryRetitledFirstOccurrence` error. Verify: `CreateRetryIdentityTests`, red against stubs that return `main`'s answer.

## 2. Wiring (`EventKitManager.createEvent`)

- [x] 2.1 The retitled read after the title lookup missed, for a recurring request only, before any write; the fall-through return answers `answeredSeries`; one shared request and series read. Verify: `CreateRetryIdentityWiringTests`, the rewritten `ExclusionRetryTargetWiringTests` pins, `CreateRetryIdentityHandlerTests`; red against `main`'s `createEvent`.

## 3. Texts

- [x] 3.1 CHANGELOG `[Unreleased]`, both READMEs, both `excluded_occurrence_dates` descriptions and their pin, the gate section. Verify: content review; `ManifestParityTests`.

## 4. Proof

- [x] 4.1 Three-zone suite, removed-test check, mutants.
- [x] 4.2 Device cells (`--cli`, signed release builds, iCloud, `#578` calendars), cleanup counted twice a minute apart.
