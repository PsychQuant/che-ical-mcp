## ADDED Requirements

### Requirement: A date-only recurrence end includes that day

A `recurrence.end_date` given as a date only (`YYYY-MM-DD`) on `create_event`, `create_events_batch`, `update_event`, `create_reminder` or `update_reminder` SHALL be stored as the last instant of that day in the zone it is read in: on `create_event` and `create_events_batch` the event's `timezone` when given, otherwise the host zone; on `update_event` the call's `timezone` when given, otherwise the event's stored zone (through an occurrence's own identifier, that occurrence's zone, which is the series' unless it was set elsewhere), and the host zone for a floating event or one `clear_timezone` makes floating; on the reminder tools the host zone, also when the due date carries another zone: the first instant of the next day minus one second. On the event tools an occurrence on that day SHALL therefore be in the series at any time of day; on the reminder tools only the stored end is specified. A `recurrence.end_date` with a time SHALL be stored as the instant given. A date the parser refuses SHALL stay refused.

#### Scenario: A weekly reminder ending on its third Monday

- **WHEN** `create_reminder` has `due_date` 2026-11-30T10:00:00+08:00 and `recurrence` weekly on Mondays with `end_date` "2026-12-14", on a host in Asia/Taipei
- **THEN** the rule's end is stored as 2026-12-14T23:59:59+08:00, the last second of that day in this Mac's zone

##### Example: stored end

| `end_date` | Read in | Stored end |
|---|---|---|
| `2026-12-14` | Asia/Taipei | 2026-12-14T23:59:59+08:00 |
| `2026-12-14` | America/New_York | 2026-12-14T23:59:59-05:00 |
| `2027-03-13` | America/New_York (the next day starts in daylight time) | 2027-03-13T23:59:59-05:00 |
| `2028-03-11` | America/Havana (the next midnight is skipped) | 2028-03-11T23:59:59-05:00 |
| `2027-03-14` | America/New_York (a 23-hour day) | 2027-03-14T23:59:59-04:00 |
| `2026-12-14T00:00:00+08:00` | any | unchanged |
| `2028-03-12` | America/Havana | refused, as before |
