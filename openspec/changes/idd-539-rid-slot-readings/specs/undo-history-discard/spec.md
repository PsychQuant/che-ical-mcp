## ADDED Requirements

### Requirement: An edited occurrence's recorded slot is read both ways

The identifier of an occurrence edited on its own carries its original time after `/RID=`. When the occurrence was edited while its timed series had no time zone, that time is wall-clock time written as UTC; otherwise it is an instant. The server SHALL read a timed `/RID=` both ways, as an instant and as wall-clock time in the host's time zone, and SHALL use a reading only once it falls on a slot of the series: exactly one of the readings is a slot. An all-day occurrence, and an occurrence without a `/RID=`, SHALL keep the one reading the server used before this requirement.

For the undo of a whole-series delete the server SHALL record an edited occurrence when either reading is inside a recorded window, and SHALL place each recorded edited occurrence among the occurrences of the recreated series (listed over the windows and, when a reading lies outside them, 14 hours beyond each window). An occurrence placed outside every window SHALL be left to the series' rule. When one recorded edited occurrence cannot be placed (neither reading or both readings fall on a slot), the server SHALL apply none of the series' exceptions.

For the undo of the delete of one occurrence, the check whether the restored series already holds the occurrence's slot SHALL compare every reading of the occurrence with every reading of each occurrence of the same series (or of a series an undo recreated from it), and SHALL NOT count an occurrence of another series.

Before a whole-series delete removes anything, the server SHALL place each recorded edited occurrence on the slots the series' rule gives, expanded from the series' first slot to 14 hours past the last recorded window. When at least one cannot be placed (neither reading or both readings fall on a slot), and the delete is recorded as a whole-series delete, the delete's answer SHALL carry an `undo_note` saying that undo is expected to bring the series back from its rules alone, with the count. The note is a forecast: the restore still places against the recreated series. The server SHALL NOT write the note when the first slot cannot be shown (the series was reached through a stand-in, or its first occurrence was edited on its own), when the series has more than one rule or a rule the expander does not follow, when the expander would take more slots than its limit, or when the call's undo would be refused as a whole (a `delete_events_batch` call that also deleted an occurrence and the following ones). The delete SHALL NOT be refused for it.

#### Scenario: A floating edit comes back

- **WHEN** a weekly series is given no time zone, one occurrence is retitled and another moved, the series is deleted whole and the delete is undone
- **THEN** the series comes back from its rules and both edited occurrences come back as one-off events

##### Example: the two readings of an identifier

- **GIVEN** a host at `Asia/Taipei` and an occurrence of 2027-02-25 10:00 local edited while its series had no time zone, whose identifier ends `/RID=` with the seconds of 2027-02-25T10:00:00Z
- **WHEN** its readings are taken
- **THEN** they are 2027-02-25T10:00:00Z and 2027-02-25T02:00:00Z, and the second is the one placed on the series' slot

##### Example: a floating edit comes back

- **GIVEN** six weekly occurrences at 10:00 in each of `Asia/Taipei`, `America/Los_Angeles` and `UTC`, the third retitled and the fourth moved an hour while the series had no time zone
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the outcome is restored with exceptions, 0 stayed deleted and 2 one-off events

#### Scenario: One record that cannot be placed

- **WHEN** a recorded edited occurrence has no reading, or two readings, on a slot of the recreated series
- **THEN** none of the series' exceptions is applied and the undo text says the record did not match

#### Scenario: The undo of an occurrence's delete after its series was restored

- **WHEN** an occurrence edited while its series had no time zone was deleted, the whole series was deleted and restored, and the occurrence's delete is undone
- **THEN** one event is at the occurrence's time: the occurrence is written when the restored series does not hold its slot, and nothing is written when it does

##### Example: MA writes one event

- **GIVEN** the third and fifth occurrences edited while the series had no time zone, the third deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the third occurrence's delete
- **THEN** the second undo writes one one-off event and the store holds one event at the third occurrence's time

#### Scenario: The delete forecasts a restore from the rules alone

- **WHEN** a whole series is deleted while one of its recorded edited occurrences falls on no slot of the rule expanded from its first slot
- **THEN** the series is deleted and the answer's `undo_note` says undo is expected to bring it back from its rules alone; in `delete_events_batch` the note is in the row of that series, and a dry run with span `all` carries it in the row before anything is deleted

##### Example: no note once the edit is placed

- **GIVEN** the six weekly occurrences of the example above, the third retitled and the fourth moved while the series had no time zone
- **WHEN** the whole series is deleted
- **THEN** both records are placed on the rule's slots, the count is 0, and the answer has no `undo_note`
