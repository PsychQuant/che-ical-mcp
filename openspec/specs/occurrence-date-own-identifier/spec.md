# occurrence-date-own-identifier Specification

## Purpose

Through the own identifier of one occurrence, `update_event` and `delete_event` with span `this` or `future` take `occurrence_date` only when it names that occurrence's day (#416). This capability states which days those are, and how an occurrence's original day is read from its `/RID=` identifier on any host time zone (#543).

## Requirements

### Requirement: Occurrence date names the occurrence's shown day or its original day

When `update_event` or `delete_event` addresses one occurrence through its own identifier with span `this` or `future` and passes `occurrence_date`, the server SHALL accept the date when it is the day the occurrence starts on, or the occurrence's original day as far as the identifier shows it, and SHALL refuse it otherwise, writing nothing.

The day the occurrence starts on SHALL be compared as before: for an all-day occurrence, its start's day in this Mac's time zone against the day of `occurrence_date` in the zone `occurrence_date` was read in (the occurrence's time zone, this Mac's for an occurrence without one); for a timed one, whether its start lies within the day of `occurrence_date` in that zone. A request that is exactly the all-day occurrence's shown start also matches, as before.

The original slot SHALL be read from the `/RID=` part of the event identifier, else of the external identifier, else from `occurrenceDate`. What the `/RID=` digits mean depends on the series when the occurrence was first edited on its own, not on the series now: an all-day series writes a floating date (the day at 00:00 UTC), a timed series an instant. The server SHALL read them as follows:

- with no `/RID=`, or digits that are not 00:00 UTC of a day, the slot SHALL be compared as before (an instant, with the occurrence's own all-day flag and zone): a floating date is always 00:00 UTC;
- with digits at 00:00 UTC, the server SHALL compare an instant as before and independently compare the digits' UTC civil date against the requested civil date in the request zone. It SHALL accept the original day if both readings give it. If exactly one does, it SHALL refuse with a reason that names the ambiguity, the shown day, and omitting `occurrence_date` as a way to reach the occurrence.

The comparison SHALL take this Mac's time zone as a parameter. The server SHALL NOT look up the series to infer how its identifier was encoded: neither current flag proves how the original slot was written.

Known limits: a timed slot written while its series had no time zone uses wall-clock digits (#539). This check retains the existing instant comparison except for ambiguous midnight UTC identifiers. The general wall-clock problem stays open in #569. Whether the store rewrites the digits when a series is converted remains unmeasured.

#### Scenario: All-day original day on a host west of UTC

- **WHEN** an occurrence of an all-day weekly series whose `/RID=` names 2026-12-28 was moved on its own to 2026-12-30, and `occurrence_date` is passed through its own identifier on a host at America/Los_Angeles
- **THEN** 2026-12-30 is accepted; 2026-12-27 and 2026-12-28 are refused as ambiguous, and 2026-12-29 is refused as unrelated, with nothing written on refusal

##### Example: one shape on five host zones

| Host zone | 2026-12-27 | 2026-12-28 | 2026-12-29 | 2026-12-30 |
|---|---|---|---|---|
| Pacific/Pago_Pago | ambiguous | ambiguous | refused | accepted |
| America/Los_Angeles | ambiguous | ambiguous | refused | accepted |
| UTC | refused | accepted | refused | accepted |
| Asia/Taipei | refused | accepted | refused | accepted |
| Pacific/Kiritimati | refused | accepted | refused | accepted |

#### Scenario: A timed series' occurrence made all-day on its own

- **WHEN** the series is timed, its occurrence slot is 2026-12-28 07:00 at Asia/Taipei (`/RID=` the instant 2026-12-27 23:00 UTC), the occurrence was made all-day on its own and moved to 2026-12-30, and the host is Asia/Taipei
- **THEN** 2026-12-28 is accepted and 2026-12-27 is refused, as digits that are not 00:00 UTC are read as an instant

#### Scenario: Only the external identifier carries a recurrence ID

- **WHEN** an all-day occurrence's `/RID=` is 2026-12-28 00:00 UTC on its external identifier only and it was moved to 2026-12-30
- **THEN** on a host at Asia/Taipei or UTC 2026-12-28 is accepted; on a host at America/Los_Angeles 2026-12-27 and 2026-12-28 are refused with the ambiguous-original-day reason, and 2026-12-30 is accepted

#### Scenario: A host that skipped the day

- **WHEN** the host is Pacific/Apia, which has no 2011-12-30, an occurrence of an all-day series whose `/RID=` names 2011-12-30 carries the time zone UTC, and `occurrence_date` 2011-12-30 is read in UTC
- **THEN** 2011-12-30 is accepted where both comparisons match it, 2011-12-29 is refused as ambiguous for the all-day occurrence, and 2011-12-31 is refused as unrelated

#### Scenario: Every cell against main

- **WHEN** each cell of {host Asia/Taipei, UTC, America/Los_Angeles} × {all-day series, timed series in Asia/Tokyo at 07:00, 09:00 and 12:00, timed series with no zone at 00:00, 07:00 and 20:00} × {plain, moved, made all-day, made timed, series converted after the edit, series and occurrence converted after the edit} × {series readable, not} is compared with `main`'s check and with the right days for the way the digits were written
- **THEN** the server accepts no wrong day that the base branch refused and accepts no additional days. In the Tokyo grid the base branch's four correct dates lost are the 09:00 slot made all-day or with both converted, each with readable or unreadable series, under Los Angeles (2026-12-27). In the additional America/New_York 19:00 grid, sixteen correct dates are refused: moved and series converted on each host, plus made all-day and both converted under Los Angeles, each with readable or unreadable series (2026-12-28).

<!-- @trace
source: idd-543-fix1-midnight
updated: 2026-11-22
code:
  - Tests/CheICalMCPTests/OccurrenceDateMatchTests.swift
  - Sources/CheICalMCP/EventKit/DetachedOccurrenceSpan.swift
  - Tests/CheICalMCPTests/OccurrenceDateMatchWiringTests.swift
  - Sources/CheICalMCP/EventKit/FirstRemainingOccurrence.swift
  - Sources/CheICalMCP/EventKit/OccurrenceDateMatch.swift
  - Tests/CheICalMCPTests/OccurrenceDateMatchCellTests.swift
  - Sources/CheICalMCP/EventKit/EventKitManager.swift
  - Tests/CheICalMCPTests/DetachedOccurrenceSpanTests.swift
  - CHANGELOG.md
-->