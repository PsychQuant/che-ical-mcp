## Purpose

What `update_event`, `delete_event` and `move_events_batch` answer when a recurring series' identifier and a day name an occurrence that was edited on its own, which has an identifier of its own and is no longer reached through the series' identifier. The answer gives that identifier and writes nothing, so a caller is not told that a visible occurrence does not exist.

## ADDED Requirements

### Requirement: Series identifier and day do not address an edited occurrence

The occurrence lookup by a series' identifier and a day SHALL stay as it is: it resolves the occurrence that starts on that day and is still addressed by the series' identifier. When that lookup resolves nothing in `update_event` or `delete_event` (span `this` or `future` with `occurrence_date`) or in `move_events_batch` (span `this` with an occurrence date), the call SHALL look for occurrences of that series that were edited on their own and belong to the requested day. An occurrence belongs to the day when it starts on that day, or when the slot the series' rule gave it is on that day and it now starts on another day. An edited occurrence whose identifier equals the series' identifier SHALL NOT be reported, because the identifier would not address it.

When exactly one such occurrence is found, the call SHALL be refused, SHALL write nothing, and the refusal SHALL give that occurrence's identifier, the one `list_events` shows. With span `this` the refusal SHALL say to pass that identifier as `event_id` and to leave `occurrence_date` out. For an occurrence that now starts on another day, the refusal SHALL also give its start. The refusal of `delete_event` SHALL end by saying that nothing was deleted, the others that nothing was written or moved.

The search SHALL run only after the lookup resolved nothing, and before anything is assigned, saved or removed.

#### Scenario: An occurrence edited in place is pointed to by its identifier

- **GIVEN** a weekly series whose occurrence of one day was edited on its own (its title changed) and still starts on that day
- **WHEN** `update_event` or `delete_event` is called with the series' identifier, span `this` and that day as `occurrence_date`
- **THEN** the call is refused, nothing is written, and the refusal gives the occurrence's own identifier and says to pass it as `event_id` without `occurrence_date`

##### Example: Edited in place

- **GIVEN** series `S`, read in `Asia/Taipei`, and an edited occurrence `S/RID=819511200` that starts at 2026-12-21T10:00:00+08:00
- **WHEN** the refusal for `update_event`, span `this`, requested day 2026-12-21 is built
- **THEN** the text names the day `2026-12-21`, holds `Its identifier is S/RID=819511200: pass it as event_id and leave occurrence_date out.` and ends with `Nothing was written.`; for `delete_event` it ends with `Nothing was deleted.`

#### Scenario: An occurrence moved to another day is found by its original day

- **GIVEN** an occurrence whose slot was on the requested day and that was moved to start two days later
- **WHEN** the series' identifier and the original day are passed with span `this`
- **THEN** the refusal gives the occurrence's identifier and its start now, and nothing is written

##### Example: Moved off the day

- **GIVEN** series `S` in `Asia/Taipei`, and `S/RID=819511200` (slot 2026-12-21T10:00:00+08:00) that now starts at 2026-12-23T08:00:00+08:00
- **WHEN** the edited occurrences for the requested day 2026-12-21 are collected
- **THEN** one match of the kind "originally that day" comes back, and the span `this` text holds `now starts at 2026-12-23T08:00:00+08:00`; the same occurrence requested by 2026-12-23 comes back as "shown that day"

#### Scenario: A plain occurrence that starts on the day is resolved as before

- **GIVEN** a day on which an occurrence still addressed by the series' identifier starts, and onto which an edited occurrence was moved as well
- **WHEN** the series' identifier and that day are passed
- **THEN** the plain occurrence is resolved and written to as before, and no refusal is built

##### Example: A plain occurrence still resolves

- **GIVEN** the source of `updateEvent`, `deleteEvent` and `moveEvent`
- **WHEN** the branch that handles the lookup is read
- **THEN** the search for edited occurrences is called only inside the branch taken when `findOccurrence` returned nothing, before the not-found throw, and `findOccurrence` still tests an event through `FutureDeletionCoverage.isRequested`

### Requirement: Several edited occurrences are all listed

When two or more occurrences of the series that were edited on their own belong to the requested day, the refusal SHALL list each of them with its identifier and its start, in the order of their starts, SHALL NOT pick one, and the call SHALL write nothing. An occurrence found both by its start and by its slot SHALL be listed once.

#### Scenario: One occurrence moved onto the day and one moved off it

- **GIVEN** an edited occurrence moved onto the requested day and the occurrence of that day moved to another day
- **WHEN** the series' identifier and that day are passed
- **THEN** the refusal lists both identifiers with their starts, and nothing is written

##### Example: Two for one day

- **GIVEN** series `S` in `Asia/Taipei`, `S/RID=818906400` (slot 2026-12-14) now starting at 2026-12-21T15:00:00+08:00, and `S/RID=819511200` (slot 2026-12-21) now starting at 2026-12-23T08:00:00+08:00
- **WHEN** the matches for 2026-12-21 are collected and the span `this` text is built
- **THEN** two matches come back in start order, and the text starts with `More than one occurrence of this series that was edited on its own belongs to 2026-12-21:` and holds both identifiers

### Requirement: Span future refusals say what the identifier takes

For `update_event` with span `future`, the refusal SHALL give the occurrence's identifier, SHALL NOT say that a span `future` call through that identifier takes the fields of the refused call, and SHALL name the other way with the sentence the refusal for span `future` through an occurrence's own identifier uses, read from the same constant so the two texts cannot differ. For `delete_event` with span `future`, the refusal SHALL say that the delete through that identifier starts at the occurrence's original date, give that date when it is known, and say that this delete cannot be undone. The span of the call SHALL reach the text builder at each caller that takes both spans.

#### Scenario: The span of the call selects the text

- **GIVEN** an edited occurrence found for the requested day
- **WHEN** the call was made with span `future`
- **THEN** the span `future` text is answered, and the span `this` instruction (pass it as `event_id` and leave `occurrence_date` out) is not in it

##### Example: Update with span future

- **GIVEN** the match `S/RID=819511200` shown on 2026-12-21 in `Asia/Taipei`
- **WHEN** the text for `update_event` with span `future` is built
- **THEN** it holds `Its identifier is S/RID=819511200. With span 'future' through that identifier a call takes only some fields, and that call answers which.` followed by `For the rest: use span 'this' on that occurrence, and ` and the shared sentence about the next occurrence that was not edited on its own, and ends with `Nothing was written.`

##### Example: Delete with span future

- **GIVEN** the same match, whose original slot is on 2026-12-21
- **WHEN** the text for `delete_event` with span `future` is built
- **THEN** it holds `delete_event with span 'future' through that identifier deletes the series from that occurrence's original date, 2026-12-21, on, where that call allows it, and that delete cannot be undone.` and ends with `Nothing was deleted.`

### Requirement: Move row names event_ids and the start day

For a `move_events_batch` row, the refusal SHALL be that row's `error`, SHALL say to pass the occurrence's identifier in `event_ids` with its `occurrence_dates` entry set to the day the occurrence starts, and SHALL NOT name `event_id`, a parameter the tool does not have. The other rows of the call SHALL go on.

#### Scenario: A row with an edited occurrence fails alone

- **GIVEN** a call with two rows, the first naming a series' identifier and the day of an occurrence edited on its own
- **WHEN** the call runs
- **THEN** the first row reports `success: false` with the refusal as its error, and the second row is moved

##### Example: Move row

- **GIVEN** the match `S/RID=819511200` that now starts at 2026-12-23T08:00:00+08:00 in `Asia/Taipei`, requested by 2026-12-21
- **WHEN** the row text is built
- **THEN** it holds `pass it in event_ids, with its occurrence_dates entry set to 2026-12-23, the day it starts now.` and ends with `Nothing was moved.`

### Requirement: Identifier echoed only in a known shape

A refusal SHALL echo an identifier read from the store only when every character of it is an ASCII letter, an ASCII digit, or one of `:` `/` `=` `-` `.` `_` and the at sign, and it is at most 200 characters long. Otherwise the text SHALL give no identifier and SHALL say to use the id `list_events` shows for the occurrence. The text SHALL NOT hold the event's title, its calendar's name or its account.

#### Scenario: An identifier with other characters is not echoed

- **GIVEN** an edited occurrence whose identifier holds a character outside the allowed list
- **WHEN** the refusal is built
- **THEN** the identifier is not in the text, and the text points to `list_events`

##### Example: Identifier outside the allowed characters

| Identifier | Echoed |
| ---------- | ------ |
| `6F2A:9B1C/RID=819511200` | yes |
| `a.b_c@example/RID=1` | yes |
| one with a space | no |
| one with a line break | no |
| one with a double quote, a backtick, an angle bracket, an ampersand or a semicolon | no |
| one with a character outside ASCII | no |
| one of 201 characters | no |

### Requirement: Not-found answer prints the local day

When no edited occurrence is found for the requested day, `update_event` and `delete_event` SHALL answer `Event not found: <identifier> (no occurrence on <day>)`, where `<identifier>` is the one the caller passed and `<day>` is the requested day as `yyyy-MM-dd` in the zone the day was read in: the event's zone, or the host's when the event has none. The day SHALL NOT be printed as a UTC instant. The same answer SHALL be given when the series cannot be listed: an occurrence whose slot was on that day and that was moved to another day is then not found, and no identifier is named that was not read.

#### Scenario: The requested day reads as the caller wrote it

- **GIVEN** a series in `Asia/Taipei` with no occurrence on 2026-12-21
- **WHEN** `update_event` or `delete_event` is called with `occurrence_date` 2026-12-21
- **THEN** the error text ends with `(no occurrence on 2026-12-21)`

##### Example: Local day in the not-found text

- **GIVEN** the requested instant 2026-12-20T16:00:00Z, which is midnight of 2026-12-21 in `Asia/Taipei`, and the identifier `S`
- **WHEN** the not-found detail is built for the zone `Asia/Taipei`
- **THEN** it is `S (no occurrence on 2026-12-21)`

##### Example: Series that cannot be listed

- **GIVEN** no event on the requested day that carries the series' identifier before `/RID=`, and no listing of the series
- **WHEN** the edited occurrences for the day are collected
- **THEN** none comes back, so the caller answers not found

### Requirement: Refusal reasons stay off stderr

The refusals of this capability SHALL be trusted error messages: their text SHALL reach the caller unchanged, and the handlers SHALL write nothing to stderr for them, so an identifier read from the store does not appear there.

#### Scenario: A refused call writes no stderr line

- **GIVEN** `update_event`, `delete_event` or a `move_events_batch` row whose write is refused with a reason of this capability
- **WHEN** the handler answers
- **THEN** the response carries the reason unchanged and nothing was written to stderr during the call

##### Example: Stderr stays empty

- **GIVEN** a write source that throws `occurrenceAddressRefused` (or `moveRefused` for a move row) with the reason `R`
- **WHEN** the tool call is answered with stderr captured
- **THEN** the answer is `Error: R` (the row's `error` is `R`), and the captured stderr is empty, while an error that is not trusted writes one line through the same capture
