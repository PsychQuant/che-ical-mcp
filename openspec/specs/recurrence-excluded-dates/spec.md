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

- **GIVEN** a series created with exclusions on iCloud, where excluded dates read back as removed occurrences and not as edited (detached) ones (checked on iCloud, 2026-10-05; other stores were not checked, and a store that returned an excluded date as a detached occurrence differing from the series would make this undo refuse with `modified_occurrences`)
- **WHEN** `undo` is invoked and no occurrence was edited on its own since
- **THEN** the series is removed; had an occurrence been edited on its own, the undo would refuse and keep the record (#236)

---
### Requirement: Idempotent retry and conflict detection

When the existing duplicate heuristic (±30 s start + title match + the same kind, timed or all-day, #364) detects an existing series and the request carries exclusions, the implementation SHALL check each requested excluded date against the existing series: if every requested date is already absent, the result is `skipped` (idempotent retry); if any requested date still resolves to an occurrence, the call SHALL fail with a conflict error that includes the existing event ID. Detection of extra exclusions present in the existing series but not in the request is out of scope and SHALL be documented as a limitation.

A requested date SHALL count as still present when the occurrence lookup by the existing series' identifier resolves an occurrence on it, or when an event that starts on that date has an identifier that is the existing series' identifier followed by `/RID=`, the identifier of an occurrence edited on its own (as on iCloud), whether it was edited in place or moved onto that date (#534). The lookup by the series' identifier does not resolve such an occurrence. This SHALL hold for `create_event` and for each `create_events_batch` item. Only the requested date SHALL be read for this; the series SHALL NOT be listed and no slot SHALL be read. The answer for that case SHALL be a conflict error of its own that names the existing event ID and the date and says that an occurrence edited on its own starts on a date the request excludes, which is true in both cases; the answer for a date the lookup resolves SHALL keep its text.

The existing series SHALL be found from the event the duplicate heuristic matched (#544). When that event addresses one occurrence (it reports itself detached, or its identifier carries `/RID=`), whether or not it reports rules of its own, the existing series SHALL be the series object named by the part of its identifier before `/RID=`, read without a refresh, and only when all of these hold: that object reads with recurrence rules; its title equals the requested title; and the matched occurrence is the series' first occurrence edited in place, that is, its original slot (read from `/RID=`, an all-day series' floating date taken on this Mac's day) and its start both equal the requested start within one second. The dates SHALL then be checked against that series' identifier, in the request's time zone or else the series' zone, and both conflict errors SHALL name that identifier. A `skipped` answer for such a match SHALL give the series' identifier as `id` (`event_id` for a `create_events_batch` item). When any of those conditions fails, or the identifier has no `/RID=` part, the call SHALL fail with an error of its own that says the excluded dates were not checked and when a retry is checked against the series of an occurrence edited on its own, naming the matched occurrence's identifier only in the shape the edited-occurrence refusals echo, and writing nothing. A lookup that raises SHALL fail the call as a failed lookup. A matched event that addresses no occurrence SHALL be the series when it has rules, and SHALL keep the conflict naming the first requested date when it has none. That a slot equal to the requested start is the series' first one SHALL NOT be read: a same-titled series with an occurrence edited in place at that start is taken, as an unedited occurrence of it there is. A first occurrence whose title was changed is not matched by the heuristic, and the retry creates a second series (#578).

Three cases are not detected, and the result stays `skipped`: an occurrence that was edited on its own and moved off a requested date (nothing of the series starts on that date); an edited occurrence whose identifier has another shape than the series' identifier followed by `/RID=` (a source that gives it an unrelated identifier; none was measured); and the extra exclusions named above. They SHALL be documented as limitations.

#### Scenario: Identical retry is idempotent

- **GIVEN** a series already created with exclusions `["2026-09-07", "2026-09-14"]`
- **WHEN** the identical request is submitted again
- **THEN** the response reports `skipped` and no mutation occurs

#### Scenario: Differing exclusion set conflicts

- **GIVEN** the same existing series
- **WHEN** a request with exclusions `["2026-09-21"]` (still present as an occurrence) matches the duplicate heuristic
- **THEN** the call fails with a conflict error naming the existing event ID

#### Scenario: An occurrence edited on its own on a requested date conflicts

- **GIVEN** an existing series whose occurrence of 2026-09-21 was edited on its own and still starts on that day
- **WHEN** a request with exclusions `["2026-09-21"]` matches the duplicate heuristic
- **THEN** the call fails with the conflict error naming the existing event ID, and does not report `skipped`

##### Example: Edited occurrence on an excluded date

- **GIVEN** existing series `S` in `Asia/Taipei`, and among the events of 2026-09-21 the occurrence `S/RID=811648800` that starts at 2026-09-21T10:00:00+08:00
- **WHEN** the check for the requested date 2026-09-21 reads that day
- **THEN** the date counts as still present

##### Example: Occurrence moved onto an excluded date

- **GIVEN** existing series `S`, and among the events of 2026-09-21 the occurrence `S/RID=811044000` (slot 2026-09-14) that now starts at 2026-09-21T15:00:00+08:00
- **WHEN** the check for the requested date 2026-09-21 reads that day
- **THEN** the date counts as still present

#### Scenario: An occurrence moved off a requested date is not detected

- **GIVEN** an existing series whose occurrence of 2026-09-21 was edited on its own and now starts on 2026-09-23
- **WHEN** a request with exclusions `["2026-09-21"]` matches the duplicate heuristic
- **THEN** the response reports `skipped` (the documented limitation)

##### Example: Occurrence moved off an excluded date

- **GIVEN** existing series `S`, and among the events of 2026-09-21 none that carries `S` before `/RID=` (the occurrence `S/RID=811648800` starts on 2026-09-23)
- **WHEN** the check for the requested date 2026-09-21 reads that day
- **THEN** the date does not count as still present

##### Example: Identifier of another shape on an excluded date

- **GIVEN** existing series `S`, and among the events of 2026-09-21 an event with the identifier `OTHER-1` whose external identifier is `UID-1/RID=811648800`, starting at 2026-09-21T10:00:00+08:00
- **WHEN** the check for the requested date 2026-09-21 reads that day
- **THEN** the date does not count as still present (the stated limitation)

##### Example: Conflict sentence for an edited occurrence

- **GIVEN** the existing event ID `S` and the date `2026-09-21`
- **WHEN** the two conflict errors are described
- **THEN** the one for an edited occurrence reads `An existing series (event ID S) matches this event, and an occurrence of it that was edited on its own starts on 2026-09-21, a date this request excludes. Not modifying the existing series; adjust it explicitly or change the request.`, and the one for a resolved occurrence keeps `still has an occurrence on 2026-09-21`

#### Scenario: A retry whose match is the series' edited first occurrence is checked against the series

- **GIVEN** an existing series `S` whose first occurrence was edited on its own (its identifier `S/RID=818301600`, no rules of its own) and whose occurrence of 2027-01-04 was deleted
- **WHEN** a request with exclusions `["2027-01-04"]` matches the duplicate heuristic
- **THEN** the response reports `skipped` with `id` `S`, and a request with exclusions `["2027-01-04", "2026-12-21"]`, whose 2026-12-21 occurrence is unedited, fails with the conflict naming `S` and 2026-12-21

##### Example: target of the check

Requested title `T`, requested start 2026-12-07 10:00 +08:00 (`/RID=818301600`).

| Matched event | Series object read | Checked against |
|---|---|---|
| `S`, rules, not detached | not read | `S` |
| `S/RID=818301600`, starts at the requested start, no rules | `S`, rules, title `T` | `S` |
| `S/RID=818301600`, starts at the requested start, reports rules | `S`, rules, title `T` | `S` |
| `S/RID=818301600`, starts at the requested start | `S`, rules, title `Other` (an occurrence retitled to `T`) | not checked |
| `S/RID=818128800` (two days earlier), moved to the requested start | `S`, rules, title `T` | not checked |
| `S/RID=818301600`, starts 20 s later | `S`, rules, title `T` | not checked |
| `S/RID=818301600` | none, or no rules | not checked |
| detached `OTHER-1` | not read | not checked |
| `ONE`, no rules, not detached | not read | the conflict naming the first requested date |

---
### Requirement: Response contract

A successful create SHALL include `excluded_occurrence_dates` (normalized `yyyy-MM-dd` strings in the event timezone) and `exclusion_count`. `create_events_batch` SHALL report the same fields per successful recurring item, and SHALL convert an exclusion failure (including compensating-delete outcome) into that item's `{"success": false, "error": …}` entry without aborting other items — the all-or-nothing boundary is a single series, not the whole batch.

#### Scenario: Batch reports exclusions deterministically per item

- **GIVEN** a batch with one recurring item carrying 2 valid exclusions and one item whose exclusion fails to resolve
- **WHEN** the batch completes
- **THEN** the first item's entry includes `exclusion_count: 2`, the second item's entry is `success: false` with the rollback outcome, and remaining items are unaffected
