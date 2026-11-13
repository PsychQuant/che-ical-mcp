## MODIFIED Requirements

### Requirement: Span future refusals say what the identifier takes

For `update_event` with span `future`, the refusal SHALL give the occurrence's identifier, SHALL NOT say that a span `future` call through that identifier takes the fields of the refused call, and SHALL name the other way with the route the refusal for span `future` through an occurrence's own identifier uses, followed by that refusal's ending (if that identifier is refused, the shape has no tested way) and its sentence on the fields that way leaves out, all read from the same constants so the texts cannot differ. For `delete_event` with span `future`, the refusal SHALL say that the delete through that identifier starts at the occurrence's original date, give that date when it is read, and say that this delete cannot be undone. The span of the call SHALL reach the text builder at each caller that takes both spans.

A span `future` call through the identifier of an occurrence that was moved starts at that occurrence's original date, not at the day it starts now (measured on iCloud: a delete for an occurrence moved later and for one moved earlier; an update of the title for one moved later, for one moved earlier, and so read for one asked by its original day).

With one occurrence found, the update refusal SHALL say, for every occurrence that was moved and whose original date is read, that the write starts at that original date, and what was measured: for one that starts on the requested day and came from an earlier date, that a title written that way reached the occurrences of the series from the original date on; for one that starts on the requested day and came from a later date, that it did not reach the occurrences between the requested day and the original date; for one asked by its original day, that the write does not start at the day it starts now. It SHALL say nothing of where the write starts for an occurrence that was not moved or whose original date is not read. The delete refusal SHALL give the original date when it is read and, when the occurrence starts on the requested day and its original date is earlier, SHALL say that the occurrences of the series from the original date up to the requested day are deleted too.

With several listed, the update refusal SHALL say that a call through one of those identifiers starts at that occurrence's original date, which for one that was moved is not the day it starts now, and that a title written that way reached the occurrences from the original date on; the delete refusal SHALL say that for one that was moved later the occurrences from its original date up to the day it starts now are deleted too.

For a timed series with no time zone the original date is not read. The update refusal SHALL say nothing of where the write starts. The delete refusal SHALL give no date; it SHALL say that the delete removes the occurrences of the series after that occurrence's original date, that this server does not read that date for such a series, that occurrences before the requested day are deleted too when that date is earlier, and what was measured on iCloud in such a series: the edited occurrence itself stayed, although the call answered `deleted` (#549). For an occurrence with no slot in a series with a zone, the delete text SHALL say that the cut is at the original date and give no date.

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

##### Example: Moved earlier with span future

- **GIVEN** the match `S/RID=819511200` (original date 2026-12-21) that now starts at 2026-12-13T10:00:00+08:00, requested by 2026-12-13 in `Asia/Taipei`
- **WHEN** the span `future` texts are built
- **THEN** the update text holds `It starts at that occurrence's original date, 2026-12-21, not at 2026-12-13: a title written that way did not reach the occurrences of the series between 2026-12-13 and 2026-12-21 (measured on iCloud).`, and the delete text names 2026-12-21 and adds no sentence on other occurrences

##### Example: Delete in a series with no time zone

- **GIVEN** a series with no time zone, host `Asia/Taipei`, and `S/RID=819835200` that starts at 2026-12-26T20:00:00+08:00, requested by 2026-12-26
- **WHEN** the span `future` delete text is built
- **THEN** it ends `delete_event with span 'future' through that identifier, where that call allows it, deletes the occurrences of the series after that occurrence's original date, which this server does not read for a series with no time zone: if that date is earlier than 2026-12-26, occurrences before 2026-12-26 are deleted too. Measured on iCloud; in such a series that occurrence itself stayed (#549). That delete cannot be undone. Nothing was deleted.`

