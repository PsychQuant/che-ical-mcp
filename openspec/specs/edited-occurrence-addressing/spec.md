# edited-occurrence-addressing Specification

## Purpose

What `update_event`, `delete_event` and `move_events_batch` answer when a recurring series' identifier and a day name an occurrence that was edited on its own, which has an identifier of its own and is no longer reached through the series' identifier. The answer gives that identifier and writes nothing, so a caller is not told that a visible occurrence does not exist.

## Requirements

### Requirement: Series identifier and day do not address an edited occurrence

The occurrence lookup by a series' identifier and a day SHALL stay as it is: it resolves the occurrence that starts on that day and is still addressed by the series' identifier. When that lookup resolves nothing in `update_event` or `delete_event` (span `this` or `future` with `occurrence_date`) or in `move_events_batch` (span `this` with an occurrence date), the call SHALL look for occurrences of that series that were edited on their own and start on the requested day.

The search SHALL read only the events of the requested day's window, the window the lookup enumerates. It SHALL take an event only when its identifier is the series' identifier followed by `/RID=` (the exact series part, so a longer identifier that begins with the same characters is not taken) and it starts on the requested day: in the series' zone, in this Mac's zone for a series with no time zone, and in this Mac's zone for an all-day occurrence. Of each event the search SHALL read its identifier, its all-day state, its start and its own time zone, and nothing else: it SHALL NOT read the digits after `/RID=` as a date, an occurrence date, an external identifier or whether the event is detached, and it SHALL NOT list the series. An edited occurrence whose identifier equals the series' identifier, or has another shape (one tied to its series by the external identifier only), SHALL NOT be found; no such source was measured. On iCloud and on Google through EventKit every occurrence edited on its own has an identifier of the series' identifier followed by `/RID=` and digits, the occurrence standing in for a series whose first occurrence was deleted included.

An occurrence that was moved off the requested day SHALL NOT be found through the series' identifier and that day: the answer is not found, as before this capability, and `list_events` shows the occurrence under its own identifier.

When exactly one such occurrence is found, the call SHALL be refused, SHALL write nothing, and the refusal SHALL say that an occurrence of this series that starts on the requested day was edited on its own, so the series' identifier and that day do not address it, and SHALL give that occurrence's identifier, the one `list_events` shows. With span `this` the refusal SHALL say to pass that identifier as `event_id` and to leave `occurrence_date` out. No refusal SHALL print or imply an original date, or say that an occurrence was on the requested day: every date in it is the requested day or the start of a listed occurrence. The refusal of `delete_event` SHALL end by saying that nothing was deleted, the others that nothing was written or moved.

The search SHALL run only after the lookup resolved nothing, and before anything is assigned, saved or removed.

#### Scenario: An occurrence edited in place is pointed to by its identifier

- **GIVEN** a weekly series whose occurrence of one day was edited on its own (its title changed) and still starts on that day
- **WHEN** `update_event` or `delete_event` is called with the series' identifier, span `this` and that day as `occurrence_date`
- **THEN** the call is refused, nothing is written, and the refusal gives the occurrence's own identifier and says to pass it as `event_id` without `occurrence_date`

##### Example: Edited in place

- **GIVEN** series `S`, read in `Asia/Taipei`, and an edited occurrence `S/RID=819511200` that starts at 2026-12-21T10:00:00+08:00
- **WHEN** the refusal for `update_event`, span `this`, requested day 2026-12-21 is built
- **THEN** the text is `An occurrence of this series that starts on 2026-12-21 was edited on its own, so the series' identifier and that day do not address it. Its identifier is S/RID=819511200: pass it as event_id and leave occurrence_date out. Nothing was written.`; for `delete_event` it ends with `Nothing was deleted.`

#### Scenario: An occurrence moved to another day is found only by the day it starts on

- **GIVEN** an occurrence edited on its own that was moved to start two days after its own day
- **WHEN** the series' identifier is passed with the day it was moved off, and then with the day it starts on
- **THEN** the first answer is not found with the requested day as a date, and the second is the refusal with its identifier

##### Example: Moved off the day

- **GIVEN** series `S` in `Asia/Taipei`, and `S/RID=819511200` that now starts at 2026-12-23T08:00:00+08:00, on a host in `Asia/Taipei`, `America/Los_Angeles` or `UTC`
- **WHEN** the edited occurrences are collected for 2026-12-21 and for 2026-12-23
- **THEN** none comes back for 2026-12-21, even when the day's events held the occurrence, so `update_event`, `delete_event` and a move row answer not found (`S (no occurrence on 2026-12-21)` for the first two); one comes back for 2026-12-23

#### Scenario: A plain occurrence that starts on the day is resolved as before

- **GIVEN** a day on which an occurrence still addressed by the series' identifier starts, and onto which an edited occurrence was moved as well
- **WHEN** the series' identifier and that day are passed
- **THEN** the plain occurrence is resolved and written to as before, and no refusal is built

##### Example: A plain occurrence still resolves

- **GIVEN** the source of `updateEvent`, `deleteEvent` and `moveEvent`
- **WHEN** the branch that handles the lookup is read
- **THEN** the search for edited occurrences is called only inside the branch taken when `findOccurrence` returned nothing, before the not-found throw, and `findOccurrence` still tests an event through `FutureDeletionCoverage.isRequested`

#### Scenario: No slot is read

- **GIVEN** edited occurrences whose `/RID=` digits name another day than the one they start on: a series with no time zone (wall time read as UTC), a series that got its time zone after its occurrences were edited, an all-day series
- **WHEN** the series' identifier is passed with the day the digits name
- **THEN** the answer is not found, and no occurrence is named

##### Example: No slot is read

- **GIVEN** series `S` at Thursdays 20:00 in `Asia/Taipei` (and the same series with no time zone, on a Taipei host), the occurrence `S/RID=819230400` that starts at 2026-12-17T20:00:00+08:00 and `S/RID=820440000` that starts at 2027-01-02T20:00:00+08:00, both in the day's events
- **WHEN** the edited occurrences are collected for 2026-12-18, 2027-01-01, 2026-12-31, 2026-12-17 and 2027-01-02, on hosts in `Asia/Taipei`, `America/Los_Angeles` and `UTC`
- **THEN** none comes back for the first three days, `S/RID=819230400` alone for 2026-12-17 and `S/RID=820440000` alone for 2027-01-02; an identifier with any digits is matched by its start alone, and every text for 2027-01-02 holds no date but `2027-01-02`

##### Example: The search reads no slot

- **GIVEN** the source of `EditedOccurrenceAddress` and of the manager functions the search runs
- **WHEN** they are read with comments stripped
- **THEN** a reading is built from the event's identifier, all-day state, start and time zone only; the source holds no reading of an occurrence date, an external identifier, `isDetached` or a number from the identifier; the only code past the `/RID=` marker is the echo's check that the digits are ASCII digits; and no series listing is called

#### Scenario: A timed series with no time zone is matched by start only

- **GIVEN** a weekly series with no time zone at 20:00 wall time on Thursdays, whose occurrence of one Thursday was moved to the Saturday after it, on a host in `Asia/Taipei`
- **WHEN** the series' identifier is passed with the Friday between them, with the Thursday, and with the Saturday
- **THEN** the answer is not found for the Friday and the Thursday, and the refusal for the Saturday names that occurrence

##### Example: Floating series by start only

- **GIVEN** series `S` with no time zone, host `Asia/Taipei`, and `S/RID=819835200` (2026-12-24T20:00:00Z, the wall time of the Thursday slot read as UTC) that now starts at 2026-12-26T20:00:00+08:00
- **WHEN** the edited occurrences are collected for Friday 2026-12-25, for Thursday 2026-12-24 and for Saturday 2026-12-26
- **THEN** none comes back for Friday and none for Thursday; for Saturday one comes back, and its move row text is `An occurrence of this series that starts on 2026-12-26 was edited on its own, so the series' identifier and that day do not address it. Its identifier is S/RID=819835200: pass it in event_ids, with its occurrence_dates entry set to 2026-12-26, the day it starts. Nothing was moved.`

#### Scenario: No text prints an original date

- **GIVEN** one or two edited occurrences that start on the requested day, in a series with a zone and in one with none
- **WHEN** the text of each call is built
- **THEN** no text holds `was on that day`, `had on`, `original date is`, a date after `original date`, `now starts`, `starts now` or `no longer address`, and every date in it is the requested day

##### Example: No original date in any text

- **GIVEN** `S/RID=819511200` starting at 2026-12-21T10:00:00+08:00 and `S/RID=818906400` starting at 2026-12-21T15:00:00+08:00, requested by 2026-12-21
- **WHEN** the five texts are built for each one alone and for both
- **THEN** the only date in each is `2026-12-21`, and `2026-12-14` is in none

---
### Requirement: Several edited occurrences are all listed

When two or more occurrences of the series that were edited on their own start on the requested day, the refusal SHALL list each of them with its identifier and its start, in the order of their starts, SHALL NOT pick one, and the call SHALL write nothing. An occurrence held twice by the day's events SHALL be listed once.

#### Scenario: One occurrence edited in place and one moved onto the day

- **GIVEN** an edited occurrence that starts on the requested day and another one moved onto that day
- **WHEN** the series' identifier and that day are passed
- **THEN** the refusal lists both identifiers with their starts, and nothing is written

##### Example: Two for one day

- **GIVEN** series `S` in `Asia/Taipei`, `S/RID=819511200` starting at 2026-12-21T10:00:00+08:00 and `S/RID=818906400` starting at 2026-12-21T15:00:00+08:00
- **WHEN** the matches for 2026-12-21 are collected and the span `this` text is built
- **THEN** two matches come back in start order, and the text starts with `More than one occurrence of this series that was edited on its own starts on 2026-12-21: S/RID=819511200 (starts at 2026-12-21T10:00:00+08:00); S/RID=818906400 (starts at 2026-12-21T15:00:00+08:00).`

---
### Requirement: Span future refusals say what the identifier takes

For `update_event` with span `future`, the refusal SHALL give the occurrence's identifier, SHALL NOT say that a span `future` call through that identifier takes the fields of the refused call, and SHALL name the other way with the route the refusal for span `future` through an occurrence's own identifier uses, followed by that refusal's ending (if that identifier is refused, the shape has no tested way) and its sentence on the fields that way leaves out, all read from the same constants so the texts cannot differ. For `delete_event` with span `future`, the refusal SHALL say that the delete through that identifier starts at the occurrence's original date and that this delete cannot be undone. The span of the call SHALL reach the text builder at each caller that takes both spans.

A span `future` call through the identifier of an edited occurrence starts at that occurrence's original date, not at the day it starts on now. This server does not read that date. Every span `future` text, with one occurrence or several, SHALL say so and SHALL give both directions without a date: when that date is before the requested day, occurrences of the series before the requested day are written (deleted) too; when it is after, the occurrences between the requested day and that date are not reached. It SHALL cite what was measured, without dates: on iCloud, an update of a title and a delete through an occurrence moved later and through one moved earlier, and an update of a title through one moved later in a series with no time zone.

Every span `future` text SHALL also say, whatever the occurrence: where the store recorded that occurrence at another time of day than the series, a span `future` update through its identifier moved the later occurrences of the series to another day (#550), and the update text SHALL add that span `this` on that occurrence is the tested way; the delete text SHALL say instead what #550 measured for a delete: that occurrence and the later ones were removed, and an occurrence the rule shows on its day stayed.

In a timed series with no time zone, the delete refusal SHALL say that the delete removes the occurrences of the series after that occurrence's original date, and SHALL name the known defect #549 as one, measured on iCloud: in such a series that call answers `deleted` while the edited occurrence itself stays. That sentence SHALL NOT be in any other text or series. It, the tool description and the release-gate cell change when #549 is fixed. The update text of such a series SHALL be the one of a series with a zone.

#### Scenario: The span of the call selects the text

- **GIVEN** an edited occurrence that starts on the requested day
- **WHEN** the call was made with span `future`
- **THEN** the span `future` text is answered, and the span `this` instruction (pass it as `event_id` and leave `occurrence_date` out) is not in it

##### Example: Update with span future

- **GIVEN** the match `S/RID=819511200` that starts on 2026-12-21 in `Asia/Taipei`
- **WHEN** the text for `update_event` with span `future` is built
- **THEN** after `Its identifier is S/RID=819511200.` it holds `With span 'future' through that identifier a call takes only some fields, and that call answers which. Such a call starts at that occurrence's original date. This server does not read that date: when it is before 2026-12-21, occurrences of the series before 2026-12-21 are written too; when it is after 2026-12-21, the occurrences between 2026-12-21 and that date are not reached. Measured on iCloud with a title, through an occurrence moved later and one moved earlier, and through one moved later in a series with no time zone.`, then the sentence of #550, then `For the rest: use span 'this' on that occurrence, and ` and the shared sentence about the next occurrence that was not edited on its own, and ends with `Nothing was written.`

##### Example: Delete with span future

- **GIVEN** the same match
- **WHEN** the text for `delete_event` with span `future` is built
- **THEN** it holds `delete_event with span 'future' through that identifier, where that call allows it, deletes the series from that occurrence's original date on. This server does not read that date: when it is before 2026-12-21, occurrences of the series before 2026-12-21 are deleted too; when it is after 2026-12-21, the occurrences between 2026-12-21 and that date are not reached. Measured on iCloud, through an occurrence moved later and one moved earlier.`, then the sentence of #550 for a delete, and ends `That delete cannot be undone. Nothing was deleted.`

##### Example: Moved later with span future

- **GIVEN** `S/RID=819511200` that now starts at 2026-12-29T10:00:00+08:00, requested by 2026-12-29
- **WHEN** the span `future` texts are built
- **THEN** they are the texts above with 2026-12-29 as the requested day, and they hold no other date

##### Example: Both directions with span future

- **GIVEN** one occurrence, and two, that start on 2026-12-29, in a series with a zone and in one with none
- **WHEN** the texts of every call are built
- **THEN** the span `future` update and delete texts each hold the sentence of both directions once and `original date` once, and the span `this` texts and the move row hold neither

##### Example: The sentence of #550

- **GIVEN** one occurrence, and two, in a series with a zone and in one with none
- **WHEN** the span `future` texts are built
- **THEN** the update text holds `Where the store recorded that occurrence at another time of day than the series, a span 'future' update through its identifier moved the later occurrences of the series to another day (#550); span 'this' on that occurrence is the tested way.` once, followed by `For the rest:`, the delete text holds `Where the store recorded that occurrence at another time of day than the series, a span 'future' delete through its identifier removed that occurrence and the later ones, and an occurrence the rule shows on its day stayed (#550).` once, followed by `That delete cannot be undone.`, and no span `this` text or move row names #550

##### Example: Several with span future

- **GIVEN** the two matches of the example "Two for one day"
- **WHEN** the span `future` texts are built
- **THEN** they hold the same sentences as for one occurrence, with `through one of those identifiers` in place of `through that identifier`

##### Example: Delete in a series with no time zone

- **GIVEN** a series with no time zone, host `Asia/Taipei`, and `S/RID=819835200` that starts at 2026-12-26T20:00:00+08:00, requested by 2026-12-26
- **WHEN** the span `future` delete text is built
- **THEN** it holds `deletes the occurrences of the series after that occurrence's original date.`, the sentence of both directions, `Measured on iCloud, through an occurrence moved later and one moved earlier. Known defect #549, measured on iCloud: in a series with no time zone that call answers deleted while that occurrence itself stays.`, the sentence of #550 for a delete, and ends `That delete cannot be undone. Nothing was deleted.`; no text of an all-day series or of a series with a zone names #549

##### Example: Update in a series with no time zone

- **GIVEN** the same series and occurrence, requested by 2026-12-26
- **WHEN** the span `future` update text is built
- **THEN** it equals the text built for a series in `Asia/Taipei` with the same occurrence and day

---
### Requirement: Move row names event_ids and the start day

For a `move_events_batch` row, the refusal SHALL be that row's `error`, SHALL say to pass the occurrence's identifier in `event_ids` with its `occurrence_dates` entry set to the day the occurrence starts, and SHALL NOT name `event_id`, a parameter the tool does not have. That day SHALL be printed in the edited occurrence's own time zone (this Mac's zone for an all-day occurrence or one with no zone), the zone in which the call through that identifier reads the entry (measured on iCloud: the day in the series' zone was answered with no occurrence, the day in the occurrence's zone moved it), and the text SHALL say so when that day differs from the day in the series' zone. Limit: on a Google calendar the zone an edited occurrence reports differed between runs (#548, cause not separated), so whether the printed day is accepted there by a later process was not measured. With several occurrences listed, the text prints no day: it prints each start in the series' zone and says to pass the day the occurrence starts, read in that occurrence's own time zone. The other rows of the call SHALL go on.

#### Scenario: A row with an edited occurrence fails alone

- **GIVEN** a call with two rows, the first naming a series' identifier and the day of an occurrence edited on its own
- **WHEN** the call runs
- **THEN** the first row reports `success: false` with the refusal as its error, and the second row is moved

##### Example: Move row

- **GIVEN** the match `S/RID=818906400` that starts at 2026-12-21T15:00:00+08:00 in `Asia/Taipei`, requested by 2026-12-21
- **WHEN** the row text is built
- **THEN** it holds `pass it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts.` and ends with `Nothing was moved.`

##### Example: Own zone day in the move row

- **GIVEN** series `S` in `Asia/Taipei`, and `S/RID=819511200` that starts at 2026-12-21T08:00:00+08:00 and has the zone `America/Los_Angeles` of its own (2026-12-20 there)
- **WHEN** the row text is built for the requested day 2026-12-21
- **THEN** it holds `with its occurrence_dates entry set to 2026-12-20, the day it starts (the day in that occurrence's own time zone).`, and the update and delete texts for the same match hold no `2026-12-20`

---
### Requirement: Identifier echoed only in a known shape

A refusal SHALL echo an identifier read from the store only when it is exactly the series' identifier the lookup used, followed by `/RID=` and one or more ASCII digits, every character of it is an ASCII letter, an ASCII digit, or one of `:` `/` `=` `-` `.` `_` and the at sign, and it is at most 200 characters long. The digits SHALL be checked to be ASCII digits and SHALL NOT be read as a date. Otherwise the text SHALL give no identifier and SHALL say to use the id `list_events` shows for the occurrence. The text SHALL NOT hold the event's title, its calendar's name or its account.

#### Scenario: An identifier with other characters is not echoed

- **GIVEN** an edited occurrence whose identifier holds a character outside the allowed list
- **WHEN** the refusal is built
- **THEN** the identifier is not in the text, and the text points to `list_events`

##### Example: Identifier outside the allowed characters

For the series identifier `6F2A:9B1C`:

| Identifier | Echoed |
| ---------- | ------ |
| `6F2A:9B1C/RID=819511200` | yes |
| `OTHER-1` | no |
| `6F2A:9B1C/RID=81951x` | no |
| `6F2A:9B1C/RID=1/RID=2` | no |
| `6F2A:9B1C/RID=` | no |
| the series identifier with a space in it, followed by `/RID=1` | no |
| one of 201 characters | no |

---
### Requirement: Not-found answer prints the local day

When no edited occurrence starts on the requested day, `update_event` and `delete_event` SHALL answer `Event not found: <identifier> (no occurrence on <day>)`, where `<identifier>` is the one the caller passed and `<day>` is the requested day as `yyyy-MM-dd` in the zone the day was read in: the event's zone, or this Mac's when the event has none. The day SHALL NOT be printed as a UTC instant. A `move_events_batch` row SHALL keep its answer `No occurrence of this event falls on occurrence_date.` The same answers SHALL be given, and no identifier SHALL be named, for a day an edited occurrence was moved off, and for an edited occurrence whose identifier is not the series' identifier followed by `/RID=`.

#### Scenario: The requested day reads as the caller wrote it

- **GIVEN** a series in `Asia/Taipei` with no occurrence on 2026-12-21
- **WHEN** `update_event` or `delete_event` is called with `occurrence_date` 2026-12-21
- **THEN** the error text ends with `(no occurrence on 2026-12-21)`

##### Example: Local day in the not-found text

- **GIVEN** the requested instant 2026-12-20T16:00:00Z, which is midnight of 2026-12-21 in `Asia/Taipei`, and the identifier `S`
- **WHEN** the not-found detail is built for the zone `Asia/Taipei`
- **THEN** it is `S (no occurrence on 2026-12-21)`

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
