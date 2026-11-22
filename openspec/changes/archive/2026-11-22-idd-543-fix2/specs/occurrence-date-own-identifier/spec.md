## MODIFIED Requirements

### Requirement: Occurrence date names the occurrence's shown day or its original day

When `update_event` or `delete_event` addresses one occurrence through its own identifier with span `this` or `future` and passes `occurrence_date`, the server SHALL check the shown start first. If that check fails, it SHALL check the original slot. A refusal SHALL write nothing.

For an all-day occurrence, the shown-start check SHALL compare the start's day in the host zone with the requested day in the request zone. A request exactly equal to the all-day start instant also SHALL match. For a timed occurrence the start SHALL fall within the requested day in the request zone. The request zone is the occurrence's zone, or the host zone when the occurrence has none.

The server SHALL read the original slot from the event identifier's `/RID=`, then the external identifier's `/RID=`, then `occurrenceDate`. Without a recurrence ID at 00:00 UTC it SHALL compare the slot as an instant using the existing shown-start comparison, with the occurrence's own all-day flag and zone. At 00:00 UTC it SHALL also compare the UTC civil date of the digits with the requested civil date in the request zone. If both readings match, the date SHALL pass. If neither matches, the date SHALL be refused as unrelated. If just one matches, the date SHALL be refused as undetermined unless it already passed the shown-start check. The reason SHALL say that the recurrence ID does not establish the original day here, give the date used by the shown-start comparison when available, and offer omitting `occurrence_date`.

The comparison SHALL take the host zone as a parameter. The server SHALL NOT look up the series to infer the recurrence ID's encoding from current flags.

**Known limits tracked in #543**

- West of UTC, a moved all-day occurrence's original day is still refused, now as undetermined when the two readings disagree.
- An original-slot request previously accepted on main is newly refused as undetermined when its recurrence ID is at 00:00 UTC and the UTC date and existing instant comparison disagree, unless the shown-start check passes. Examples include a moved timed occurrence at 19:00 EST, 20:00 EDT or 16:00 PST, and an explicit instant that equals the recurrence ID when the request zone puts it on a different civil day.
- A zoned all-day occurrence can still pass both midnight checks on the host day after conversion from timed, even if its original timed slot was on a different day in the occurrence's zone.
- The inherited exact-instant shown-start shortcut can accept a request naming another civil day when the request and shown start are in different zones.

Timed slots can also carry wall-clock digits. The general wall-clock issue remains tracked in #569. Whether the store rewrites the digits when a series is converted remains unmeasured.

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

#### Scenario: The shown day takes precedence

- **WHEN** the same Los Angeles all-day occurrence was moved to December 27 instead of December 30
- **THEN** December 27 passes as the shown start day even though the original-slot readings disagree

#### Scenario: A timed series' occurrence made all-day on its own

- **WHEN** the series is timed, its occurrence slot is 2026-12-28 07:00 at Asia/Taipei (`/RID=` the instant 2026-12-27 23:00 UTC), the occurrence was made all-day on its own and moved to 2026-12-30, and the host is Asia/Taipei
- **THEN** 2026-12-28 is accepted and 2026-12-27 is refused, as digits that are not 00:00 UTC are read as an instant

#### Scenario: Only the external identifier carries a recurrence ID

- **WHEN** an all-day occurrence's `/RID=` is 2026-12-28 00:00 UTC on its external identifier only and it was moved to 2026-12-30
- **THEN** on a host at Asia/Taipei or UTC 2026-12-28 is accepted; on a host at America/Los_Angeles 2026-12-27 and 2026-12-28 are refused with the ambiguous-original-day reason, and 2026-12-30 is accepted

#### Scenario: A host that skipped the day

- **WHEN** the host is Pacific/Apia, an occurrence with the UTC recurrence ID 2011-12-30T00:00:00Z is moved to 2012-01-02, and the request is read in UTC
- **THEN** for an all-day occurrence, 2011-12-29 is undetermined, the exact recurrence instant 2011-12-30T00:00:00Z matches through instant equality and the UTC civil date, and 2011-12-30T09:00:00Z is undetermined. For a timed occurrence in UTC, 2011-12-30T09:00:00Z passes both day comparisons. In both cases 2011-12-31 is unrelated. These are matcher inputs and do not specify how a date-only request for a skipped day parses in Apia.

#### Scenario: A moved timed occurrence with wall-clock digits at midnight

- **WHEN** a floating timed occurrence originally at 00:00 on 2026-12-28 in the host zone is moved on its own to 2026-12-30, retains a midnight UTC recurrence ID for the 28th, and has no zone on an America/Los_Angeles host
- **THEN** the 27th and 28th are refused as undetermined, with the refusal giving 2026-12-30 as the shown start day

#### Scenario: Every cell against main

- **WHEN** the cell tests compare main with the current matcher across host zones, series encodings and occurrence states
- **THEN** the current matcher accepts no additional dates. Previously accepted dates are refused only for midnight UTC recurrence IDs where the readings disagree and the shown-start check fails.
