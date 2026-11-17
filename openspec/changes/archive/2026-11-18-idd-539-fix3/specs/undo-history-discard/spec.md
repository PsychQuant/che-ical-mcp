## MODIFIED Requirements

### Requirement: An edited occurrence's recorded slot is read both ways

The identifier of an occurrence edited on its own carries its original time after `/RID=`. Measured on iCloud (#539), when the occurrence was edited while its timed series had no time zone that time is wall-clock time written as UTC; otherwise it is an instant. Three readers of this server SHALL read a timed `/RID=` both ways, as an instant and as wall-clock time in the host's time zone: the capture of a whole-series delete for its undo, the check whether a restored series holds a deleted occurrence's slot, and the forecast at a whole-series delete. They SHALL take the wall-clock reading only for an occurrence of a series that has no time zone when it is read: at the capture for the delete's record, the series object; for a deleted or moved occurrence's origin, the series of the event the delete or move resolved: that event itself when it was reached through the series' identifier, and the series object stored under the part before `/RID=` when the occurrence was addressed by its own identifier; when that series object cannot be read, the origin SHALL take the instant reading alone. When the two readings are the same instant (a host at offset 0 when the slot falls), there is one reading. An occurrence of a series that has a time zone, an all-day occurrence and an occurrence without a `/RID=` SHALL keep the one reading the server used before #539, and the capture, the restore and the slot check for them SHALL be the ones before #539 (the forecast at the delete below applies to them too). The other readers of a `/RID=` (the #503 check, #553; the create-undo check, #416's weekday check and the #509 rule-end check, #557) read the instant only.

For the undo of a whole-series delete the server SHALL record an edited occurrence when either reading is inside a recorded window. The server SHALL NOT place a record of two readings on a slot of the recreated series (PR #558 round 3: the placement of rounds 0 to 2 is withdrawn after verify rounds 1 to 3 each found a shape in which it lost an occurrence or wrote a second event). When the record holds at least one record of two readings, the server SHALL apply none of the series' exceptions: the series comes back with the occurrences its rules give, and the undo's text SHALL say that the series had no time zone and that the original slot of an occurrence of it edited on its own cannot be read reliably. A record of one reading SHALL NOT be the reason for that. Otherwise, when a record's own end is before its start as this process reads it (its wall-clock times fall across a daylight-saving gap of this Mac's time zone), no one-off event can be saved for it, and the server SHALL apply none of the series' exceptions and SHALL say so in the undo's text. The edits of a series with no time zone, read on a host not at offset 0, are therefore not restored by this undo; #539 stays open for that.

For the undo of the delete of one occurrence (and of a split move's source), the check whether the restored series already holds the occurrence's slot SHALL count only occurrences of the same series or of a series an undo recreated from it, and SHALL compare an occurrence edited on its own by its instant reading only. When such an occurrence is at the instant reading of the deleted occurrence's slot, the slot is held: nothing is written and the record is used up, as before #539. When only an occurrence not edited on its own is at the deleted occurrence's wall-clock reading, the server SHALL write nothing, SHALL refuse the undo and SHALL keep the record, with a text that says the series holds an occurrence at that time as this Mac's time zone reads the recorded time, that this server cannot tell whether it is the deleted occurrence's slot, and that the entry can be given up with `discard_id`. Otherwise the occurrence is written as a one-off event.

Before a whole-series delete removes anything, the server SHALL read the recorded edited occurrences. When the record holds a record of two readings, every recorded edited occurrence is counted, through any route the delete took, and the forecast's cause is that the series has no time zone. Otherwise the server SHALL check each record's one reading against the slots the series' rule gives, expanded from the series' first slot to the end of the last recorded window, and count those that are no slot. When the count is above 0 and the delete is recorded as a whole-series delete, the delete's answer SHALL carry an `undo_note` saying that undo is expected to bring the series back from its rules alone, with the count and the cause's reason; in a real `delete_events_batch` call the note is in its `rules_alone_on_undo` list. The note is a forecast: the restore decides on the recreated series. The note SHALL NOT count a record of one reading that is on its slot but ends before it starts. For a record with no record of two readings, the server SHALL NOT write the note when the first slot cannot be shown (for example the series was reached through a stand-in, or its first occurrence was edited or deleted on its own), when the series has more than one rule or a rule the expander does not follow, when the expander would take more slots than its limit, when an occurrence not edited on its own that the delete recorded is no slot of the expander, or when the call's undo would be refused as a whole (a row of a `delete_events_batch` call recorded as deleting an occurrence and the following ones). The delete SHALL NOT be refused for it.

#### Scenario: A floating edit comes back from the rules alone

- **WHEN** a weekly series is given no time zone, one occurrence is retitled and another moved, the series is deleted whole and the delete is undone on a host not at offset 0
- **THEN** the series comes back with the occurrences its rules give, none of the edits is applied, and the undo text says the series had no time zone and the original slot cannot be read reliably; on a host at UTC both edits come back as one-off events

##### Example: the two readings of an identifier

- **GIVEN** a host at `Asia/Taipei` and an occurrence of 2027-02-25 10:00 local edited while its series had no time zone, whose identifier ends `/RID=` with the seconds of 2027-02-25T10:00:00Z
- **WHEN** its readings are taken
- **THEN** they are 2027-02-25T10:00:00Z and 2027-02-25T02:00:00Z

##### Example: a floating edit comes back from the rules alone

- **GIVEN** six weekly occurrences at 10:00 in each of `Asia/Taipei`, `America/Los_Angeles` and `UTC`, the third retitled and the fourth moved an hour while the series had no time zone
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** at `Asia/Taipei` and `America/Los_Angeles` the outcome is not applied with the floating cause and the six slots are back; at `UTC` it is restored with exceptions, 0 stayed deleted and 2 one-off events

##### Example: a floating edit stops the restore

- **GIVEN** six daily slots at 06:00 `Asia/Taipei` and a record of two readings on the fourth slot
- **WHEN** the restore runs on a recreated series that generates every slot
- **THEN** nothing is removed or written and the outcome is not applied with the floating cause; with only a record of one reading on its slot, that record is written as a one-off

##### Example: H1

- **GIVEN** a host at `+08:00`, a daily series at 06:00 with no time zone, its second occurrence retitled, the whole series then moved one day later, and the new first occurrence deleted on its own, the series object refreshing
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the series comes back from its rules alone and no occurrence is lost or doubled

#### Scenario: A series with a time zone is read as before

- **WHEN** a series has a time zone, one occurrence is retitled, the whole series is moved later the same day, and the series is deleted whole and the delete undone, or the retitled occurrence is deleted through its own identifier and that delete undone
- **THEN** the identifier is read as an instant only, and the undo does what it did before #539

##### Example: S1

- **GIVEN** a host at `Asia/Taipei` and a daily series at 06:00 with time zone `Asia/Taipei`, its second occurrence retitled, then the whole series moved to 22:00 the same day
- **WHEN** the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules alone with all six occurrences, and the undo text says the recorded exceptions did not match

#### Scenario: The undo of an occurrence's delete after its series was restored

- **WHEN** an occurrence edited while its series had no time zone was deleted, the whole series was deleted and restored, and the occurrence's delete is undone
- **THEN** one event is at the occurrence's time: the occurrence is written when the restored series does not hold its slot, and when the restored series has an occurrence not edited on its own at its wall-clock reading the undo is refused, nothing is written, and the entry stays in the history

##### Example: MA writes one event

- **GIVEN** the third and fifth occurrences edited while the series had no time zone, the third deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the third occurrence's delete
- **THEN** on a host not at offset 0 the series comes back from its rules alone and the second undo is refused with nothing written; at UTC the second undo writes one one-off event; either way the store holds one event at the third occurrence's time

##### Example: the restored series holds the wall-clock reading

- **GIVEN** a host at `Asia/Taipei`, a weekly series at 10:00 with no time zone, its third occurrence retitled and deleted through its own identifier, and the series recreated from its rules with a plain occurrence at the third slot
- **WHEN** the third occurrence's delete is undone
- **THEN** the undo is refused with the text naming `discard_id`, nothing is written, and the record is kept

#### Scenario: The delete forecasts a restore from the rules alone

- **WHEN** a whole series is deleted while its record holds an edit of two readings, or a record of one reading off the rule expanded from its first slot
- **THEN** the series is deleted and the answer's `undo_note` says undo is expected to bring it back from its rules alone, with the cause; in a `delete_events_batch` call the series' row is listed in `rules_alone_on_undo`, and a dry run with span `all` carries the note in the series' row (by date range, in the row of every listed occurrence of that series) before anything is deleted

##### Example: the delete counts every floating edit

- **GIVEN** the six weekly occurrences of the example above, the third retitled and the fourth moved while the series had no time zone
- **WHEN** the whole series is deleted
- **THEN** at `Asia/Taipei` and `America/Los_Angeles` both edits are counted with the floating cause; at `UTC` none is counted and the answer has no `undo_note`

#### Scenario: An edit that ends before it starts

- **WHEN** a floating series' edited occurrence falls in the spring gap of this Mac's time zone, is listed ending before it starts, and the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules and none of its exceptions is applied: on a host not at offset 0 its record has two readings and the undo gives the floating reason, with the note at the delete; a record of one reading gives the text that an occurrence edited on its own ends before it starts, and no note at the delete

##### Example: DS1

- **GIVEN** a host at `America/Los_Angeles`, a weekly series at 02:30 for 30 minutes with no time zone, its occurrence of 2027-03-14 retitled and listed from 03:30 to 03:00 PDT
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the outcome is not applied with the floating cause, and the series' six slots are back
