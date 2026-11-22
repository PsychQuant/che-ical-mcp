## RENAMED Requirements

- FROM: `### Requirement: An edited occurrence's recorded slot is read both ways`
- TO: `### Requirement: An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo`

## MODIFIED Requirements

### Requirement: An edited occurrence's recorded slot is read both ways

The identifier of an occurrence edited on its own carries its original time after `/RID=`. Measured on iCloud (#539), when the occurrence was edited while its timed series had no time zone that time is wall-clock time written as UTC; otherwise it is an instant, and one series can hold both. Every undo SHALL read that time as `main` before #539 reads it (as an instant; an all-day one as its local day): the undo of a whole-series delete, with its capture, restore, consistency check, placement of one-off events, removal of surplus slots and counts, and the check of #321 whether a restored series holds the slot of a deleted occurrence, in the undo of one occurrence's delete and of a split move's source. PR #558 read the time both ways in rounds 0 to 4, in the whole-series undo and then in the check of #321, and each verify round found a shape in which that did worse than `main`. On a host not at offset 0, the record of an occurrence edited while its series had no time zone is then usually no slot of the recreated series, and the undo applies none of the series' exceptions and says the recorded exceptions did not match; in some shapes the record is a slot and is applied, and in some the calendar after the undo has two events at one start. These are `main`'s results; #539 stays open for them.

Before a whole-series delete removes anything, the server SHALL read the recorded edited occurrences and check each record's slot, read as the undo reads it, against the slots the series' rule gives, expanded from the series' first slot to the end of the last recorded window, and count those that are no slot. When the count is above 0 and the delete is recorded as a whole-series delete, the delete's answer SHALL carry an `undo_note` saying that the undo's check is expected to apply none of the exceptions recorded with the series, with the count; in a real `delete_events_batch` call the note is in its `rules_alone_on_undo` list. The note SHALL NOT say more than that check establishes: the series is expected to be recreated from its rule, with no edited occurrence written back and no slot removed. The note is a forecast of `main`'s check: the restore decides on the recreated series. A dry run with span `all` SHALL leave out of the record and of the first slot's listing the occurrences that the call's earlier rows delete, by their own event identifiers, before the record reduces an occurrence to its slot, as the real call's series row no longer lists them. The server SHALL NOT write the note when the series was reached through a stand-in or its first occurrence is not a plain occurrence at its own start (for example edited or deleted on its own, or when it cannot be shown), when the series has more than one rule or a rule the expander does not follow, when the rule gives more slots from the first slot to the end of that window than the expander takes, when an occurrence not edited on its own that the delete recorded is no slot of the expander, or when the call's undo would be refused as a whole (a row of a `delete_events_batch` call recorded as deleting an occurrence and the following ones). The delete SHALL NOT be refused for it.

#### Scenario: A floating edit comes back as on main

- **WHEN** a weekly timed series has no time zone, a later occurrence is retitled and another later occurrence is moved while both original slots are within the recorded window, then the whole-series delete is undone
- **THEN** the undo leaves the calendar and answer `main`'s run of the same sequence leaves: if the instant reading leaves either record off the recreated rule, the series comes back from its rules and the undo text says the recorded exceptions did not match; when both records match generated slots and the capture passes the consistency check, both edits come back as one-off events

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

- **WHEN** a whole series is deleted while its record holds an edit whose slot, read as an instant, is off the rule expanded from its first slot
- **THEN** the series is deleted and the answer's `undo_note` says the undo's check is expected to apply none of the recorded exceptions, with the count; in a `delete_events_batch` call the series' row is listed in `rules_alone_on_undo`, and a dry run with span `all` carries the note in the series' row (by date range, in the row of every listed occurrence of that series) before anything is deleted

##### Example: the delete forecasts a floating edit

- **GIVEN** the six weekly occurrences of the example above, the third retitled and the fourth moved while the series had no time zone
- **WHEN** the whole series is deleted
- **THEN** at `Asia/Taipei` and `America/Los_Angeles` both edits are counted; at `UTC` none is counted and the answer has no `undo_note`

##### Example: the dry run leaves out what an earlier row deletes

- **GIVEN** a series with one occurrence edited off the rule and one on its slot, and a dry run of `delete_events_batch` with span `all` naming the first one's own identifier and the series
- **WHEN** the series' row is forecast
- **THEN** the record leaves that occurrence out, as the real call's does, and the row has no note

##### Example: the dry run leaves out an opaque occurrence

- **GIVEN** the same series, the occurrence edited off the rule having an opaque identifier and its `/RID=` only in its external identifier, and the dry run naming that identifier and the series
- **WHEN** the series' row is forecast
- **THEN** the record leaves that occurrence out, as the real call's does, and the row has no note

##### Example: the dry run keeps another occurrence at the same slot

- **GIVEN** two occurrences of the series recorded at one slot off the rule, one with the series' identifier and `/RID=`, the other opaque with the same `/RID=` in its external identifier, and the dry run naming the first and the series
- **WHEN** the series' row is forecast
- **THEN** the record keeps the second, as the real call's does, and the row's note counts one
