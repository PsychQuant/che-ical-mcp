## MODIFIED Requirements

### Requirement: An edited occurrence's recorded slot is read both ways

The identifier of an occurrence edited on its own carries its original time after `/RID=`. Measured on iCloud (#539), when the occurrence was edited while its timed series had no time zone that time is wall-clock time written as UTC; otherwise it is an instant, and one series can hold both. The undo of a whole-series delete SHALL read that time as an instant, for every series, with or without a time zone, and its capture, restore, consistency check, placement of one-off events, removal of surplus slots and counts SHALL be those of `main` before #539 (PR #558 fix round 4: rounds 0 to 3 read both readings there and each verify round found a shape in which that did worse than `main`). On a host not at offset 0, an occurrence edited while its series had no time zone is then usually read at no slot of the recreated series, the undo applies none of the series' exceptions and says the recorded exceptions did not match; #539 stays open for restoring such edits.

One reader of this server SHALL read a timed `/RID=` both ways, as an instant and as wall-clock time in the host's time zone: the check whether a restored series holds a deleted occurrence's slot, for the undo of the delete of one occurrence (and of a split move's source). It SHALL take the wall-clock reading only for an occurrence of a series that has no time zone when the delete or move read it: the event the delete or move resolved, when it was reached through the series' identifier; the series object stored under the part before `/RID=`, when the occurrence was addressed by its own identifier. When that series object cannot be read, or the `/RID=` is only in the occurrence's external identifier, the origin SHALL take the instant reading alone. When the two readings are the same instant (a host at offset 0 when the slot falls) there is one reading. An all-day occurrence and an occurrence without a `/RID=` keep one reading. The check SHALL count only occurrences of the same series or of a series an undo recreated from it, and SHALL compare an occurrence edited on its own by its instant reading only. When such an occurrence is at the instant reading of the deleted occurrence's slot, the slot is held: nothing is written and the record is used up, as on `main`. When none is there and only an occurrence not edited on its own is at the deleted occurrence's wall-clock reading, the server SHALL write nothing, SHALL refuse the undo and SHALL keep the record, with a text that says the series holds an occurrence at that time as this Mac's time zone reads the recorded time, that this server cannot tell whether it is the deleted occurrence's slot, and that the entry can be given up with `discard_id`; for a split move's source the text SHALL say that the copy the move made was not looked up or touched. Otherwise the occurrence is written as a one-off event, as on `main`. What this check writes SHALL be a part of what `main`'s writes.

Before a whole-series delete removes anything, the server SHALL read the recorded edited occurrences and check each record's slot, read as the undo reads it, against the slots the series' rule gives, expanded from the series' first slot to the end of the last recorded window, and count those that are no slot. When the count is above 0 and the delete is recorded as a whole-series delete, the delete's answer SHALL carry an `undo_note` saying that undo is expected to bring the series back from its rules alone, with the count; in a real `delete_events_batch` call the note is in its `rules_alone_on_undo` list. The note is a forecast of `main`'s check: the restore decides on the recreated series. A dry run with span `all` SHALL leave out of the record and of the first slot's listing the occurrences that the call's earlier rows delete, as the real call's series row no longer sees them. The server SHALL NOT write the note when the series was reached through a stand-in or its first occurrence is not a plain occurrence at its own start (for example edited or deleted on its own, or when it cannot be shown), when the series has more than one rule or a rule the expander does not follow, when the expander would take more slots than its limit, when an occurrence not edited on its own that the delete recorded is no slot of the expander, or when the call's undo would be refused as a whole (a row of a `delete_events_batch` call recorded as deleting an occurrence and the following ones). The delete SHALL NOT be refused for it.

#### Scenario: A floating edit comes back as on main

- **WHEN** a weekly series is given no time zone, one occurrence is retitled and another moved, the series is deleted whole and the delete is undone
- **THEN** the undo leaves the calendar and answer `main`'s run of the same sequence leaves: on a host not at offset 0 the series comes back from its rules alone and the undo text says the recorded exceptions did not match; on a host at UTC both edits come back as one-off events

##### Example: the two readings of an identifier

- **GIVEN** a host at `Asia/Taipei` and an occurrence of 2027-02-25 10:00 local edited while its series had no time zone, whose identifier ends `/RID=` with the seconds of 2027-02-25T10:00:00Z
- **WHEN** its readings are taken
- **THEN** they are 2027-02-25T10:00:00Z and 2027-02-25T02:00:00Z

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

- **WHEN** an occurrence is retitled while its series has a time zone, the series' zone is then cleared without changing its times, another occurrence is deleted on its own, and the series is deleted whole and the delete undone
- **THEN** the edit comes back as a one-off event and the deleted occurrence stays deleted, in every host zone, as on `main`

#### Scenario: The undo of an occurrence's delete after its series was restored

- **WHEN** an occurrence edited on its own was deleted, the whole series was deleted and restored, and the occurrence's delete is undone
- **THEN** the occurrence is written when the restored series does not hold its slot, nothing is written when an occurrence of the series is at the slot read as an instant, and when only an occurrence not edited on its own is at its wall-clock reading the undo is refused, nothing is written, and the entry stays in the history

##### Example: C1 the older record writes its edit as on main

- **GIVEN** a weekly series with a time zone, its second and fourth occurrences retitled, its zone then cleared at the same times, the second deleted through its own identifier, then the whole series deleted, on a host at `+08:00`, `-08:00`, `+05:45` or UTC
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s: the series comes back with the fourth as a one-off and the second's slot empty, and the second undo writes the second occurrence once with its edit

##### Example: C1 no second event after a move

- **GIVEN** the same series moved three hours later after the second occurrence was edited and before the fourth was, then given no time zone, the second deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s, with no two events at one start

##### Example: MA writes one event

- **GIVEN** the third and fifth occurrences edited while the series had no time zone, the third deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the third occurrence's delete
- **THEN** the series' undo is `main`'s; on a host not at offset 0 it comes back from its rules alone and the second undo is refused with nothing written, where `main`'s wrote a second event at the third occurrence's time; at UTC the second undo writes one one-off event, as on `main`

##### Example: the restored series holds the wall-clock reading

- **GIVEN** a host at `Asia/Taipei`, a weekly series at 10:00 with no time zone, its third occurrence retitled and deleted through its own identifier, and the series recreated from its rules with a plain occurrence at the third slot
- **WHEN** the third occurrence's delete is undone
- **THEN** the undo is refused with the text naming `discard_id`, nothing is written, and the record is kept

#### Scenario: The delete forecasts a restore from the rules alone

- **WHEN** a whole series is deleted while its record holds an edit whose slot, read as an instant, is off the rule expanded from its first slot
- **THEN** the series is deleted and the answer's `undo_note` says undo is expected to bring it back from its rules alone, with the count; in a `delete_events_batch` call the series' row is listed in `rules_alone_on_undo`, and a dry run with span `all` carries the note in the series' row (by date range, in the row of every listed occurrence of that series) before anything is deleted

##### Example: the delete forecasts a floating edit

- **GIVEN** the six weekly occurrences of the example above, the third retitled and the fourth moved while the series had no time zone
- **WHEN** the whole series is deleted
- **THEN** at `Asia/Taipei` and `America/Los_Angeles` both edits are counted; at `UTC` none is counted and the answer has no `undo_note`

##### Example: the dry run leaves out what an earlier row deletes

- **GIVEN** a series with one occurrence edited off the rule and one on its slot, and a dry run of `delete_events_batch` with span `all` naming the first one's own identifier and the series
- **WHEN** the series' row is forecast
- **THEN** the record leaves that occurrence out, as the real call's does, and the row has no note
