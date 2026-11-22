## MODIFIED Requirements

### Requirement: Occurrence date names the occurrence's shown day or its original day

When `update_event` or `delete_event` addresses one occurrence through its own identifier with span `this` or `future` and passes `occurrence_date`, the server SHALL accept the date when it is the day the occurrence starts on, or the occurrence's original day as far as the identifier shows it, and SHALL refuse it otherwise, writing nothing.

The day the occurrence starts on SHALL be compared as before: for an all-day occurrence, its start's day in this Mac's time zone against the day of `occurrence_date` in the zone `occurrence_date` was read in (the occurrence's time zone, this Mac's for an occurrence without one); for a timed one, whether its start lies within the day of `occurrence_date` in that zone.

The original slot SHALL be read from the `/RID=` part of the event identifier, else of the external identifier, else from `occurrenceDate`. What the `/RID=` digits mean depends on the series when the occurrence was first edited on its own, not on the series now: an all-day series writes a floating date (the day at 00:00 UTC), a timed series an instant. The server SHALL read them as follows:

- with no `/RID=`, or digits that are not 00:00 UTC of a day, the slot SHALL be compared as before (an instant, with the occurrence's own all-day flag and zone): a floating date is always 00:00 UTC;
- with digits at 00:00 UTC, the series object named by the part of the event identifier before `/RID=` readable, and the series and the occurrence both all-day, the original day SHALL be the digits' UTC date, compared with the day of `occurrence_date` in the zone it was read in, without going through an instant of this Mac's zone;
- with digits at 00:00 UTC, the series readable, and the series and the occurrence both timed, the slot SHALL be compared as before;
- otherwise (the series object cannot be read: none, the lookup throws, or the event identifier has no `/RID=` part; or the series and the occurrence differ in being all-day) the server SHALL take the original day only when both readings give the date, and when exactly one does it SHALL refuse with a reason that says the date may be the original day and that the occurrence is reached by the day it starts on or by leaving `occurrence_date` out.

The comparison SHALL take this Mac's time zone as a parameter.

The server SHALL NOT read the series' flag from the occurrence, and SHALL NOT look the series up by the external identifier.

Known limits, read from the code and not measured:

- the series' flag is the series' now; a series converted between all-day and timed after the edit (#428 (h), or another app) is read by its flags of now where they agree, which is wrong only for a timed slot at exactly 00:00 UTC whose series and occurrence were both made all-day afterwards, on a host where that instant is another day;
- an occurrence of a timed series with no time zone, edited while the series had none, has its wall-clock time as its digits (#539); this check reads them as an instant as before, so its original day can be off by a day by the host's offset; that stays open in #569;
- whether the store rewrites the `/RID=` digits when a series is converted is not measured.

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
- **THEN** 2026-12-28 is accepted and 2026-12-27 is refused, as digits that are not 00:00 UTC are read as an instant, whatever the series' flag says now and whether the series can be read

#### Scenario: The series object cannot be read

- **WHEN** an all-day occurrence's `/RID=` is 2026-12-28 00:00 UTC on its external identifier only, so the series is not looked up, and it was moved to 2026-12-30
- **THEN** on a host at Asia/Taipei or UTC 2026-12-28 is accepted; on a host at America/Los_Angeles 2026-12-27 and 2026-12-28 are refused with the reason that the date may be the original day, and 2026-12-30 is accepted

#### Scenario: A host that skipped the day

- **WHEN** the host is Pacific/Apia, which has no 2011-12-30, an occurrence of an all-day series whose `/RID=` names 2011-12-30 carries the time zone UTC, and `occurrence_date` 2011-12-30 is read in UTC
- **THEN** 2011-12-30 is accepted and 2011-12-31 is refused

#### Scenario: Every cell against main

- **WHEN** each cell of {host Asia/Taipei, UTC, America/Los_Angeles} × {all-day series, timed series in Asia/Tokyo at 07:00, 09:00 and 12:00, timed series with no zone at 00:00, 07:00 and 20:00} × {plain, moved, made all-day, made timed, series converted after the edit, series and occurrence converted after the edit} × {series readable, not} is compared with `main`'s check and with the right days for the way the digits were written
- **THEN** the server takes a wrong day that `main` refused in one cell only (Tokyo 09:00, series and occurrence converted, readable, Los Angeles, 2026-12-28), refuses a right day that `main` took in four (Tokyo 09:00 made all-day or both converted, readable or not, Los Angeles, 2026-12-27), and takes a right day `main` refused in two (the all-day series' moved occurrence, readable, Los Angeles, 2026-12-28; the no-zone series at 00:00 with series and occurrence both converted, readable, Los Angeles, 2026-12-28)
