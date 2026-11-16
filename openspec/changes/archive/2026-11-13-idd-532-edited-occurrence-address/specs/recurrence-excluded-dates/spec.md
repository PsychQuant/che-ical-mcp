## MODIFIED Requirements

### Requirement: Idempotent retry and conflict detection

When the existing duplicate heuristic (±30 s start + title match + the same kind, timed or all-day, #364) detects an existing series and the request carries exclusions, the implementation SHALL check each requested excluded date against the existing series: if every requested date is already absent, the result is `skipped` (idempotent retry); if any requested date still resolves to an occurrence, the call SHALL fail with a conflict error that includes the existing event ID. Detection of extra exclusions present in the existing series but not in the request is out of scope and SHALL be documented as a limitation.

A requested date SHALL count as still present when the occurrence lookup by the existing series' identifier resolves an occurrence on it, or when an occurrence of the existing series that was edited on its own starts on that date, whether it was edited in place or moved onto that date (#534). Such an occurrence has an identifier of its own, so the lookup by the series' identifier does not resolve it. This SHALL hold for `create_event` and for each `create_events_batch` item. Only the requested date SHALL be read for this; the series SHALL NOT be listed. An occurrence that was edited on its own and moved off a requested date is not detected: nothing of the series starts on that date, so the result stays `skipped`. This SHALL be documented as a limitation next to the one above.

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
