# batch-similar-events Specification

## Purpose

What the similar-events search of `create_events_batch` reads (#590).

## Requirements

### Requirement: The similar-events search of a batch create reads only the rows' calendars

`create_events_batch` SHALL search for similar existing events only in the calendar each row was written to: the calendar of the event a created row saved, or of the existing event a skipped row matched. The search SHALL run once for each distinct pair of a row's title and that calendar, and SHALL NOT read any other calendar. A row that failed SHALL get no search. `similar_events` SHALL list only events found that way. An event a row of the batch created or matched (its own identifier or the answered one) SHALL be left out before the one-per-title rule and the limit, so it neither is listed nor takes the place of an existing event.

#### Scenario: Two rows in two calendars

- **WHEN** a batch creates "Standup" in calendar A and "Standup" in calendar B, and a third row fails because its calendar does not exist
- **THEN** the search runs once for "Standup" in A and once in B, reads no other calendar, and runs nothing for the failed row

##### Example: what is searched

| Row | Outcome | Searched |
|---|---|---|
| "Standup", calendar A | created | "Standup" in A |
| "Standup", calendar A (a second row) | created | the same pair, once |
| "Standup", calendar B | created | "Standup" in B |
| "Retro", a calendar that does not exist | failed | nothing |
