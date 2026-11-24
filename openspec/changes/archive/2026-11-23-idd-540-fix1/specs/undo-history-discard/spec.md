## MODIFIED Requirements

### Requirement: Records follow an item the undo of its delete recreated

The undo of a delete writes a new item from the record's snapshot; on iCloud the store gave it a new identifier (measured for a one-off event, a reminder and a series), and the rule below does not assume it. The `.deleteEvent` and `.deleteReminder` records SHALL hold the identifier the removed item had (for an event with rules, the series' identifier without a `/RID=` part), read before the removal, in a single delete and in every row of a batch delete. After the undo of such a record wrote the new item, the server SHALL move every undo and redo record that names the removed identifier to the new identifier, in the cases of this closed list and in no other:

1. the undo of a one-off event's delete, when the event was written;
2. the undo of a whole series' delete, when the series was recreated from its rules alone, or with its recorded exceptions and no occurrence edited on its own came back as a separate event;
3. the undo of a reminder's delete, when the save returned (a save that threw but that a new store finds counts as returned);
4. each member of a batch undo, by the three cases above, right after that member was written.

In every case both identifiers SHALL be non-empty and differ. The undo of one occurrence's delete, of a move that split one occurrence out, of the rule-less record of one occurrence, and of a move that fell back to copy and delete SHALL NOT move records. A failed undo, a series whose exceptions failed and was rolled back, and an occurrence whose slot its series already holds SHALL NOT move records. The record of a whole-series update that undo could restore (#263) SHALL NOT be moved: it was recorded against the series as it was, with its occurrences, so its undo looks up the removed identifier and, while that identifier no longer resolves (as on iCloud, measured), answers not found and keeps the record, which `discard_id` gives up; where the records follow, the delete's undo does not mention it; it is flagged only in the case below, where it alone can bring the delete's sentence. A record that names the series by the own identifier of one of its occurrences (`<series>/RID=…`), which is the record of a whole-series move made through that identifier (#426), is neither moved nor flagged, and its undo, once the calendar it moves the series back to is found (a missing one is refused first, as for every move), answers the generic not-found while the removed identifier no longer resolves (as on iCloud) (a stated limit). An update made through an occurrence's own identifier (#428) is recorded as the marker of an update that touched the series, whose undo is refused and the record discarded before any lookup. The identifier a delete record holds names an item that no longer exists and SHALL never be rewritten. Event records and reminder records SHALL be rewritten separately: an event identifier never rewrites a reminder record, nor the reverse. The undo of a reminder's delete SHALL give the new identifier, ` (new ID: <id>)`, after the title and before any note on fields the store holds differently; when the identifier reads back empty the answer has no such part. A record that follows is checked like any undo; it can be refused for fields that the recreate or this server's own later operations changed, with the comparison's text, which names this server's own later operations among the possible sources (#540).

When the undo of a whole series' delete brought at least one occurrence edited on its own back as a separate event, no record SHALL follow. When the recreated series reads back under the removed identifier, nothing SHALL be flagged either: the older records still name the series that exists. Otherwise the server SHALL flag every undo and redo record that names the removed series and whose undo looks the series up: a create, an update of a one-off event, an in-place move, and a whole-series update that undo could restore. A delete record, a batch, the record of an update that touched the series and that undo does not restore (its undo is refused and the record discarded before any lookup), and the record of a move by copy SHALL NOT be flagged or counted: a move by copy names its copy, and its undo restores the original first and only then looks the copy up, reporting a copy it does not find under its recorded identifier as not found (where the original's slot is already held it writes nothing and does not look the copy up), so it never answers the not-followed text (#559). The flag SHALL belong to the record, survive every operation that keeps the record, and go when the record goes. Limits, stated and not changed: when the store gives the recreated series the removed identifier and occurrences edited on their own came back as separate events, nothing is flagged, and the undo of the series' create then deletes the recreated series and leaves those events, as before this requirement (not seen on iCloud, where the recreated series had a new identifier); and the undo of a flagged update or move whose calendar to restore is also missing answers the calendar-missing refusal first, not the not-followed text. When at least one record was flagged, the answer of a single delete's undo SHALL end with: `Older undo entries of this series were not moved to the recreated series, because <n> of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.` For the members of a batch undo that flagged records, the batch's answer SHALL carry the batch form, with `<n>` summed over those members: at its end when the batch was restored whole, followed by what was kept when a partial restore (#287) kept items; the text of a batch undo that stops part-way SHALL carry it for the members it restored, before the failed item's own error. The batch form is for one member `Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because <n> of its occurrences that had been edited on their own came back as separate events.`, for `<k>` members `Older undo entries of <k> recurring events this batch recreated were not moved to their recreated series, because <n> of their occurrences that had been edited on their own came back as separate events.`, each followed by ` An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.` A batch whose members flagged nothing SHALL answer the text it answered before. The undo of a flagged record that is not found SHALL answer, in place of the generic not-found: `Cannot undo: the recurring event '<title>' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names no longer exists. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.` None of these texts SHALL hold an identifier, a calendar or account name, a date, or any title but the entry's own recorded title, shown as undo texts show titles.

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

- **WHEN** a series created in this session was deleted whole, and the delete's undo brought at least one occurrence edited on its own back as a separate event and recreated the series under another identifier
- **THEN** the create record keeps its identifier and is flagged, the delete's undo ends with the sentence above, and the create record's undo, not found, answers the flagged text, writes nothing and stays on top

##### Example: the flag goes with its entry

- **GIVEN** a flagged create record on top of the undo stack
- **WHEN** it is discarded with `discard_id` and undo runs again
- **THEN** the record under it, which carries no flag, answers the generic not-found when it is not found

##### Example: what is flagged

- **GIVEN** an undo stack holding, for series `S`, a create record, a whole-series move record, a #263 whole-series update record and the marker of an update that touched the series, with a create record of another event among them, and a redo stack holding a delete record of `S`
- **WHEN** the records of `S` are flagged
- **THEN** the create, the move and the #263 update are flagged and counted (3); the marker, the delete record and the other event's record are not

#### Scenario: A batch says it for its members

- **WHEN** the undo of a batch delete restored a series member that flagged older records
- **THEN** the batch's answer ends with the batch form of the sentence (a partial restore adds what it kept after it), and a part-way text carries it before the failed item's own error, the separate events summed over those members; without such a member the text is the one of before

##### Example: the batch form

| Members that flagged | Their separate events | End of the batch's answer |
|---|---|---|
| none | — | no sentence |
| 1 | 2 | `Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because 2 of its occurrences …` |
| 2 | 1 and 3 | `Older undo entries of 2 recurring events this batch recreated were not moved to their recreated series, because 4 of their occurrences …` |

#### Scenario: A whole-series update record is not moved

- **WHEN** a series was updated whole in the shape undo restores (#263), deleted whole, and the delete was undone with no occurrence coming back as a separate event
- **THEN** the create record follows the recreated series, the #263 update record keeps the removed identifier, and its undo, while the removed identifier no longer resolves, answers not found and keeps the record

##### Example: the rewrite after a recreate leaves the #263 record

- **GIVEN** an undo stack holding a create record that names `S`, and a redo stack holding a #263 update record and a create record that name `S`
- **WHEN** `S` is replaced by `T` as a recreate
- **THEN** the create records name `T` and the #263 update record still names `S`, inside a batch too; replaced as the same event (#435, #484), a #263 update record names `T`

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

### Requirement: Changed-after refusal names the sources it cannot tell apart

When an undo or a redo is refused because a field the write would overwrite or delete was changed after the recorded operation (for a redo, after the undo), and the change can be changed back, the error SHALL NOT claim one source of the change: the post-state check compares the item with the recorded state and does not know who changed it. The undo error SHALL name, as possible sources, another app, the calendar server, and a later operation of this server that has no entry in the undo history now (for example one whose entry was given up with `discard_id`); for a reminder it SHALL also name a failed write of this server that landed later (#274). The redo error SHALL name no source: whether this server can change a completion between an undo and its redo was neither shown nor ruled out. Neither error SHALL tell the reader that whoever made the change decides; each SHALL ask the user whether to change the field back (for an undo, or to give up the undo), as before. A change made back through this server is recorded as an entry of its own above the refused one, and the next undo takes that entry first: the undo error SHALL say so and SHALL say to give that entry up with `discard_id` before running undo again (a change made back in another app records nothing here). A change recorded through this server clears the redo history, so the redo error SHALL ask for the change-back in another app and SHALL name `complete_reminder` for setting the completion through this server (#540 verify round 1). Nothing else about the refusal changes: nothing is written and the record is kept.

#### Scenario: Older record refused after the later record was discarded

- **WHEN** an event is created, then moved to another calendar with `move_events_batch`, the move's entry is given up with `discard_id`, and undo then meets the create record
- **THEN** the undo is refused naming `calendar`, nothing is written, the record is kept, and the error names another app, the calendar server and a later operation of this server without an entry in the undo history as possible sources, and does not say "Whoever made the change"

#### Scenario: Reminder refusal keeps the failed-write source

- **WHEN** the undo of a reminder record is refused because its title was changed after the operation
- **THEN** the error names another app, the calendar server, a later operation of this server without an entry in the undo history, and a failed write of this server that landed later

#### Scenario: Redo refusal names no source

- **WHEN** the redo of a completion is refused because the reminder's completion was changed after the undo
- **THEN** the error names the changed field and no source of the change, asks for the change-back in another app, names `complete_reminder`, nothing is written, and the redo entry is kept

#### Scenario: Change-back through this server before the undo

- **WHEN** the undo of a create record is refused naming `calendar`, and the event is then moved back to its calendar with `move_events_batch`
- **THEN** the move back is a new entry above the create record; the refusal said to give that entry up with `discard_id` before running undo again, and the undo after that removes the event
