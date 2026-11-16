## ADDED Requirements

### Requirement: Records follow an item the undo of its delete recreated

The undo of a delete writes a new item from the record's snapshot, and the store gives it a new identifier. The `.deleteEvent` and `.deleteReminder` records SHALL hold the identifier the removed item had (for an event with rules, the series' identifier without a `/RID=` part). After the undo of such a record wrote the new item, the server SHALL move every undo and redo record that names the removed identifier to the new identifier, in the cases of this closed list and in no other:

1. the undo of a one-off event's delete, when the event was written;
2. the undo of a whole series' delete, when the series was recreated from its rules alone, or with its recorded exceptions and no occurrence edited on its own came back as a separate event;
3. the undo of a reminder's delete, when the save returned (a save that threw but that a new store finds counts as returned);
4. each member of a batch undo, by the three cases above, right after that member was written.

In every case both identifiers SHALL be non-empty and differ. The undo of one occurrence's delete, of a move that split one occurrence out, of the rule-less record of one occurrence, and of a move that fell back to copy and delete SHALL NOT move records. A failed undo, a series whose exceptions failed and was rolled back, and an occurrence whose slot its series already holds SHALL NOT move records. The identifier a delete record holds names an item that no longer exists and SHALL never be rewritten. Event records and reminder records SHALL be rewritten separately: an event identifier never rewrites a reminder record, nor the reverse. The undo of a reminder's delete SHALL end its answer with ` (new ID: <id>)` before the note on fields the store holds differently.

When the undo of a whole series' delete brought at least one occurrence edited on its own back as a separate event, no record SHALL follow. The server SHALL instead flag every undo and redo record that names the removed series (delete records excepted); the flag SHALL belong to the record, survive every operation that keeps the record, and go when the record goes. When at least one record was flagged, the delete's undo SHALL end with: `Older undo entries of this series were not moved to the recreated series, because <n> of its occurrences that had been edited on their own came back as separate events. An undo of those entries will answer that; they can only be given up with discard_id.` The undo of a flagged record that is not found SHALL answer, in place of the generic not-found: `Cannot undo: the recurring event '<title>' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names is not the one that exists now. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.` Neither text SHALL hold an identifier, a calendar or account name, a date, or any title but the entry's own recorded title, shown as undo texts show titles.

#### Scenario: A one-off event's create record follows its delete's undo

- **WHEN** `create_event`, `delete_event` and `undo` ran, and the event reads back under a new identifier
- **THEN** the create record names the new identifier, and the next undo removes the recreated event

##### Example: the closed list of the follow rule

| Removed | New | Occurrence record | Outcome | Follow to |
|---|---|---|---|---|
| `A` | `B` | no | none (one-off) | `B` |
| `S` | `T` | no | series from rules | `T` |
| `S` | `T` | no | series with exceptions, 0 separate events | `T` |
| `S` | `T` | no | series with exceptions, 1 separate event | none |
| `A` | `B` | yes | occurrence one-off | none |
| `A` | none | no | slot already held | none |
| empty | `B` | no | none | none |
| `A` | `A` | no | none | none |

#### Scenario: A series whose edited occurrences came back as separate events is not followed

- **WHEN** a series with an occurrence edited on its own was created in this session, deleted whole, and the delete was undone
- **THEN** the create record keeps its identifier and is flagged, the delete's undo ends with the sentence above, and the create record's undo, not found, answers the flagged text, writes nothing and stays on top

##### Example: the flag goes with its entry

- **GIVEN** a flagged create record on top of the undo stack
- **WHEN** it is discarded with `discard_id` and undo runs again
- **THEN** the record under it, which carries no flag, answers the generic not-found when it is not found

#### Scenario: An occurrence's delete is not followed

- **WHEN** the undo of `.deleteOccurrence` or of a split move writes the occurrence as a one-off event
- **THEN** no record is rewritten: the series' records keep naming the series

#### Scenario: A reminder's create record follows its delete's undo

- **WHEN** `create_reminder`, `delete_reminder` and `undo` ran
- **THEN** the undo's answer ends with ` (new ID: <id>)`, the create record names that identifier, and the next undo removes the recreated reminder

##### Example: the reminder rewrite and the event rewrite stay apart

- **GIVEN** a create-reminder record and a create-event record that both name `X`, and a delete-reminder record that holds `X`
- **WHEN** the reminder identifier `X` is replaced by `Y`
- **THEN** the create-reminder record names `Y`, the create-event record and the delete-reminder record still hold `X`

#### Scenario: A batch follows member by member

- **WHEN** the undo of a batch delete restores its members, or stops part-way
- **THEN** each restored member's older records name its new identifier, and the members not restored keep their records and identifiers

## MODIFIED Requirements

### Requirement: Records follow an identifier this server's calendar change gave

Among the writes that change an event's calendar, only the writes of this server listed here SHALL move records: an in-place move of `move_events_batch` and the undo of that move; `update_event` when all five conditions below hold; and the undo of an `update_event` on a one-off event, with or without `keep_later_edits`. The undo of a delete moves records under the requirement "Records follow an item the undo of its delete recreated", and under no other rule. When one of these writes moves an event to another calendar and the store gives the event a new identifier, the server SHALL move every undo and redo record that names the event by its old identifier to the new one, so that an older record still finds the event. Any other write that gives an event a new identifier SHALL NOT move records. One such write is `update_event` with span `future` from the series' first occurrence and `calendar_name`: it fails condition 2, so no record follows, although within a Google account it moved the whole series under a new identifier and the undo of the series' creation then answered not found (#551). A removed identifier held by a delete record SHALL NOT be touched. The identifier comparison SHALL treat a series identifier and an occurrence identifier of that same series as the same identifier, and SHALL treat an empty identifier as no change.

For `update_event` the server SHALL rewrite only when all of the following hold, and SHALL NOT rewrite for a new identifier that has any other cause:

1. the call changed the calendar (it named a calendar that is not the one the event was in);
2. the call wrote the whole event (the event did not repeat, or span `all` was asked);
3. the identifier was not resolved through the stand-in of a series whose first occurrence was deleted;
4. the identifier is not the own identifier of one occurrence;
5. the identifier after the save differs from the identifier the call named.

The undo of an `update_event` on a one-off event, with or without `keep_later_edits`, SHALL compare the record's identifier with the event's identifier after its save. When they differ it SHALL move the older records as above and SHALL end its answer with the new identifier in the form ` (new ID: <id>)`. When they do not differ the answer SHALL be the text it was before this requirement.

#### Scenario: In-place move and its undo

- **WHEN** `move_events_batch` moves an event in place and the event reads back under another identifier, or the undo of that move does
- **THEN** every older record of the event names the new identifier, and the undo's answer gives the new identifier

##### Example: a move and its undo call the rewrite

- **GIVEN** the source of `EventKitManager.moveEvent` and of the `.moveEvent` undo arm
- **WHEN** the identifier after the save differs from the one before it
- **THEN** both call `CalendarUndoManager.replaceEventIdentifier` with the old and the new identifier, and the undo arm's answer ends with `(new ID: <id>)`

#### Scenario: Calendar update of a one-off event or of a whole series

- **WHEN** `update_event` with `calendar_name` moves a one-off event, or a whole series with span `all`, to another calendar and the identifier after the save differs
- **THEN** every older record of the event names the new identifier before this update's own record is added

##### Example: the five conditions of the forward rewrite

| Changed calendar | Whole event | Through the stand-in | Occurrence's own identifier | Requested → saved | Rewrite to |
|---|---|---|---|---|---|
| yes | yes | no | no | `A` → `B` | `B` |
| no | yes | no | no | `A` → `B` | none |
| yes | no | no | no | `A` → `B` | none |
| yes | yes | yes | no | `A` → `B` | none |
| yes | yes | no | yes | `S/RID=1` → `T/RID=1` | none |
| yes | yes | no | no | `A` → `A` | none |
| yes | yes | no | no | `A` → empty | none |
| yes | yes | no | no | `S` → `S/RID=1` | none |

##### Example: older create and update records follow one rewrite

- **GIVEN** an undo stack holding a create record and an update record that both name `old`, and a create record of another event that names `other`
- **WHEN** `old` is replaced by `new`
- **THEN** the two records name `new`, the third still names `other`, and the history entries keep their ids and their order

#### Scenario: A split is not followed

- **WHEN** `update_event` with span `future` starts a new series from an occurrence or, from the series' first occurrence with `calendar_name`, moves the whole series (#551), or an `update_event` write goes through an occurrence's own identifier or the stand-in
- **THEN** no record is rewritten, whatever identifier the save returns

##### Example: the saved object is picked in three branches

- **GIVEN** the source of `EventKitManager.updateEvent`
- **WHEN** it picks the object it saves
- **THEN** it assigns the resolved object for an event that does not repeat and for span `all`, and an occurrence found by `occurrence_date` otherwise, and the rewrite is asked with `wholeEvent` equal to `!hadRules || applyToAll`

#### Scenario: Undo of a calendar update reports the new identifier

- **WHEN** the undo of an `update_event` on a one-off event restores the calendar and the event reads back under another identifier
- **THEN** every older record and the redo stack name the new identifier, and the answer is `Undone: restored event '<title>' to previous state (new ID: <id>)`

##### Example: the answer of an update's undo with and without a new identifier

| Title | New identifier | Answer |
|---|---|---|
| `Standup` | none | `Undone: restored event 'Standup' to previous state` |
| `Standup` | `NEW-1` | `Undone: restored event 'Standup' to previous state (new ID: NEW-1)` |

#### Scenario: Undo with keep_later_edits reports the new identifier

- **WHEN** `undo` with `keep_later_edits` restores the calendar of a one-off event and the event reads back under another identifier
- **THEN** every older record and the redo stack name the new identifier, and the answer is the merge's text followed by ` (new ID: <id>)`

##### Example: the merge answer with a new identifier

- **GIVEN** a merge that restored `calendar` and kept the later edit to `title`, on an event titled `Standup`
- **WHEN** the event reads back as `NEW-1`
- **THEN** the answer is `Undone: restored event 'Standup' in calendar; kept the later edits to title (new ID: NEW-1)`, and without a new identifier it is the same text without the suffix

#### Scenario: A record popped to the redo stack follows

- **WHEN** an undo changes the identifier after its own record was moved to the redo stack
- **THEN** the redo stack names the new identifier too

##### Example: an update record on the redo stack follows

- **GIVEN** an update record naming `moved` that was popped to the redo stack
- **WHEN** `moved` is replaced by `restored`
- **THEN** the record on the redo stack names `restored`
