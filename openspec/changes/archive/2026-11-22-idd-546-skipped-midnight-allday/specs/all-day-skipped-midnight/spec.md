## ADDED Requirements

### Requirement: A date names its day when the zone skips that midnight

A date-only value (`YYYY-MM-DD`) SHALL name 00:00 of that day in the zone it is read in, or, when that zone skips 00:00 of that day, the first instant of that day. A value that is not a calendar date (`2026-02-30`) or that the date-only form does not accept SHALL be refused as before.

#### Scenario: The skipped-midnight day is read from 01:00

- **WHEN** `2028-03-12` is read in `America/Havana`, where that day starts at 01:00
- **THEN** it names 01:00 of 2028-03-12, and `2026-02-30` read in the same zone is refused

##### Example: a date on the skipped-midnight day

| Zone | Value | Result |
|---|---|---|
| a zone whose day D starts at 01:00 | D | 01:00 of D |
| the same zone | the day before and after D | 00:00 of that day |
| the same zone | `2026-02-30`, `2026-13-01`, `2026-04-31` | refused |

### Requirement: An all-day event is read as the days it stands for

Where the server prints an all-day event's dates and where `update_event` counts the days of a stored all-day event, it SHALL read the pair EventKit returns as (start of the first day, last second of the last day) in this Mac's zone: a start that is not the start of its day stands for the nearest day start (the next day from noon on), and the number of days is the elapsed time rounded to whole days. Only a pair whose first day so read does not start at 00:00 SHALL be read anew, and a pair more than three hours from that reading SHALL be used as returned; every other pair SHALL be unchanged, whatever its end. A timed event's dates SHALL be printed as returned.

#### Scenario: A one-day event on the skipped-midnight day

- **WHEN** EventKit returns a one-day all-day event on a day that starts at 01:00 as 01:00 to 00:59:59 of the next day
- **THEN** it is printed from `T01:00:00` to `T23:59:59` of that day, and moved with `start_time` alone it stays one day

##### Example: a one-day event on the day reads as that day

| Returned start | Returned end | Read as |
|---|---|---|
| 01:00 of D (measured, iCloud) | 00:59:59 of D+1 | 01:00 to 23:59:59 of D |
| 23:00 of D-1 (the issue's Google numbers) | 22:59:59 of D | 01:00 to 23:59:59 of D |
| 01:00 of D | 00:59:59 of D+2 | D and D+1 |
| 00:00 of an ordinary day | any end (23:59:59, an exact next midnight, an hour short) | unchanged |

##### Example: moving that event by its start keeps one day

| Stored (as returned) | Update | Written |
|---|---|---|
| 01:00 of D to 00:59:59 of D+1 | `start_time` alone, a later day L | L, one day |

##### Example: list_events gives that day

| Event | Printed `start_date_local` | Printed `end_date_local` |
|---|---|---|
| all-day, returned 01:00 of D to 00:59:59 of D+1 | `DT01:00:00` | `DT23:59:59` |
