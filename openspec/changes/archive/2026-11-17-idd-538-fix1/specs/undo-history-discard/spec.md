## MODIFIED Requirements

### Requirement: Records follow an identifier this server's calendar change gave

Among the writes that change an event's calendar, only the writes of this server listed here SHALL move records: an in-place move of `move_events_batch` and the undo of that move; `update_event` when all five conditions below hold; and the undo of an `update_event` on a one-off event, with or without `keep_later_edits`. The undo of a delete moves records under the requirement "Records follow an item the undo of its delete recreated", and under no other rule. When one of these writes moves an event to another calendar and the store gives the event a new identifier, the server SHALL move every undo and redo record that names the event by its old identifier to the new one, so that an older record still finds the event. Any other write that gives an event a new identifier, other than the undo of a delete under that requirement, SHALL NOT move records. One such write is `update_event` with span `future` from the series' first occurrence and `calendar_name`: it fails condition 2, so no record follows, although within a Google account it moved the whole series under a new identifier and the undo of the series' creation then answered not found (#551). A removed identifier held by a delete record SHALL NOT be touched. The identifier comparison SHALL treat a series identifier and an occurrence identifier of that same series as the same identifier, and SHALL treat an empty identifier as no change.

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


### Requirement: Records follow an item the undo of its delete recreated

The undo of a delete writes a new item from the record's snapshot; on iCloud the store gave it a new identifier (measured for a one-off event, a reminder and a series), and the rule below does not assume it. The `.deleteEvent` and `.deleteReminder` records SHALL hold the identifier the removed item had (for an event with rules, the series' identifier without a `/RID=` part), read before the removal, in a single delete and in every row of a batch delete. After the undo of such a record wrote the new item, the server SHALL move every undo and redo record that names the removed identifier to the new identifier, in the cases of this closed list and in no other:

1. the undo of a one-off event's delete, when the event was written;
2. the undo of a whole series' delete, when the series was recreated from its rules alone, or with its recorded exceptions and no occurrence edited on its own came back as a separate event;
3. the undo of a reminder's delete, when the save returned (a save that threw but that a new store finds counts as returned);
4. each member of a batch undo, by the three cases above, right after that member was written.

In every case both identifiers SHALL be non-empty and differ. The undo of one occurrence's delete, of a move that split one occurrence out, of the rule-less record of one occurrence, and of a move that fell back to copy and delete SHALL NOT move records. A failed undo, a series whose exceptions failed and was rolled back, and an occurrence whose slot its series already holds SHALL NOT move records. The record of a whole-series update that undo could restore (#263) SHALL NOT be moved: it was recorded against the series as it was, with its occurrences, so its undo looks up the removed identifier, answers not found and keeps the record, which `discard_id` gives up; it is flagged only in the case below. A record that names the series by the own identifier of one of its occurrences (`<series>/RID=…`: a whole-series move or an update recorded through an occurrence's own identifier, #426, #428) is neither moved nor flagged, and its undo answers the generic not-found (a stated limit). The identifier a delete record holds names an item that no longer exists and SHALL never be rewritten. Event records and reminder records SHALL be rewritten separately: an event identifier never rewrites a reminder record, nor the reverse. The undo of a reminder's delete SHALL give the new identifier, ` (new ID: <id>)`, after the title and before any note on fields the store holds differently; when the identifier reads back empty the answer has no such part. A record that follows is checked like any undo; it can be refused for fields that the recreate or this server's own later operations changed, with the comparison's text, which names another app or the calendar server (#540).

When the undo of a whole series' delete brought at least one occurrence edited on its own back as a separate event, no record SHALL follow. When the recreated series reads back under the removed identifier, nothing SHALL be flagged either: the older records still name the series that exists. Otherwise the server SHALL flag every undo and redo record that names the removed series and whose undo looks the series up: a create, an update of a one-off event, a move, a whole-series update that undo could restore, and the copy of a move by copy. A delete record, a batch, and the record of an update that touched the series and that undo does not restore (its undo is refused and the record discarded before any lookup) SHALL NOT be flagged or counted. The flag SHALL belong to the record, survive every operation that keeps the record, and go when the record goes. When at least one record was flagged, the answer of a single delete's undo SHALL end with: `Older undo entries of this series were not moved to the recreated series, because <n> of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.` For the members of a batch undo that flagged records, the batch's answer, and the text of a batch undo that stops part-way for the members it restored, SHALL end with the batch form, with `<n>` summed over those members: for one member `Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because <n> of its occurrences that had been edited on their own came back as separate events.`, for `<k>` members `Older undo entries of <k> recurring events this batch recreated were not moved to their recreated series, because <n> of their occurrences that had been edited on their own came back as separate events.`, each followed by ` An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.` A batch whose members flagged nothing SHALL answer the text it answered before. The undo of a flagged record that is not found SHALL answer, in place of the generic not-found: `Cannot undo: the recurring event '<title>' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names no longer exists. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.` None of these texts SHALL hold an identifier, a calendar or account name, a date, or any title but the entry's own recorded title, shown as undo texts show titles.

#### Scenario: A one-off event's create record follows its delete's undo

- **WHEN** `create_event`, `delete_event` and `undo` ran, and the event reads back under a new identifier
- **THEN** the create record names the new identifier, and the next undo removes the recreated event

##### Example: the closed list of the follow rule

| Removed | New | Occurrence record | Outcome | Follow to |
|---|---|---|---|---|
| `A` | `B` | no | none (one-off) | `B` |
| `S` | `T` | no | series from rules | `T` |
| `S` | `T` | no | series with exceptions, 0 separate events | `T` |
| `S` | `T` | no | series with exceptions, 1 separate event | none (flagged) |
| `S` | `S` | no | series with exceptions, 1 separate event | none (not flagged) |
| `A` | `B` | yes | occurrence one-off | none |
| `A` | none | no | slot already held | none |
| empty | `B` | no | none | none |
| `A` | `A` | no | none | none |

#### Scenario: A series whose edited occurrences came back as separate events is not followed

- **WHEN** a series created in this session was deleted whole, and the delete's undo brought at least one occurrence edited on its own back as a separate event
- **THEN** the create record keeps its identifier and is flagged, the delete's undo ends with the sentence above, and the create record's undo, not found, answers the flagged text, writes nothing and stays on top

##### Example: the flag goes with its entry

- **GIVEN** a flagged create record on top of the undo stack
- **WHEN** it is discarded with `discard_id` and undo runs again
- **THEN** the record under it, which carries no flag, answers the generic not-found when it is not found

##### Example: what is flagged

- **GIVEN** an undo stack holding, for series `S`, a create record, a whole-series move record, a #263 whole-series update record, the marker of an update that touched the series, a delete record, and a create record of another event
- **WHEN** the records of `S` are flagged
- **THEN** the create, the move and the #263 update are flagged and counted (3); the marker, the delete record and the other event's record are not

#### Scenario: A batch says it for its members

- **WHEN** the undo of a batch delete restored a series member that flagged older records
- **THEN** the batch's answer, or its part-way text, ends with the batch form of the sentence, the separate events summed over those members; without such a member the text is the one of before

##### Example: the batch form

| Members that flagged | Their separate events | End of the batch's answer |
|---|---|---|
| none | — | no sentence |
| 1 | 2 | `Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because 2 of its occurrences …` |
| 2 | 1 and 3 | `Older undo entries of 2 recurring events this batch recreated were not moved to their recreated series, because 4 of their occurrences …` |

#### Scenario: A whole-series update record is not moved

- **WHEN** a series was updated whole in the shape undo restores (#263), deleted whole, and the delete was undone with no occurrence coming back as a separate event
- **THEN** the create record follows the recreated series, the #263 update record keeps the removed identifier, and its undo answers not found and keeps the record

##### Example: the rewrite after a recreate leaves the #263 record

- **GIVEN** an undo stack and a redo stack each holding a #263 update record and a create record that name `S`
- **WHEN** `S` is replaced by `T` as a recreate
- **THEN** the create records name `T` and the #263 update records still name `S`; replaced as the same event (#435, #484), all of them name `T`

#### Scenario: An occurrence's delete is not followed

- **WHEN** the undo of `.deleteOccurrence` or of a split move writes the occurrence as a one-off event
- **THEN** no record is rewritten: the series' records keep naming the series

#### Scenario: A reminder's create record follows its delete's undo

- **WHEN** `create_reminder`, `delete_reminder` and `undo` ran
- **THEN** the undo's answer gives ` (new ID: <id>)` after the title, the create record names that identifier, and the next undo removes the recreated reminder

##### Example: the reminder rewrite and the event rewrite stay apart

- **GIVEN** a create-reminder record and a create-event record that both name `X`, and a delete-reminder record that holds `X`
- **WHEN** the reminder identifier `X` is replaced by `Y`
- **THEN** the create-reminder record names `Y`, the create-event record and the delete-reminder record still hold `X`

#### Scenario: A batch follows member by member

- **WHEN** the undo of a batch delete restores its members, or stops part-way
- **THEN** each restored member's older records name its new identifier right after that member was written, and the members not restored keep their records and identifiers
