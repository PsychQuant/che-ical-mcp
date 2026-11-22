## MODIFIED Requirements

### Requirement: An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo

An occurrence edited on its own may carry its original time after `/RID=` in its event identifier or external identifier. If neither supplies a readable RID, the slot reader falls back to the occurrence date or start. Measured on iCloud (#539), when the occurrence was edited while its timed series had no time zone that time is wall-clock time written as UTC; otherwise it is an instant, and one series can hold both. Every undo SHALL read that time as `main` before #539 reads it (as an instant; an all-day one as its local day): the undo of a whole-series delete, with its capture, restore, consistency check, placement of one-off events, removal of surplus slots and counts, and the check of #321 whether a restored series holds the slot of a deleted occurrence, in the undo of one occurrence's delete and of a split move's source. PR #558 read the time both ways in rounds 0 to 4, in the whole-series undo and then in the check of #321, and each verify round found a shape in which that did worse than `main`. On a host not at offset 0, the record of an occurrence edited while its series had no time zone is then usually no slot of the recreated series, and the undo applies none of the series' exceptions and says the recorded exceptions did not match; in some shapes the record is a slot and is applied, and in some the calendar after the undo has two events at one start. These are `main`'s results; #539 stays open for them.

A whole-series delete SHALL use its own recorded capture for the forecast without additional store reads. It SHALL parse the forecast anchor and expand the rule only for a recorded whole-series delete and only after any structural batch refusal has been accounted for. When it records a whole-series delete, it SHALL report an `undo_note` with the count of captured edits absent from the predicted restore listings, provided the forecast can model those listings and the count is positive. A real `delete_events_batch` SHALL give it in `rules_alone_on_undo` and omit all forecast rows if the batch includes a recorded delete of an occurrence and the following ones that makes the batch undo refuse. The forecast is computed from the recurrence rule. The store may list different slots at undo. The undo itself SHALL check the actual recreated series with the listed occurrences' occurrence dates or starts before attempting exception writes.

The forecast SHALL model each recorded window from a proven stored first slot, positive finite duration, and one simple daily or weekly rule in an unchanged recurrence time zone at undo. A weekly rule with more than one distinct weekday is outside the model. The 20,000-slot limit applies to expansion from the first slot to one second past the last recorded window, before filtering to those windows. The projection SHALL exclude a start exactly at the window end and abstain within one second of that edge when the times differ. Uncertain window starts, overlapping end times at the window start and rule starts on the local rule-end day also cause abstention. The forecast SHALL compare the in-window anchor and kept slots before counting absent edit slots. Other reasons it can abstain include a stand-in or unproven first slot, failed capture or no detached record, an unfollowed rule, an offset change and a kept slot absent from the projection. A delete without the note can still come back from its rules alone.

With span `all`, a batch dry run SHALL use the existing requested-ID state to answer each ordinary preview row and separate series identities to decide whether to forecast. A forecast key keeps the identifier through the part before `/RID=`, or the whole identifier when that marker is absent. The preview SHALL skip a forecast after a successful earlier row of the same series or after a successful earlier row whose series cannot be identified. A requested ID that differs from the resolved ID without an external identifier tying the row to a series counts as unknown, as does the first-edited-occurrence deletion route. The preview SHALL decide from the event, capture windows and call state whether to admit a forecast capture, and admit at most 16 additional store listings per call for that purpose. A later delete may use a differently placed capture window. A dry run with span `future` gives no forecast.

#### Scenario: A floating edit comes back as on main

- **WHEN** a weekly timed series has no time zone, a later occurrence is retitled and another later occurrence is moved and both edits are captured using the slots as recorded, then the whole-series delete is undone
- **THEN** the undo leaves the calendar and answer `main`'s run of the same sequence leaves: if the instant reading leaves either record off the recreated rule, the series comes back from its rules and the undo text says the recorded exceptions did not match; when both records match listed slots and the capture passes the consistency check, undo attempts to restore matching edits as one-off events, skipping edits at the recreated first slot and applying the existing rollback handling if a write fails

##### Example: a floating edit comes back as on main

- **GIVEN** six weekly occurrences at 10:00 in each of `Asia/Taipei`, `America/Los_Angeles` and `UTC`, the third retitled and the fourth moved an hour while the series had no time zone
- **WHEN** the whole series is deleted and the delete is undone, through this server and through `main`
- **THEN** both leave the same calendar and answer: at `Asia/Taipei` and `America/Los_Angeles` the outcome is not applied and the six slots are back; at `UTC` it is restored with exceptions, 0 stayed deleted and 2 one-off events

##### Example: H1

- **GIVEN** a host at `+08:00`, a daily series at 06:00 with no time zone, its second occurrence retitled, the whole series then moved one day later, and the new first occurrence deleted on its own, the series object refreshing
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the calendar and the answer are `main`'s

#### Scenario: A series with a time zone is read as before

- **WHEN** a series has a time zone, one occurrence is retitled, the whole series is moved later the same day, and the series is deleted whole and the delete undone, or the retitled occurrence is deleted through its own identifier and that delete undone
- **THEN** the identifier is read as an instant only, and the undo does what it does on `main`

##### Example: S1

- **GIVEN** a host at `Asia/Taipei` and a daily series at 06:00 with time zone `Asia/Taipei`, its second occurrence retitled, then the whole series moved to 22:00 the same day
- **WHEN** the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules alone with all six occurrences, and the undo text says the recorded exceptions did not match

#### Scenario: An edit made while the series had its zone

- **WHEN** a later occurrence is retitled while its series has a time zone, the zone is then cleared without changing the generated slots, another later occurrence is deleted on its own, and the whole-series delete is undone with both slots within the recorded window and the capture passing the consistency check
- **THEN** the edit comes back as a one-off event and the deleted occurrence stays deleted, as on `main`

#### Scenario: The undo of an occurrence's delete after its series was restored

- **WHEN** an occurrence edited on its own was deleted, the whole series was deleted and restored, and the occurrence's delete is undone
- **THEN** the calendar and both answers, outcomes and texts, are those of `main`'s run of the same sequence

##### Example: C1 the older record writes its edit as on main

- **GIVEN** a weekly series with a time zone, its second and fourth occurrences retitled, its zone then cleared at the same times, the second deleted through its own identifier, then the whole series deleted, on a host at `+08:00`, `-08:00`, `+05:45` or UTC
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s: the series comes back with the fourth as a one-off and the second's slot empty, and the second undo writes the second occurrence once with its edit

##### Example: C1 no second event after a move

- **GIVEN** the same series moved three hours later after the second occurrence was edited and before the fourth was, then given no time zone, the second deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s, with no two events at one start

##### Example: MA is as on main

- **GIVEN** the second and fourth occurrences of a weekly series edited while it had no time zone, the second deleted through its own identifier, then the whole series deleted, on a host at `+08:00`, `-08:00`, `+05:45` or UTC
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s: away from offset 0 two events at the second occurrence's start, `main`'s own; at UTC one

#### Scenario: The delete forecasts a restore from the rules alone

- **WHEN** the delete records a whole series and its captured edit has a slot absent from the eligible model of the restore listings, with in-window anchor and kept slots accounted for
- **THEN** the answer forecasts that undo applies none of the recorded exceptions, with the count, and a real batch lists the series row in `rules_alone_on_undo` unless a recorded structural refusal suppresses the batch's forecast
- **AND** an eligible span `all` preview shows the note in the series row and in returned date-range rows that inherit its answer

##### Example: the delete forecasts a floating edit

- **GIVEN** six weekly occurrences at 10:00 before any offset change, its first slot proven, the third retitled and the fourth moved while the series had no time zone, both edits captured inside the modelled window
- **WHEN** the whole series is deleted
- **THEN** the forecast counts both edits at `Asia/Taipei` and `America/Los_Angeles`, and gives no note at UTC

##### Example: the dry run skips a series after deleting its edited first occurrence

- **GIVEN** a batch preview names the first edited occurrence and its series, and the requested ID for the occurrence resolves to a different ID
- **WHEN** the first row previews a deletion and the ordinary series preview picks a stand-in as on main
- **THEN** the series row keeps the ordinary preview answer and the forecast reads no capture for it

##### Example: the dry run identifies an opaque occurrence by its external identifier

- **GIVEN** a preview's earlier deleting row has an opaque occurrence ID and an external identifier shared with the series through its RID suffix
- **WHEN** the preview reaches the series and an unrelated series
- **THEN** it skips the earlier row's series and can forecast the unrelated one

##### Example: the dry run skips later forecasts after an unidentified earlier row

- **GIVEN** a preview's earlier deleting row was requested by a RID from an old series identifier but resolved to a different identifier without an external series key
- **WHEN** the preview reaches later rows
- **THEN** those rows still have their ordinary preview answers and no forecast is attempted

##### Example: the daily rule starts exactly at the window end

- **GIVEN** a simple open daily rule with a stable offset and a projected start exactly at the end of the delete window
- **WHEN** the forecast checks the projected listing
- **THEN** it excludes that start and can count the missing slot of an edited occurrence within the window
