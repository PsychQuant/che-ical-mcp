## MODIFIED Requirements

### Requirement: A date names its day when the zone skips that midnight

The start and end dates of an all-day create, batch create, or update, and date-only occurrence selectors (including recurrence exclusions), SHALL accept exact ten-byte ASCII `YYYY-MM-DD` on a day whose midnight is skipped and use its first instant in the zone used to parse it. All-day event endpoints use the server process zone. Occurrence selectors use the applicable series or event zone, falling back to the process zone. For `span: "all"`, a supplied bare date is parsed in the process zone for validation. It does not select an occurrence, and a recurring move with both span all and a date is refused. An update of an already all-day event with a stored zone that is neither the process zone nor an equivalent alias SHALL refuse an endpoint requiring this fallback. Timed endpoints, reminder inputs, query bounds and recurrence end dates retain their existing parsing. An impossible Gregorian date and a civil date skipped in full SHALL both be refused.

#### Scenario: The skipped-midnight day is read from 01:00

- **WHEN** an all-day endpoint is `2028-03-12` in `America/Havana`
- **THEN** it names 01:00 on that date, while `2026-02-30` and Apia's wholly skipped `2011-12-30` in their respective zones are refused

##### Example: a date on the skipped-midnight day

| Zone | Value | Result |
|---|---|---|
| a zone whose day D starts at 01:00 | D | 01:00 of D |
| the same zone | the day before and after D | 00:00 of that day |
| the same zone | `2026-02-30` | refused |

### Requirement: An all-day event is read as the days it stands for

The date fields of `list_events`, `list_events_quick`, `search_events`, `check_conflicts`, and `delete_events_batch` dry-run rows, and `update_event` planning when both the stored and resulting event are all-day, SHALL apply the correction in the server process zone (including `TZ=`). Correction applies only when the event has no time zone of its own or its zone matches the process zone, including an equivalent alias. The two shapes are recognized at second precision. In the iCloud shape the start equals a civil day's first instant one minute to three hours after midnight. Its raw end is one second before a later civil day's first instant shifted forward by that gap. In the Google shape the day begins at 01:00, the raw start is at 23:00 the evening before, and shifting both raw endpoints forward by one hour places them at the first instant of the first day and the last second of the last day. The correction SHALL return the first and last instants of the inferred range at second precision and keep other pairs as returned. The local output fields still use `display_timezone`, the event's zone, or the process zone according to the tool's formatting rules. Matching and membership use the stored values. The duplicate and similar-event outputs, `occurrence_start` and undo item text also keep those values. Timed dates and inherited endpoints when converting to timed SHALL use the original pair.

#### Scenario: A one-day event on the skipped-midnight day

- **WHEN** EventKit returns a one-day all-day event on a day that starts at 01:00 as 01:00 to 00:59:59 of the next day
- **THEN** it is printed from `T01:00:00` to `T23:59:59` when displayed in the process zone, and moved with `start_time` alone it stays one day

##### Example: a one-day event on the day reads as that day

| Returned start | Returned end | Read as |
|---|---|---|
| 01:00 of D | 00:59:59 of D+1 | 01:00 to 23:59:59 of D |
| 23:00 of D-1 | 22:59:59 of D | 01:00 to 23:59:59 of D |
| 22:00 of D-1 | 22:00 of D | unchanged |

##### Example: moving that event by its start keeps one day

| Stored (as returned) | Update | Written |
|---|---|---|
| 01:00 of D to 00:59:59 of D+1 | `start_time` alone, a later day L | L, one day |

##### Example: list_events gives that day

| Event | Printed `start_date_local` | Printed `end_date_local` |
|---|---|---|
| all-day, returned 01:00 of D to 00:59:59 of D+1, displayed in the process zone | `DT01:00:00` | `DT23:59:59` |

#### Scenario: A recognized range crosses a later offset transition

- **WHEN** an iCloud-shaped pair crosses a later fall-back or a Google-shaped pair crosses a wholly skipped civil date
- **THEN** the dates are corrected using their day boundaries, and a canonical pair across the same transition is returned as stored

##### Example: Apia skips 2011-12-30

| Pair | Stored endpoints (UTC) | Read endpoints (UTC) |
|---|---|---|
| Canonical | `2010-09-26T11:00:00Z` to `2012-04-10T10:59:59Z` | unchanged |
| Google shape | `2010-09-26T10:00:00Z` to `2012-04-10T09:59:59Z` | `2010-09-26T11:00:00Z` to `2012-04-10T10:59:59Z` |

### Requirement: An occurrence day ends at the start of the following day

For a day whose midnight is skipped, timed occurrence-day matching SHALL use a window ending at the next civil day's first instant if it is earlier than adding one calendar day to the start. The candidate search SHALL apply that bound to the requested day in the search zone and the corresponding civil day in the host zone, then search from the earlier start to the later end. Day matching still uses the search zone's window. Days with an existing midnight retain the existing calendar-day addition.

#### Scenario: The day starts at 01:00

- **WHEN** a request selects 2028-03-12 in Havana
- **THEN** a timed occurrence starting at 00:30 on 2028-03-13 is outside that day
