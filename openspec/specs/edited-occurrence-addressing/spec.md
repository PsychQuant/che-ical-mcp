# edited-occurrence-addressing Specification

## Purpose

What `update_event`, `delete_event` and `move_events_batch` answer when a recurring series' identifier and a day name an occurrence that was edited on its own, which has an identifier of its own and is no longer reached through the series' identifier. The answer gives that identifier and writes nothing, so a caller is not told that a visible occurrence does not exist.

## Requirements

### Requirement: Series identifier and day do not address an edited occurrence

The occurrence lookup by a series' identifier and a day SHALL stay as it is: it resolves the occurrence that starts on that day and is still addressed by the series' identifier. When that lookup resolves nothing in `update_event` or `delete_event` (span `this` or `future` with `occurrence_date`) or in `move_events_batch` (span `this` with an occurrence date), the call SHALL look for occurrences of that series that were edited on their own and belong to the requested day. An occurrence belongs to the day when it starts on that day, or when the slot the series' rule gave it is on that day and it now starts on another day. An edited occurrence whose identifier equals the series' identifier SHALL NOT be reported, because the identifier would not address it.

The search SHALL read two things. From the events of the requested day it SHALL take an event only when its identifier is the series' identifier followed by `/RID=` and it starts on that day. From one listing of the series' calendar over the requested day and 366 days on each side it SHALL take an occurrence tied to the series by either identifier that was edited on its own, when it starts on the requested day or its slot is on it. The listing SHALL be made over that range, not from the series' first start, so the age of the series does not matter. An occurrence that was moved more than 366 days away from the requested day is not found, and the answer is not found.

For a timed series with no time zone the search SHALL NOT read a slot: the `/RID=` of such a series is its wall time read as UTC (#539), not the instant of the slot. Such a series SHALL be matched only by the day an occurrence starts on; no occurrence SHALL be matched by its original day, and no original date SHALL be printed. The time zone the series has SHALL reach the search as it is, with no default put in its place. A series that has a time zone now but had none when an occurrence was edited is read as a zoned series; that case is not told apart (#539).

When exactly one such occurrence is found, the call SHALL be refused, SHALL write nothing, and the refusal SHALL give that occurrence's identifier, the one `list_events` shows. With span `this` the refusal SHALL say to pass that identifier as `event_id` and to leave `occurrence_date` out. For an occurrence that now starts on another day, the refusal SHALL also give its start. The refusal of `delete_event` SHALL end by saying that nothing was deleted, the others that nothing was written or moved.

The search SHALL run only after the lookup resolved nothing, and before anything is assigned, saved or removed. Whether the series is all-day is read from the object the identifier resolved to; when that object is a later occurrence standing in for a series whose first occurrence was deleted, and that occurrence was edited to another all-day state, the slots are read wrongly (not measured).

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

#### Scenario: A timed series with no time zone is matched by start only

- **GIVEN** a weekly series with no time zone at 20:00 wall time on Thursdays, whose occurrence of one Thursday was moved to the Saturday after it, on a host in `Asia/Taipei`
- **WHEN** the series' identifier is passed with the Friday between them, a day with no occurrence
- **THEN** the answer is not found, and no occurrence of another day is named

##### Example: Floating series by start only

- **GIVEN** series `S` with no time zone, host `Asia/Taipei`, and `S/RID=819835200` (2026-12-24T20:00:00Z, the wall time of the Thursday slot read as UTC) that now starts at 2026-12-26T20:00:00+08:00
- **WHEN** the edited occurrences are collected for Friday 2026-12-25, for Thursday 2026-12-24 and for Saturday 2026-12-26
- **THEN** none comes back for Friday and none for Thursday; for Saturday one comes back as "shown that day" with no original day, and no text built for it holds an original date

#### Scenario: An old series is listed around the requested day

- **GIVEN** a weekly series that started more than six years before the requested day, whose occurrence of that day was moved two days later
- **WHEN** the series' identifier is passed with the original day
- **THEN** the refusal names that occurrence

##### Example: Listing around the requested day

- **GIVEN** the requested instant 2026-12-20T16:00:00Z read in `Asia/Taipei` (the day 2026-12-21)
- **WHEN** the range of the series listing is computed
- **THEN** it runs from 366 days before the start of that day's window to 366 days after its end, whatever the series' first start is; a listing that does not hold the moved occurrence gives no match

---
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

---
### Requirement: Span future refusals say what the identifier takes

For `update_event` with span `future`, the refusal SHALL give the occurrence's identifier, SHALL NOT say that a span `future` call through that identifier takes the fields of the refused call, and SHALL name the other way with the route the refusal for span `future` through an occurrence's own identifier uses, followed by that refusal's ending (if that identifier is refused, the shape has no tested way) and its sentence on the fields that way leaves out, all read from the same constants so the texts cannot differ. For `delete_event` with span `future`, the refusal SHALL say that the delete through that identifier starts at the occurrence's original date, give that date when it is read, and say that this delete cannot be undone. The span of the call SHALL reach the text builder at each caller that takes both spans.

A span `future` call through the identifier of an occurrence that was moved later starts at that occurrence's original date (measured on iCloud for a delete and for an update of the title). When the occurrence found starts on the requested day and its original date is earlier, the delete refusal SHALL say that the occurrences of the series from the original date up to the requested day are deleted too, and the update refusal SHALL say that the write starts at the original date and not at the requested day, and that a title written that way reached the occurrences of the series from that date on, as measured. With one occurrence found, the update refusal SHALL say nothing of where the write starts in any other case. With several listed, the update refusal SHALL say that a call through one of those identifiers starts at that occurrence's original date and not at the day it starts now (measured on iCloud with a title, for an occurrence moved later and for one moved earlier), and the delete refusal SHALL say that for one that was moved later the occurrences from its original date up to the day it starts now are deleted too; for a series with no time zone the update refusal SHALL say nothing of where the write starts. When the original date is not read (a timed series with no time zone, or an occurrence with no slot), the delete text SHALL still say that the cut is at the original date and SHALL give no date; for a series with no time zone it SHALL say that this server does not read that date, and that occurrences from it up to the requested day are deleted too if it is earlier.

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

##### Example: Moved later with span future

- **GIVEN** the match `S/RID=819511200` (original date 2026-12-21) that now starts at 2026-12-29T10:00:00+08:00, requested by 2026-12-29 in `Asia/Taipei`
- **WHEN** the span `future` texts are built
- **THEN** the delete text holds `so the occurrences of the series from 2026-12-21 up to 2026-12-29 are deleted too`, and the update text holds `It starts at that occurrence's original date, 2026-12-21, not at 2026-12-29: a title written that way reached the occurrences of the series from 2026-12-21 on (measured on iCloud).`

---
### Requirement: Move row names event_ids and the start day

For a `move_events_batch` row, the refusal SHALL be that row's `error`, SHALL say to pass the occurrence's identifier in `event_ids` with its `occurrence_dates` entry set to the day the occurrence starts, and SHALL NOT name `event_id`, a parameter the tool does not have. That day SHALL be printed in the edited occurrence's own time zone (this Mac's zone for an all-day occurrence or one with no zone), the zone in which the call through that identifier reads the entry (measured on iCloud: the day in the series' zone was answered with no occurrence, the day in the occurrence's zone moved it), and the text SHALL say so when that day differs from the day in the series' zone. The original date in the delete text is not an argument and SHALL stay in the series' zone. The other rows of the call SHALL go on.

#### Scenario: A row with an edited occurrence fails alone

- **GIVEN** a call with two rows, the first naming a series' identifier and the day of an occurrence edited on its own
- **WHEN** the call runs
- **THEN** the first row reports `success: false` with the refusal as its error, and the second row is moved

##### Example: Move row

- **GIVEN** the match `S/RID=819511200` that now starts at 2026-12-23T08:00:00+08:00 in `Asia/Taipei`, requested by 2026-12-21
- **WHEN** the row text is built
- **THEN** it holds `pass it in event_ids, with its occurrence_dates entry set to 2026-12-23, the day it starts now.` and ends with `Nothing was moved.`

##### Example: Own zone day in the move row

- **GIVEN** series `S` in `Asia/Taipei`, and `S/RID=819511200` that starts at 2026-12-21T08:00:00+08:00 and has the zone `America/Los_Angeles` of its own (2026-12-20 there)
- **WHEN** the row text is built for the requested day 2026-12-21
- **THEN** it holds `with its occurrence_dates entry set to 2026-12-20, the day it starts (the day in that occurrence's own time zone).`

---
### Requirement: Identifier echoed only in a known shape

A refusal SHALL echo an identifier read from the store only when it is exactly the series' identifier the lookup used, followed by `/RID=` and one or more ASCII digits, every character of it is an ASCII letter, an ASCII digit, or one of `:` `/` `=` `-` `.` `_` and the at sign, and it is at most 200 characters long. Otherwise the text SHALL give no identifier and SHALL say to use the id `list_events` shows for the occurrence. This holds for an occurrence found through the series listing under an identifier that does not start with the series' identifier. The text SHALL NOT hold the event's title, its calendar's name or its account.

#### Scenario: An identifier with other characters is not echoed

- **GIVEN** an edited occurrence whose identifier holds a character outside the allowed list
- **WHEN** the refusal is built
- **THEN** the identifier is not in the text, and the text points to `list_events`

##### Example: Identifier outside the allowed characters

For the series identifier `6F2A:9B1C`:

| Identifier | Echoed |
| ---------- | ------ |
| `6F2A:9B1C/RID=819511200` | yes |
| `OTHER-1` (found through the listing) | no |
| `6F2A:9B1C/RID=81951x` | no |
| `6F2A:9B1C/RID=1/RID=2` | no |
| `6F2A:9B1C/RID=` | no |
| the series identifier with a space in it, followed by `/RID=1` | no |
| one of 201 characters | no |

---
### Requirement: Not-found answer prints the local day

When no edited occurrence is found for the requested day, `update_event` and `delete_event` SHALL answer `Event not found: <identifier> (no occurrence on <day>)`, where `<identifier>` is the one the caller passed and `<day>` is the requested day as `yyyy-MM-dd` in the zone the day was read in: the event's zone, or the host's when the event has none. The day SHALL NOT be printed as a UTC instant. The same answer SHALL be given, and no identifier SHALL be named that was not read, in the cases the search does not reach: the series cannot be listed and the occurrence does not start on the requested day; the occurrence was moved more than 366 days away from the requested day; the series is timed and has no time zone and the occurrence was moved off the requested day.

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

---
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
