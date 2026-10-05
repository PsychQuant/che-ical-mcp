# recurrence-excluded-dates Specification

## Purpose

TBD - created by archiving change 'add-recurrence-excluded-dates'. Update Purpose after archive.

## Requirements

### Requirement: Field validity and caller gating

`excluded_occurrence_dates` SHALL be accepted only inside a `recurrence` object on `create_event` and `create_events_batch` items. The shared recurrence parser SHALL reject the field with an explicit, named error when it appears in `update_event` or `create_reminder` input; it MUST NOT be silently ignored.

#### Scenario: Field without recurrence rule is rejected

- **GIVEN** a `create_event` call whose `recurrence` object is absent
- **WHEN** `excluded_occurrence_dates` appears anywhere in the input
- **THEN** the call fails validation before any store mutation

#### Scenario: Unsupported caller is rejected explicitly

- **GIVEN** an `update_event` or `create_reminder` call whose `recurrence` object contains `excluded_occurrence_dates`
- **WHEN** the input is parsed
- **THEN** the call fails with an error naming the field as unsupported for that tool, and no mutation occurs

---
### Requirement: Pre-save validation with zero mutation

Before the master event is saved, the server SHALL validate: (a) the field is an array of strings, reporting the index of any offending element; (b) values normalize to distinct calendar days in the event timezone — duplicates SHALL be rejected; (c) each date falls within the coarse bounds of the recurrence window (`end_date` / `occurrence_count` when derivable); (d) the array length does not exceed 100. Any pre-save validation failure SHALL leave the store unmodified.

#### Scenario: Duplicate exclusion dates are rejected before mutation

- **GIVEN** `excluded_occurrence_dates` containing `"2026-09-07"` twice (or two values normalizing to the same day)
- **WHEN** the call is validated
- **THEN** it fails with a duplicate-date error and no event is created

#### Scenario: Date-only values use the event timezone

- **GIVEN** an event created with `timezone: "America/Toronto"` and a date-only exclusion `"2026-09-07"`
- **WHEN** the exclusion is resolved
- **THEN** the excluded calendar day is 2026-09-07 in America/Toronto, matching the day-boundary semantics of the existing `occurrence_date` grammar

---
### Requirement: Two-pass post-save execution with compensating delete

After saving the master event, the implementation SHALL first resolve every excluded date to an occurrence of the saved series (pass 1) and only then remove the resolved occurrences (pass 2). If any date fails to resolve in pass 1, the implementation SHALL delete the entire just-created series before any occurrence has been removed and report which date failed. If a removal fails in pass 2, the implementation SHALL attempt the same compensating delete; if the compensating delete itself fails, the error SHALL include the master event ID and the list of exclusions already applied.

#### Scenario: Non-matching exclusion rolls back cleanly

- **GIVEN** a daily series 2026-09-01 to 2026-09-30 and an exclusion `"2026-10-15"` that passes coarse pre-validation bounds but resolves to no occurrence
- **WHEN** pass 1 runs
- **THEN** the new series is deleted, no occurrence was removed, and the error names `2026-10-15` as non-matching

#### Scenario: Rollback failure is reported, never silent

- **GIVEN** a pass-2 removal failure followed by a compensating-delete failure
- **WHEN** the operation reports its result
- **THEN** the error includes the master event ID and the already-applied exclusion list

---
### Requirement: Undo consistency

The `.createEvent` undo entry SHALL be recorded only after the exclusion pass completes successfully, so that a single `undo` invocation removes the entire series including its exclusions. The compensating-delete path SHALL record no undo entry. Calls without exclusions SHALL retain their existing undo behavior unchanged.

#### Scenario: One undo removes series created with exclusions

- **GIVEN** a series created with 2 exclusions
- **WHEN** `undo` is invoked once
- **THEN** the whole series is removed and the undo stack holds no residual entries from the exclusion operation

#### Scenario: Excluded dates do not block the undo; edited occurrences do

- **GIVEN** a series created with exclusions, whose excluded dates read back as removed occurrences and not as edited (detached) ones (checked on iCloud, 2026-10-05)
- **WHEN** `undo` is invoked and no occurrence was edited on its own since
- **THEN** the series is removed; had an occurrence been edited on its own, the undo would refuse and keep the record (#236)

---
### Requirement: Idempotent retry and conflict detection

When the existing duplicate heuristic (±30 s start + title match) detects an existing series and the request carries exclusions, the implementation SHALL check each requested excluded date against the existing series: if every requested date is already absent, the result is `skipped` (idempotent retry); if any requested date still resolves to an occurrence, the call SHALL fail with a conflict error that includes the existing event ID. Detection of extra exclusions present in the existing series but not in the request is out of scope and SHALL be documented as a limitation.

#### Scenario: Identical retry is idempotent

- **GIVEN** a series already created with exclusions `["2026-09-07", "2026-09-14"]`
- **WHEN** the identical request is submitted again
- **THEN** the response reports `skipped` and no mutation occurs

#### Scenario: Differing exclusion set conflicts

- **GIVEN** the same existing series
- **WHEN** a request with exclusions `["2026-09-21"]` (still present as an occurrence) matches the duplicate heuristic
- **THEN** the call fails with a conflict error naming the existing event ID

---
### Requirement: Response contract

A successful create SHALL include `excluded_occurrence_dates` (normalized `yyyy-MM-dd` strings in the event timezone) and `exclusion_count`. `create_events_batch` SHALL report the same fields per successful recurring item, and SHALL convert an exclusion failure (including compensating-delete outcome) into that item's `{"success": false, "error": …}` entry without aborting other items — the all-or-nothing boundary is a single series, not the whole batch.

#### Scenario: Batch reports exclusions deterministically per item

- **GIVEN** a batch with one recurring item carrying 2 valid exclusions and one item whose exclusion fails to resolve
- **WHEN** the batch completes
- **THEN** the first item's entry includes `exclusion_count: 2`, the second item's entry is `success: false` with the rollback outcome, and remaining items are unaffected
