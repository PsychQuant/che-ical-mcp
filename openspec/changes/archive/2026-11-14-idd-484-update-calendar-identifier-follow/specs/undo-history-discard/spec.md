## ADDED Requirements

### Requirement: Records follow an identifier this server's calendar change gave

When a write of this server moves an event to another calendar and the store gives the event a new identifier, the server SHALL move every undo and redo record that names the event by its old identifier to the new one, so that an older record still finds the event. A removed identifier held by a delete record SHALL NOT be touched. The identifier comparison SHALL treat a series identifier and an occurrence identifier of that same series as the same identifier, and SHALL treat an empty identifier as no change.

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

- **WHEN** `update_event` with span `future` starts a new series from an occurrence, or a write goes through an occurrence's own identifier or the stand-in
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
