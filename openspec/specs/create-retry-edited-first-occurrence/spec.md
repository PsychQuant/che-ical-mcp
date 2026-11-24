# create-retry-edited-first-occurrence Specification

## Purpose

What a recurring `create_event` retry answers when the series' first occurrence was edited on its own: the series' identifier for one edited in place, and a refusal for one retitled in place (#578).

## Requirements

### Requirement: Recurring retry over the series' edited first occurrence

When `create_event`, or a `create_events_batch` item, carries a recurrence rule and no exclusion check runs (no `excluded_occurrence_dates`, or an empty list), and the duplicate heuristic (title, the 30-second window around the requested start, the calendar, timed or all-day) matches an event, the `skipped` answer SHALL give as `id` (`event_id` for a batch item) the identifier of the series named before the match's `/RID=` when the target rule of the requirement "Idempotent retry and conflict detection" (capability `recurrence-excluded-dates`) takes that series: the match is its first occurrence edited in place, and the series object reads with rules, the requested title and its first slot at the requested start. Otherwise the answer SHALL keep the matched event's identifier. A request without a recurrence rule SHALL keep the matched event's identifier in every case. A series lookup that raises SHALL be read as not taking the series, so the answer is the matched event's identifier. Nothing SHALL be written. This answer does not compare the series' kind with the request's: a timed series whose first occurrence at 00:00 was turned all-day on its own (same title), retried by an all-day recurring request at that 00:00 without exclusions, answers `skipped` with the timed series' identifier, as the exclusion path of `recurrence-excluded-dates` does for that shape; nothing is written. Changing that is not part of this requirement.

#### Scenario: Recurring retry over the first occurrence edited in place

- **GIVEN** a weekly series `S` whose first occurrence's notes were edited on its own (its identifier `S/RID=818301600`)
- **WHEN** the same recurring request is submitted again without exclusions
- **THEN** the response reports `skipped` with `id` `S`, where it reported `S/RID=818301600`, and a one-off request with the same title and start still reports `S/RID=818301600`

---
### Requirement: Recurring retry over a retitled first occurrence

When `create_event`, or a `create_events_batch` item, carries a recurrence rule and the duplicate heuristic matches nothing, the server SHALL read the same window again, and when an event of the same kind (timed or all-day) in it is taken by that target rule for a series with the requested title and of the request's kind (the series object timed for a timed request, all-day for an all-day one), with the requested title compared to the series object and not to the event, the call SHALL fail with an error of its own that says the series has this title and its first occurrence at this start, that the first occurrence was edited on its own and now has another title, and that this server cannot tell whether the request is a retry of that series, naming both identifiers only in the shape the edited-occurrence refusals echo, and writing nothing. Otherwise the event SHALL be created as before. The second read SHALL NOT run for a request without a recurrence rule or after the heuristic matched. A series lookup that raises SHALL be read as not taking the series.

#### Scenario: Recurring retry over a retitled first occurrence

- **GIVEN** a weekly series `S` titled `T` whose first occurrence was retitled on its own in place to `U`
- **WHEN** a recurring request titled `T` with `S`'s first start is submitted, with or without exclusions
- **THEN** the call fails with the refusal naming `S` and `S/RID=818301600`, and no series is created, where a second series was created

##### Example: retitled first occurrence

| Window event | Series object read | Request | Answer |
|---|---|---|---|
| `S/RID=818301600` titled `U`, starts at the requested start | `S`, rules, title `T`, first slot at the start | recurring, `T` | the refusal |
| the same | the same | one-off, `T` | created (the second read does not run) |
| the same | `S`, title `Other` | recurring, `T` | created |
| `S/RID=818128800` (two days earlier), moved to the requested start | `S`, title `T` | recurring, `T` | created |
| the same as the first row, all-day | timed series | recurring, timed `T` | created (the event is not of the request's kind) |
| the same as the first row, all-day | `S` timed, rules, title `T`, first slot at the start | recurring, all-day `T` | created (the series is not of the request's kind) |
