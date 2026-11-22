## MODIFIED Requirements

### Requirement: Series identifier and day do not address an edited occurrence

The occurrence lookup by a series' identifier and a day SHALL stay as it is: it resolves the occurrence that starts on that day and is still addressed by the series' identifier. When that lookup resolves nothing in `update_event` or `delete_event` (span `this` or `future` with `occurrence_date`) or in `move_events_batch` (span `this` with an occurrence date), the call SHALL look for occurrences of that series that were edited on their own and start on the requested day.

The search SHALL read only the events of the requested day's window, the window the lookup enumerates. It SHALL take an event only when its identifier is the series' identifier followed by `/RID=` (the exact series part, so a longer identifier that begins with the same characters is not taken) and it starts on the requested day: in the series' zone, in this Mac's zone for a series with no time zone, and in this Mac's zone for an all-day occurrence. Of each event the search SHALL read its identifier, its all-day state, its start and its own time zone, and nothing else: it SHALL NOT read the digits after `/RID=` as a date, an occurrence date, an external identifier or whether the event is detached, and it SHALL NOT list the series. An edited occurrence whose identifier equals the series' identifier, or has another shape (one tied to its series by the external identifier only), SHALL NOT be found; no such source was measured. The search reads nothing after `/RID=`: that what follows it is ASCII digits is the echo check's rule (requirement "Identifier echoed only in a known shape"), not the search's, so an event taken with another suffix is still found and only its identifier is not echoed. On iCloud and on Google through EventKit, every occurrence edited on its own that was read had an identifier of the series' identifier followed by `/RID=` and digits, an edited occurrence of a series whose first occurrence was deleted included; a slot before 2001 would give a negative number after `/RID=`, which the echo check does not echo, and none was read on a device.

An occurrence that was moved off the requested day SHALL NOT be found through the series' identifier and that day: the answer is not found, as before this capability, and `list_events` shows the occurrence under its own identifier.

When exactly one such occurrence is found, the call SHALL be refused, SHALL write nothing, and the refusal SHALL say that an occurrence of this series that starts on the requested day was edited on its own, so the series' identifier and that day do not address it, and SHALL give that occurrence's identifier, the one `list_events` shows, where the identifier may be echoed (requirement "Identifier echoed only in a known shape"; otherwise the refusal points to `list_events`). In `update_event` and `delete_event` with span `this` the refusal SHALL say to pass that identifier as `event_id` and to leave `occurrence_date` out (a move row's refusal SHALL say instead to pass it in `event_ids` with its `occurrence_dates` entry set to the day it starts, requirement "Move row names event_ids and the start day"); that call was measured on iCloud, where an occurrence edited on its own reports no recurrence rule of its own (where one does, the call asks for `occurrence_date`), and not on Google or Exchange. No refusal SHALL print or imply an original date, or say that an occurrence was on the requested day: every date in it is the requested day, the start of a listed occurrence, or, in a move row, the day a listed occurrence starts in its own time zone (requirement "Move row names event_ids and the start day"). The refusal of `delete_event` SHALL end by saying that nothing was deleted, the others that nothing was written or moved.

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
- **THEN** no text holds `was on that day`, `had on`, `original date is`, a date after `original date`, `now starts`, `starts now` or `no longer address`, and every date in it is the requested day (a move row may also print the day the occurrence starts in its own time zone, example "Own zone day in the move row")

##### Example: No original date in any text

- **GIVEN** `S/RID=819511200` starting at 2026-12-21T10:00:00+08:00 and `S/RID=818906400` starting at 2026-12-21T15:00:00+08:00, requested by 2026-12-21
- **WHEN** the five texts are built for each one alone and for both
- **THEN** the only date in each is `2026-12-21`, and `2026-12-14` is in none

### Requirement: Span future refusals say what the identifier takes

For `update_event` with span `future`, the refusal SHALL give the occurrence's identifier where it may be echoed (otherwise it points to `list_events`), SHALL NOT say that a span `future` call through that identifier takes the fields of the refused call, and SHALL name the other way with the route the refusal for span `future` through an occurrence's own identifier uses, followed by that refusal's ending (if that identifier is refused, the shape has no tested way) and its sentence on the fields that way leaves out, all read from the same constants so the texts cannot differ. For `delete_event` with span `future`, the refusal SHALL say that the delete through that identifier starts at the occurrence's original date and that this delete cannot be undone. The span of the call SHALL reach the text builder at each caller that takes both spans.

A span `future` call through the identifier of an edited occurrence starts at that occurrence's original date, not at the day it starts on now. This server does not read that date. Every span `future` text, with one occurrence or several, SHALL say so and SHALL give both directions without the original date: when that date is before the requested day, occurrences of the series before the requested day are written (deleted) too; when it is after, the occurrences between the requested day and that date are not reached. It SHALL cite what was measured, without dates: on iCloud, an update of a title and a delete through an occurrence moved later and through one moved earlier, and an update of a title through one moved later in a series with no time zone.

Every span `future` text SHALL also say, whatever the occurrence: where the store recorded that occurrence at another time of day than the series, a span `future` update through its identifier moved the later occurrences of the series to another day (#550), and the update text SHALL add that span `this` on that occurrence is the tested way; the delete text SHALL say instead what #550 measured for a delete: that occurrence and the later ones were removed, and an occurrence the rule shows on its day stayed.

In a timed series with no time zone, the delete refusal SHALL say that the delete removes the occurrences of the series after that occurrence's original date, and SHALL name the known defect #549 as one, measured on iCloud for an occurrence edited in place and one moved later (one moved earlier was not run): in such a series that call answers `deleted` while the edited occurrence itself stays. That sentence SHALL NOT be in any other refusal text, nor in the refusal of any other series; the tool description, the READMEs and the CHANGELOG describe it too. It, the tool description and the release-gate cell change when #549 is fixed. The update text of such a series SHALL be the one of a series with a zone.

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
- **THEN** it holds `deletes the occurrences of the series after that occurrence's original date.`, the sentence of both directions, `Measured on iCloud, through an occurrence moved later and one moved earlier. Known defect #549, measured on iCloud for an occurrence edited in place and one moved later: in a series with no time zone that call answers deleted while that occurrence itself stays.`, the sentence of #550 for a delete, and ends `That delete cannot be undone. Nothing was deleted.`; no text of an all-day series or of a series with a zone names #549

##### Example: Update in a series with no time zone

- **GIVEN** the same series and occurrence, requested by 2026-12-26
- **WHEN** the span `future` update text is built
- **THEN** it equals the text built for a series in `Asia/Taipei` with the same occurrence and day
