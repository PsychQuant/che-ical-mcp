## MODIFIED Requirements

### Requirement: An edited occurrence's recorded slot is read both ways

The identifier of an occurrence edited on its own carries its original time after `/RID=`. Measured on iCloud (#539), when the occurrence was edited while its timed series had no time zone that time is wall-clock time written as UTC; otherwise it is an instant. Three readers of this server SHALL read a timed `/RID=` both ways, as an instant and as wall-clock time in the host's time zone: the undo of a whole-series delete, the check whether a restored series holds a deleted occurrence's slot, and the forecast at a whole-series delete. They SHALL take the wall-clock reading only for an occurrence of a series that has no time zone when it is read: at the capture for the delete's record, the series object; for a deleted or moved occurrence's origin, the series of the event the delete or move resolved: that event itself when it was reached through the series' identifier, and the series object stored under the part before `/RID=` when the occurrence was addressed by its own identifier; when that series object cannot be read, the origin SHALL take the instant reading alone. An occurrence of a series that has a time zone, an all-day occurrence and an occurrence without a `/RID=` SHALL keep the one reading the server used before #539, and the capture, the placement and the slot check for them SHALL be the ones before #539 (the forecast at the delete below applies to them too). The other readers of a `/RID=` (the #503 check, #553; the create-undo check, #416's weekday check and the #509 rule-end check, #557) read the instant only.

For the undo of a whole-series delete the server SHALL record an edited occurrence when either reading is inside a recorded window, and SHALL place each recorded edited occurrence of two readings among the occurrences of the recreated series (listed over the windows and, when a reading lies outside them, 14 hours beyond each window): it is placed on the one reading that is a slot. The server SHALL apply none of the series' exceptions when one such record cannot be placed: neither or both readings are slots; the slot it would be placed on held an occurrence that was not edited on its own when the delete was recorded; it would be placed outside every window; or another record would be placed on its slot. A record of one reading SHALL NOT be the reason nothing is applied: it is kept on its one reading, and two records of one reading on one slot are left as they were before #539. With at least one record of two readings, the server SHALL also apply none of the series' exceptions when the delete reached the series through a stand-in (the series object did not refresh, so the earliest plain occurrence left stood in for it), or when the recreated series' first slot lies inside a recorded window and held no occurrence that was not edited on its own when the delete was recorded (it was deleted or edited on its own); the restore keeps the first slot from the rule whatever a record says, and the undo's text SHALL say that the series' first occurrence was not a plain occurrence when it was deleted. A first slot outside every window is not asked. When a placed record's own end is before its start as this process reads it (its wall-clock times fall across a daylight-saving gap of this Mac's time zone), whatever its number of readings, no one-off event can be saved for it, and the server SHALL apply none of the series' exceptions and SHALL say so in the undo's text.

For the undo of the delete of one occurrence (and of a split move's source), the check whether the restored series already holds the occurrence's slot SHALL count only occurrences of the same series or of a series an undo recreated from it, and SHALL compare an occurrence edited on its own by its instant reading only. When such an occurrence is at the instant reading of the deleted occurrence's slot, the slot is held: nothing is written and the record is used up, as before #539. When only an occurrence not edited on its own is at the deleted occurrence's wall-clock reading, the server SHALL write nothing, SHALL refuse the undo and SHALL keep the record, with a text that says the series holds an occurrence at that time as this Mac's time zone reads the recorded time, that this server cannot tell whether it is the deleted occurrence's slot, and that the entry can be given up with `discard_id`. Otherwise the occurrence is written as a one-off event.

Before a whole-series delete removes anything, the server SHALL place each recorded edited occurrence on the slots the series' rule gives, expanded from the series' first slot to 14 hours past the last recorded window, with the rules of the restore above; when the first-slot condition of the restore above holds (asked with the start the recreated series takes), every recorded edited occurrence is counted, without the expander. When at least one record cannot be placed, and the delete is recorded as a whole-series delete, the delete's answer SHALL carry an `undo_note` saying that undo is expected to bring the series back from its rules alone, with the count; in a real `delete_events_batch` call the note is in its `rules_alone_on_undo` list. The note is a forecast: the restore still places against the recreated series. The note SHALL NOT count a record that is placed but ends before it starts. Otherwise the server SHALL NOT write the note when the first slot cannot be shown (for example the series was reached through a stand-in, or its first occurrence was edited or deleted on its own), when the series has more than one rule or a rule the expander does not follow, when the expander would take more slots than its limit, when an occurrence not edited on its own that the delete recorded is no slot of the expander, or when the call's undo would be refused as a whole (a row of a `delete_events_batch` call recorded as deleting an occurrence and the following ones). The delete SHALL NOT be refused for it.

#### Scenario: A floating edit comes back

- **WHEN** a weekly series is given no time zone, one occurrence is retitled and another moved, the series is deleted whole and the delete is undone
- **THEN** the series comes back from its rules and both edited occurrences come back as one-off events

##### Example: the two readings of an identifier

- **GIVEN** a host at `Asia/Taipei` and an occurrence of 2027-02-25 10:00 local edited while its series had no time zone, whose identifier ends `/RID=` with the seconds of 2027-02-25T10:00:00Z
- **WHEN** its readings are taken and placed among the weekly slots at 10:00 local
- **THEN** they are 2027-02-25T10:00:00Z and 2027-02-25T02:00:00Z, and the second is the one placed on the series' slot

##### Example: a floating edit comes back

- **GIVEN** six weekly occurrences at 10:00 in each of `Asia/Taipei`, `America/Los_Angeles` and `UTC`, the third retitled and the fourth moved an hour while the series had no time zone
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the outcome is restored with exceptions, 0 stayed deleted and 2 one-off events

#### Scenario: A series with a time zone is read as before

- **WHEN** a series has a time zone, one occurrence is retitled, the whole series is moved later the same day, and the series is deleted whole and the delete undone, or the retitled occurrence is deleted through its own identifier and that delete undone
- **THEN** the identifier is read as an instant only, and the undo does what it did before #539

##### Example: S1

- **GIVEN** a host at `Asia/Taipei` and a daily series at 06:00 with time zone `Asia/Taipei`, its second occurrence retitled, then the whole series moved to 22:00 the same day
- **WHEN** the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules alone with all six occurrences, and the undo text says the recorded exceptions did not match

#### Scenario: One record that cannot be placed

- **WHEN** a recorded edited occurrence of two readings has no reading, or two readings, on a slot of the recreated series, is placed on a slot that held an occurrence not edited on its own, is placed outside every window, or is placed on the slot of another record
- **THEN** none of the series' exceptions is applied and the undo text says the record did not match

#### Scenario: The series' first occurrence is not plain

- **WHEN** a series with no time zone holds an occurrence edited on its own whose recorded time has two readings, its first occurrence was deleted or edited on its own (or the delete reached it through a stand-in), and the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules alone, none of its exceptions is applied, the undo text says the first occurrence was not a plain occurrence, and the delete's answer carries an `undo_note` counting every recorded edited occurrence

##### Example: the first slot stops the restore

- **GIVEN** six daily slots at 06:00 `Asia/Taipei` and a record of two readings on the fourth slot
- **WHEN** the condition is asked with the series' first slot as the recreated series' start
- **THEN** it holds when the first slot is not a kept slot inside the window, and when the record says the delete went through a stand-in; it does not hold for a plain first slot, for a first slot outside the window, or when the only record has one reading

##### Example: H1

- **GIVEN** a host at `+08:00`, a daily series at 06:00 with no time zone, its second occurrence retitled, the whole series then moved one day later, and the new first occurrence deleted on its own, the series object refreshing
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the series comes back from its rules alone and no occurrence is lost or doubled

#### Scenario: The undo of an occurrence's delete after its series was restored

- **WHEN** an occurrence edited while its series had no time zone was deleted, the whole series was deleted and restored, and the occurrence's delete is undone
- **THEN** one event is at the occurrence's time: the occurrence is written when the restored series does not hold its slot, and when the restored series has an occurrence not edited on its own at its wall-clock reading the undo is refused, nothing is written, and the entry stays in the history

##### Example: MA writes one event

- **GIVEN** the third and fifth occurrences edited while the series had no time zone, the third deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the third occurrence's delete
- **THEN** the second undo writes one one-off event and the store holds one event at the third occurrence's time

##### Example: the restored series holds the wall-clock reading

- **GIVEN** a host at `Asia/Taipei`, a weekly series at 10:00 with no time zone, its third occurrence retitled and deleted through its own identifier, and the series recreated from its rules with a plain occurrence at the third slot
- **WHEN** the third occurrence's delete is undone
- **THEN** the undo is refused with the text naming `discard_id`, nothing is written, and the record is kept

#### Scenario: The delete forecasts a restore from the rules alone

- **WHEN** a whole series is deleted while one of its recorded edited occurrences cannot be placed on the rule expanded from its first slot
- **THEN** the series is deleted and the answer's `undo_note` says undo is expected to bring it back from its rules alone; in a `delete_events_batch` call the series' row is listed in `rules_alone_on_undo`, and a dry run with span `all` carries the note in the series' row (by date range, in the row of every listed occurrence of that series) before anything is deleted

##### Example: no note once the edit is placed

- **GIVEN** the six weekly occurrences of the example above, the third retitled and the fourth moved while the series had no time zone
- **WHEN** the whole series is deleted
- **THEN** both records are placed on the rule's slots, the count is 0, and the answer has no `undo_note`

#### Scenario: A placed edit that ends before it starts

- **WHEN** a floating series' edited occurrence falls in the spring gap of this Mac's time zone, is listed ending before it starts, and the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules, none of its exceptions is applied, and the undo text says that an occurrence edited on its own ends before it starts; the delete's answer has no `undo_note` for it

##### Example: DS1

- **GIVEN** a host at `America/Los_Angeles`, a weekly series at 02:30 for 30 minutes with no time zone, its occurrence of 2027-03-14 retitled and listed from 03:30 to 03:00 PDT
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the outcome is not applied, with the cause that the occurrence ends before it starts, and the series' six slots are back
