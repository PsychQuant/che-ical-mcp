# occurrence-date-own-identifier Specification

## Purpose

Through the own identifier of one occurrence, `update_event` and `delete_event` with span `this` or `future` take `occurrence_date` only when it names that occurrence's day (#416). This capability states which days those are, and how an occurrence's original day is read from its `/RID=` identifier on any host time zone (#543).

## Requirements

### Requirement: Occurrence date names the occurrence's shown day or its original day

When `update_event` or `delete_event` addresses one occurrence through its own identifier with span `this` or `future` and passes `occurrence_date`, the server SHALL accept the date when it is the day the occurrence starts on, or the occurrence's original day, and SHALL refuse it otherwise, writing nothing. The day the occurrence starts on SHALL be read with the occurrence's own all-day flag: for an all-day occurrence its day in this Mac's time zone, for a timed one the day of `occurrence_date` in the occurrence's time zone. The original day SHALL be read from the `/RID=` part of the identifier (from `occurrenceDate` when the identifier has none) with the all-day flag of the series:

- for an all-day series the `/RID=` digits SHALL be read as a floating date, the day they give at 00:00 UTC, placed on that day in this Mac's time zone, and compared as an all-day day;
- for a timed series the digits SHALL be read as an instant, as before.

The series' all-day flag SHALL be read from the series object named by the part of the identifier before `/RID=`. When that object cannot be read (no such object, or the lookup throws), the occurrence's own all-day flag SHALL be used. The comparison SHALL take the host time zone as a parameter, the same zone for the `/RID=` reading and for the day comparison.

#### Scenario: All-day original day on a host west of UTC

- **WHEN** an occurrence of an all-day weekly series whose `/RID=` names 2026-12-28 was moved on its own to 2026-12-30, and `occurrence_date` is passed through its own identifier on a host at America/Los_Angeles
- **THEN** 2026-12-28 and 2026-12-30 are accepted, and 2026-12-27 and 2026-12-29 are refused with nothing written

##### Example: one shape on five host zones

| Host zone | 2026-12-27 | 2026-12-28 | 2026-12-29 | 2026-12-30 |
|---|---|---|---|---|
| Pacific/Pago_Pago | refused | accepted | refused | accepted |
| America/Los_Angeles | refused | accepted | refused | accepted |
| UTC | refused | accepted | refused | accepted |
| Asia/Taipei | refused | accepted | refused | accepted |
| Pacific/Kiritimati | refused | accepted | refused | accepted |

#### Scenario: A timed series' occurrence made all-day on its own

- **WHEN** the series is timed, its occurrence slot is 2026-12-28 07:00 at Asia/Taipei (`/RID=` the instant 2026-12-27 23:00 UTC), the occurrence was made all-day on its own and moved to 2026-12-30, and the host is Asia/Taipei
- **THEN** 2026-12-28 is accepted and 2026-12-27 is refused, as the `/RID=` is read as an instant with the series' flag

#### Scenario: The series object cannot be read

- **WHEN** the series object of an all-day occurrence cannot be read
- **THEN** the occurrence's own all-day flag is used, and the all-day shape above gives the same answers

<!-- @trace
source: idd-543-allday-occurrence-date
updated: 2026-11-22
code:
  - Tests/CheICalMCPTests/OccurrenceDateMatchTests.swift
  - CHANGELOG.md
  - Tests/CheICalMCPTests/DetachedOccurrenceSpanTests.swift
-->