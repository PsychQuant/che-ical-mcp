## ADDED Requirements

### Requirement: An all-day occurrence back at its slot is not counted as moved where both readings of its slot name one day

The create-undo scan of a series SHALL count an occurrence edited on its own as moved off its slot unless its start equals its slot read as an instant, or all of the following hold: the occurrence and the series are all-day; the slot came from the `/RID=` digits of an identifier and is exactly 00:00 UTC; the start equals midnight, in the host zone, of that slot's UTC date; and that slot's day in the host zone is the same date. No occurrence that the instant comparison finds on its slot SHALL be counted as moved.

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
| occurrence all-day, series timed | yes |
