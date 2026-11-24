## ADDED Requirements

### Requirement: An all-day occurrence back at its slot is not counted as moved where both readings of its slot name one day

The create-undo scan of a series SHALL count an occurrence edited on its own as moved off its slot unless its start equals its slot read as an instant, or all of the following hold: the occurrence and the series are all-day; the slot came from the `/RID=` digits of an identifier and is exactly 00:00 UTC; the start equals the first instant, in the host zone, of that slot's UTC date (midnight where it exists); and that slot's day in the host zone is the same date. No occurrence that the instant comparison finds on its slot SHALL be counted as moved. The same date is read in the host zone, while the day a store gave a 00:00 UTC slot was set in the zone the series was in when the occurrence was first edited, which cannot be read later. One case is therefore accepted although the occurrence moved: a series created all-day, made timed in a zone west of UTC with its slot at exactly 00:00 UTC (the day before there), an occurrence edited while it was timed, the series set back to its recorded all-day values, and that occurrence moved by one day onto the UTC date, read on a host at or east of UTC. The create-undo then deletes the series with that one-day move. A series still converted at the undo is refused by the field check of the series against its create record (#236).

#### Scenario: Set back at its slot on a host east of UTC

- **WHEN** an occurrence of an all-day series, edited on its own and set back to the series' values, has `/RID=` digits at 00:00 UTC of its day and a start at midnight of that day in Asia/Taipei
- **THEN** it is not counted, and the create-undo is not refused for it

#### Scenario: West of UTC the count stays

- **WHEN** the same occurrence is read on a host in America/Los_Angeles
- **THEN** it is counted as moved, as before, since the digits read as an instant name the day before

##### Example: set back at its slot, by host zone

| Host zone | Counted |
|---|---|
| Pacific/Pago_Pago | yes |
| America/Los_Angeles | yes |
| UTC | no |
| Asia/Taipei | no |
| Pacific/Kiritimati | no |

##### Example: shapes compared as before

| Shape | Counted |
|---|---|
| all-day occurrence moved to another day | yes |
| timed occurrence at its `/RID=` instant | no |
| slot from `occurrenceDate`, not `/RID=` | as before |
| `/RID=` digits not at 00:00 UTC | as before |
| occurrence all-day, series timed | yes (as before) |
