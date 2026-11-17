# undo-history-discard Specification

## Purpose

Allow clients to explicitly abandon a blocked top undo record using stable identity, while preserving older history, redo records and in-flight operation safety. Redo writes again only completions; for a create, delete, update or move it answers with the tool that repeats the operation. That is the intended design (#295), not a missing replay: replaying those writes would be a change to this contract.

## Requirements

### Requirement: Stable history identity
The server SHALL expose an id for each undo history entry, stable across pop and restore. History entries and counts SHALL come from one actor snapshot.

#### Scenario: History entry is retried
- **WHEN** an undo fails and its record is restored
- **THEN** its id equals the previously listed id

---
### Requirement: Explicit top record removal
undo with discard_id SHALL remove only the current top undo record with that id. It SHALL NOT call EventKit, create a redo record, or remove any other record. Omitted discard_id SHALL retain normal undo behavior. A present discard_id SHALL be a nonempty UUID string.

#### Scenario: Dead event above a reminder
- **WHEN** a client passes the listed top event record id as discard_id
- **THEN** that record is removed and the older reminder record is reachable

#### Scenario: Dead reminder above an event
- **WHEN** a client passes the listed top reminder record id as discard_id
- **THEN** that record is removed and the older event record is reachable

#### Scenario: Malformed request
- **WHEN** discard_id is null, a number, boolean, object, empty string or malformed UUID
- **THEN** the request fails without changing either stack

---
### Requirement: Stale and busy protection
The manager SHALL reject removal from an empty stack, removal with a nonmatching id, and removal during an active undo or redo. Failure SHALL leave both stacks unchanged. Normal not-found errors SHALL preserve the history record for retry. The state a recorded operation left SHALL be read back by the item's identifier right after its save, as the undo reads it, so a value the store normalizes on save is recorded as the undo sees it; a change another process makes between the save and that read is recorded as part of that state (#424), a known limit. An undo refused because the item no longer holds the state the recorded operation left SHALL write nothing and SHALL preserve the history record (#236), except in the six discard scenarios below (#204 identity lost, the successor shape of a recurring completion without an occurrence snapshot, the update of a recurring event (not the restorable whole-series update of #263, whose refusals keep the record and whose read-back mismatch after a write discards it), the update or move of a one-off event that repeats at undo time, a span "future" delete in one of the three cases of the scenario "Delete of an occurrence and the following ones", and a calendar operation, #273); no other refusal discards its record. The undo of an `update_event` (except the restorable whole-series update of #263, which never changes the series' calendar and reads no calendar to restore into: a series that is gone is not found, and one without a calendar is refused as such, the record kept) and of a move reads the calendar it restores into before it checks the event (#269): when that calendar is missing, the refusal of the scenario "Calendar to restore into not found" comes first and the record is kept, whatever state the event is in (changed, repeating, a detached occurrence, or not found); the discard of the update or move of a one-off event that repeats at undo time applies only once that calendar resolves.

#### Scenario: Item changed after the operation
- **WHEN** undo finds that the event or reminder was changed after the recorded operation, in a field the undo would overwrite or delete and that is not already at the value the undo writes
- **THEN** nothing is written, the error names the changed fields, the record stays on top with the same id, and undo with that id as discard_id removes it

#### Scenario: Keeping later edits when undoing an update (#265, opt-in)
- **WHEN** the record is an `update_event` of a one-off event or an `update_reminder`, undo finds the item changed after it, and the caller passes `keep_later_edits: true`
- **THEN** the fields are compared in groups (an event's start, end, all-day flag, time zone, alarms, calendar and availability; its location and place; a reminder's due date, start date, alarms, repetition, completion and list; every other field alone; what the update changed compared without the guard's geocode exemption, its other tolerances kept): when no later edit is in a group the update changed, only those groups are written back from the record, the later edits are kept, the answer names both, and the record is used up; otherwise, or when a changed field is in no group, nothing is written and the refusal is the one above; when the update changed none of the fields undo restores, the undo runs as without `keep_later_edits`. Without `keep_later_edits`, and for every other record, the scenario above applies unchanged. The refusal of an update-undo lists the fields the update changed and the fields changed after it separately, and says whether `keep_later_edits` applies

#### Scenario: Series occurrences could not be checked
- **WHEN** undo of `create_event` for a recurring event cannot look for occurrences edited on their own (the series has no identifier or calendar)
- **THEN** nothing is written, the error names `unchecked_occurrences`, and the record stays on top with the same id until it is discarded

#### Scenario: Item not found
- **WHEN** undo cannot find the item under its recorded identifier
- **THEN** nothing is written, the record stays on top with the same id, and the error names the item and discard_id

#### Scenario: Calendar to restore into not found (#269)
- **WHEN** undo of a single `delete_event` (a whole event or one occurrence), `update_event` or move of an event (`move_events_batch`, `copy_event` with `delete_original`, also a whole-series move through the stand-in, #369; a move that fell back to a copy or split one occurrence out has its own record, #466, whose restore of the source is refused here in the words of a move) finds no calendar under the identifier it recorded for the calendar it restores into, or the record has none; a same-named calendar in another account does not count; the calendars are read only after Calendar access is checked (no access is that error, not a missing calendar), and a miss is read once more after the view is marked stale before it counts (that re-read requests a background refresh and reads at once, so it can still see the old view); the update and move undo read the calendar before checking the event, so this refusal comes before a refusal for a changed event, an event that repeats or is a detached occurrence now (which would discard the record), or an event not found, and the record is kept in each case
- **THEN** nothing is written for that event, the record stays on top with the same id, and the error names the event as the undo texts show titles (quotes replaced, hidden characters dropped, capped) and neither the calendar nor its account (a shared or subscribed calendar's title is set by someone else and an account name is often an e-mail address, #37, as #290 for lists), says the calendar is not available (deleted, or its account turned off or still syncing) or, for a record without an identifier, that it cannot be found, says that nothing was written and the entry was kept, offers running undo again only when the identifier was recorded, says what giving up the undo loses (the deleted event or occurrence; for an update the event stays as it is; for a move it stays in the calendar it was moved to; for a move by copy the copy stays there, if it is still there), and then to ask the user whether to give up the undo and, if they agree, to read undo_history and call undo with the entry's id as discard_id; it names no tool besides undo and undo_history. The reminder counterpart is the list of #242; a batch is checked before its first write instead (scenario "Batch member cannot be restored")

#### Scenario: Recurring occurrence identity lost (#204)
- **WHEN** undo or redo of an identity-guarded recurring completion finds that the identifier resolves to another occurrence
- **THEN** nothing is written and the record is discarded, so older records stay reachable

#### Scenario: Recurring completion without an occurrence snapshot, successor shape
- **WHEN** undo or redo of a recurring completion recorded without the #204 snapshot finds that the identifier resolves to a reminder that still repeats and whose completion is the opposite of the state the undo or redo expects (what EventKit leaves when it advances a recurring reminder in place)
- **THEN** nothing is written and the record is discarded, as for #204, so older records stay reachable

#### Scenario: Recurring completion without an occurrence snapshot, other mismatch
- **WHEN** undo or redo of such a record finds the reminder in any other state than the one it expects (the same completion at another time, or a reminder that no longer repeats)
- **THEN** nothing is written and the record is kept, even when the reminder already looks like what the write would produce

#### Scenario: Update of a recurring event (#236, #262)
- **WHEN** undo meets the record of an `update_event` that touched a recurring event: one occurrence (span "this" with `occurrence_date`, or a detached occurrence addressed by its own identifier), an occurrence and the following ones (span "future"), the whole series (span "all") other than the restorable whole-series update of the next scenario, or an update that made a one-off event repeat or removed a series' repetition
- **THEN** nothing is looked up or written, the error names the kind of change and says to revert it in Calendar if it should be reverted (for the whole series it also says which whole-series update undo restores), and the record is discarded, so older records stay reachable; `undo_history` lists such a record as `Updated recurring event: <title> (undo not available)`

#### Scenario: Restorable whole-series update on iCloud (#263)
- **WHEN** undo meets the record of an `update_event` that, when it was saved, passed only event_id, span and title, notes or location, with span all through the series' own identifier, on an iCloud calendar, on a series that starts and ends within the dates undo lists its occurrences over (at most four years; never a series with no end, nor a count whose last occurrence cannot be bounded, which is a count with days of the month, months, weeks or days of the year, set positions, days of the week on a daily, monthly or yearly rule, or a monthly or yearly start after the 28th) and whose first occurrence was not edited or deleted on its own (through the series' identifier such a series goes through an occurrence's own identifier, #428, or a stand-in, #326, or shows a first occurrence that is not its first slot), with no location written over a place with coordinates (the series' own or that of an occurrence edited on its own) or over a series place named other than its location, with the same occurrences edited or deleted on their own listed before and after the save, and where each occurrence edited on its own, in each field it wrote, either followed the update (it had the series' old value and took the new one) or kept an own value different from both, and nothing else of it changed (the call wrote no recurrence; the slots compare to the second). The two shapes are inferred across the three fields from what was measured (follows: notes and location; keeps: title), so an occurrence that already held the written value is in neither, unless the written value equals the old one; the inverse was measured only on a series that had not started. An occurrence edited on its own and moved more than a year outside the listed dates is not listed: its slot counts as deleted, and it is not checked or compared. This record's own comparisons read nil and empty notes, location and place title as the same, and a place without coordinates whose title is the location string moves with the location; #236's guard on the series compares them exactly, so the undo of a write that clears a field may be refused there. As for every update-undo, coordinates added later to a place that had none do not block the undo and are overwritten. `undo_history` lists such a record as `Updated recurring event: <title before the update> (whole series; undo restores its <fields>)`
- **THEN** the undo first runs the post-state check of the scenario "Item changed after the operation" on the series object (a field changed since and not at the value the undo writes refuses as there, record kept). It then writes nothing and keeps the record, with an error that names the reason and says to ask the user whether to give up the undo and, if they agree, to read undo_history and call undo with the entry's id as discard_id (naming no other tool), when any of these holds: the recorded identifier no longer reads as the same series (other identifiers, a detached occurrence, no repetition); its rule differs from the rule after the update; its calendar is not on iCloud; its occurrences cannot be listed over the recorded windows, or those windows no longer hold the series; or the occurrences edited or deleted on their own differ from those listed after the update (one deleted, back, newly edited, or edited again, by slot and by the compared fields). Otherwise it writes the recorded values of the fields the update wrote, and only those, to the series with span "all" in one save; a failed save is rolled back, nothing is restored and the record is kept. After the save it reads the series and lists its occurrences again over the recorded windows: when the written fields, the rule and the occurrences edited or deleted on their own equal those before the update, the answer says what was restored and that those occurrences, as listed, were compared; otherwise the error says that the values were written, names what differs, says to check the series in Calendar, and the record is discarded. Redo of such an undo writes nothing (scenario "Redo of a record whose redo writes nothing"); `keep_later_edits` does not apply to it (it undoes as without the flag)

#### Scenario: Update of a one-off event
- **WHEN** undo meets the record of an `update_event` on an event that repeated neither before nor after the update, and the event still neither repeats nor is a detached occurrence
- **THEN** it restores the recorded values as for any update, subject to the post-state check

#### Scenario: Update or move of a one-off event that repeats at undo time
- **WHEN** undo meets the record of an `update_event`, or of a `move_events_batch` move that was not a series move, on a one-off event, and the event now repeats or is a detached occurrence (a later update or another app made it so)
- **THEN** nothing is written, the error says the event repeats now (or is an edited occurrence) and how to revert the change if it should be reverted (a move: move it back), and the record is discarded; a move of an item that was already an edited occurrence is refused the same way. This applies only when the calendar the undo restores into resolves: it is read first, and when it is missing the refusal of the scenario "Calendar to restore into not found" (#269) is given instead and the record is kept

#### Scenario: Delete of an occurrence and the following ones (#244)
- **WHEN** undo meets the record of a `delete_event` with span "future" in exactly one of these three cases, and in no other: (1) `event_id` named a detached occurrence, whose span "future" delete also removes the following occurrences of its series; (2) on a series, the delete did not start at the series' first occurrence (it started at a later one, the last one, or the first one left after earlier deletes); (3) on a series, the delete started at the series' first occurrence and the series' identifier still resolved after it; or the record of a `delete_events_batch` that holds such a delete
- **THEN** nothing is looked up or written (for a batch, no member is undone, the refusal coming before the first member runs), the error says to restore the occurrences in Calendar if they should come back, and the record is discarded, so older records stay reachable; `undo_history` lists the single record as `Deleted occurrences of recurring event: <title> (undo not available)`

#### Scenario: Calendar operation (#273)
- **WHEN** undo meets the record of a `create_calendar` (one that created a calendar; one that found an existing calendar of that title records nothing), an `update_calendar` or a `delete_calendar`, each recorded after its save or removal succeeded so that undo after it does not revert an older operation in its place
- **THEN** nothing is looked up or written, the error says the calendar operation cannot be undone and why (a created calendar may hold items added since; a renamed or recolored one may have changed again; a deleted one cannot be recreated with its events or reminders), names neither the calendar nor its account (#37), says that nothing was written and that the entry was discarded, so the next undo reverts the operation recorded before it and not the calendar operation, and says how to revert it by hand (in Calendar, or with `update_calendar`, `create_calendar`, or `delete_calendar` with `require_empty: true`); the record is discarded, so older records stay reachable; `undo_history` lists such a record as `Created calendar: <title> (undo not available)`, `Updated calendar: <title before the update> (undo not available)` or `Deleted calendar: <title> (undo not available)`; its redo writes nothing (it never reaches the redo stack)

#### Scenario: Delete of one occurrence (#244)
- **WHEN** undo meets the record of a `delete_event` with span "this" on a recurring event (or a detached occurrence), or such a member of a `delete_events_batch`
- **THEN** it recreates that occurrence as a one-off event at its start and end, never a second series; an absolute-date alarm of the series becomes an alarm at the occurrence's start, and the undo text names `absolute_alarms` (for a batch member, the batch's undo text names it once); `undo_history` lists the record as `Deleted occurrence of event: <title> (undo restores it as a one-off event)`

#### Scenario: Delete of a whole series (#244)
- **WHEN** undo meets the record of a `delete_event` (or a `delete_events_batch` member) with span "future" that started at the series' first occurrence, after which the series' identifier no longer resolved, or with span "all"
- **THEN** it recreates the series from the recorded snapshot, rules included; occurrences deleted or edited on their own before the delete are not part of the snapshot, so they come back as plain occurrences of the series (an edited one without its edit), and the undo text says the series was restored from its rules, for every series restored from its rules whether or not it had such occurrences (a batch's undo text says it once); `undo_history` lists a single record as `Deleted event: <title> (undo recreates the series from its rules: occurrences deleted on their own earlier come back, edited ones without their edits)`, and a batch record that holds such a member as `Batch (<N> operations; undo recreates <K> series from its rules: occurrences deleted on their own earlier come back, edited ones without their edits)` (`their rules` when K is more than one, `1 operation` when N is one), K counting such members at any depth, unless the batch also holds, at any depth, a member whose undo is refused (the scenario above), when it is listed as `Batch (<N> operations; undo not available: a member deleted an occurrence and the following ones of a recurring event)`; undoing an earlier record that restores one of those occurrences as a one-off then adds it a second time, and that undo's text does not warn of it (#285)

#### Scenario: Batch member cannot be restored (#248)
- **WHEN** undo of a batch record finds, before its first write, that a member it would recreate (a deleted event or reminder) has no calendar or list to be recreated in, looked up as the restore looks it up (by recorded identifier; a same-named calendar or list in another account does not count), or one that does not allow changes
- **THEN** a refresh of the store is requested and the calendars and lists are read once more (the refresh runs in the background, so a later retry may see what this read does not); if one is still missing, or is there but does not allow changes, nothing of the batch is written, the error counts the items this check stops, says what kind of calendar or list stops them, naming the items but no calendar, list or account, says how many have their calendar or list in place and that discard_id drops every item of the entry, and the record stays on top, whole, with the same id; when some items have their calendar or list in place, the error also says that undo with restore_available restores those and keeps the others (scenario "Partial restore on request"); a batch that also holds a delete of an occurrence and the following ones (#244) is refused by that instead, and its record is discarded

#### Scenario: Partial restore on request (#287)
- **WHEN** undo is called with restore_available set to true and the pre-check of the batch on top would refuse it because some members' calendars or lists are missing or read-only (read once more after the refusal requested a refresh)
- **THEN** the members whose every item has its calendar or list in place are restored, in the order a whole batch undo runs them (the reverse of the recorded order), each as in a whole batch undo (#236's check before each write, and the pre-check once more on them: a calendar or list gone since then refuses the whole entry, nothing written); the record is put back with only the other members, under the same id and timestamp, and the restored members leave a redo record, as a whole batch undo leaves its record; the answer is a success that says what was restored and, for the members kept, what kind of calendar or list stops them and why, naming the items and no calendar, list or account (#37), that a later undo restores them once their calendar or list is back, and that discard_id drops only them; when no member can be restored the refusal stands as in "Batch member cannot be restored", and when every destination is back by the time of the second read the whole batch runs; a batch holding a delete of an occurrence and the following ones (#244) is still refused by that first; restore_available changes nothing for any other record and cannot be combined with discard_id

#### Scenario: Partial restore stops part-way (#287, #248)
- **WHEN** a save fails part-way on the restorable members of a partial restore
- **THEN** the record is put back with the members kept for their calendar or list first (so they run last next time) and then the members not yet restored, as "Batch undo fails part-way" orders them, under the same id; the error is that scenario's, plus how many members were not attempted for their calendar or list and why; when that scenario would discard the record because none of its own members is left, or the only restorable member fails in a way no retry can restore, the record is kept for the members not attempted instead

#### Scenario: Batch undo fails part-way (#248)
- **WHEN** a batch undo fails on a member after earlier members were restored
- **THEN** the record is put back holding only the members not yet restored, under the same id and timestamp, with the failing member placed to run last, so the next undo restores the members never attempted before it retries the failing one (each member restores one new item and reads no other member's result, a deleted occurrence too); if the failing member's calendar or list is by then missing or read-only, the next undo is refused whole by the pre-check instead; a member whose error is permanent would be dropped and the members never attempted kept, and with none left the record discarded (no batch member's write throws such an error today); the error says how many were restored and how many remain and names what the members it restored did not restore as they were (an occurrence's absolute-date alarm, a series recreated from its rules, the fields a new store holds differently for a reminder whose save reported a failure but was found, #261), which the retry's text does not repeat

#### Scenario: Batch undo fails on its first write (#248)
- **WHEN** the first write of a batch undo fails and other members have not been attempted
- **THEN** no member is confirmed restored and the later members are not attempted; the error names the failing member (its recorded title, quotes replaced and capped); unless that member failed because its calendar or list was not found, which happens before anything is written (then the error says a retry adds no copy of it, #292), its restore may have left something written (an event whose save failed after the store took it, a reminder left pending when its removal after a failed save also failed, a series restore that was rolled back), so the error asks to check before running undo again; the record stays under the same id with the failing member placed to run last, so the next undo tries the others first; a permanent member error would drop that member and keep the others

#### Scenario: Batch undo restores a reminder the store holds differently (#248, #261)
- **WHEN** a batch undo recreates a reminder whose save reported a failure, and a new store finds it with compared fields differing from what was saved
- **THEN** the member counts as restored and is not recreated by a retry; the batch answer names that reminder with its own differing fields (the first five such reminders, then how many more), from the names the restore returns and never from its text; a batch that stops part-way names them in its error instead, once; a nested batch would pass its reminders' names up (no tool records one today)

#### Scenario: Batch undo of one member left fails (#248)
- **WHEN** a batch undo has one member left to run, no other member is restored by that undo, and that member's write fails
- **THEN** the record stays as it was, under the same id; as on a first write, the failing member is not confirmed restored but may still have been written or left pending, so the error says no item is confirmed restored, names the member, asks to check before running undo again (unless the member's error came before any write: its calendar or list was not found), and gives the member's own error last (#292); a permanent member error stands alone and discards the record

#### Scenario: Rule of a created series shortened
- **WHEN** undo of `create_event` finds the series' rule shortened (one rule before and after, the same pattern, a smaller count, an earlier end, or an end where there was none), as an update or delete of an occurrence and the following ones leaves it
- **THEN** nothing is written, the record is kept, and the error offers only giving up the undo with discard_id, not changing the recurrence back; any other change of the rule is an ordinary refusal that can be changed back

#### Scenario: Redo refused
- **WHEN** redo of a completion finds the reminder changed after the undo
- **THEN** nothing is written and the record stays on the redo stack

#### Scenario: Redo of a record whose redo writes nothing (#247)
- **WHEN** the top of the redo stack is a record whose redo writes nothing: a create, delete, update or move, or a batch with any such member (only completion records are written again)
- **THEN** nothing is executed or written, the undo stack does not change, no undo or redo is left in progress, and redo answers `success: false` with an instruction that names the tool that repeats the operation; the record is then removed from the redo stack, so the instruction is returned once and the next redo applies to whatever record is then on top; the next undo does not undo that record a second time

#### Scenario: Repeated discard
- **WHEN** the same id is submitted after its record was removed
- **THEN** the second request fails and the next record remains intact

#### Scenario: Concurrent history execution
- **WHEN** undo or redo has begun and not finished
- **THEN** discard and another begin request fail with a busy error

---
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


<!-- @trace
source: idd-538-fix1
updated: 2026-11-17
code:
  - CHANGELOG.md
-->

---
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


<!-- @trace
source: idd-539-fix2
updated: 2026-11-18
code:
  - mcpb/manifest.json
  - Sources/CheICalMCP/Server.swift
  - CHANGELOG.md
  - Tests/CheICalMCPTests/FloatingSeriesUndoMatrixTests.swift
  - Tests/CheICalMCPTests/ManifestParityTests.swift
  - Tests/CheICalMCPTests/SlotReadingsDocsTests.swift
  - README_zh-TW.md
  - Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift
  - Sources/CheICalMCP/EventKit/SlotReadings.swift
  - README.md
  - Sources/CheICalMCP/EventKit/SeriesExceptions.swift
-->

---
### Requirement: Records follow an item the undo of its delete recreated

The undo of a delete writes a new item from the record's snapshot; on iCloud the store gave it a new identifier (measured for a one-off event, a reminder and a series), and the rule below does not assume it. The `.deleteEvent` and `.deleteReminder` records SHALL hold the identifier the removed item had (for an event with rules, the series' identifier without a `/RID=` part), read before the removal, in a single delete and in every row of a batch delete. After the undo of such a record wrote the new item, the server SHALL move every undo and redo record that names the removed identifier to the new identifier, in the cases of this closed list and in no other:

1. the undo of a one-off event's delete, when the event was written;
2. the undo of a whole series' delete, when the series was recreated from its rules alone, or with its recorded exceptions and no occurrence edited on its own came back as a separate event;
3. the undo of a reminder's delete, when the save returned (a save that threw but that a new store finds counts as returned);
4. each member of a batch undo, by the three cases above, right after that member was written.

In every case both identifiers SHALL be non-empty and differ. The undo of one occurrence's delete, of a move that split one occurrence out, of the rule-less record of one occurrence, and of a move that fell back to copy and delete SHALL NOT move records. A failed undo, a series whose exceptions failed and was rolled back, and an occurrence whose slot its series already holds SHALL NOT move records. The record of a whole-series update that undo could restore (#263) SHALL NOT be moved: it was recorded against the series as it was, with its occurrences, so its undo looks up the removed identifier, answers not found and keeps the record, which `discard_id` gives up; it is flagged only in the case below. A record that names the series by the own identifier of one of its occurrences (`<series>/RID=…`: a whole-series move or an update recorded through an occurrence's own identifier, #426, #428) is neither moved nor flagged, and its undo answers the generic not-found (a stated limit). The identifier a delete record holds names an item that no longer exists and SHALL never be rewritten. Event records and reminder records SHALL be rewritten separately: an event identifier never rewrites a reminder record, nor the reverse. The undo of a reminder's delete SHALL give the new identifier, ` (new ID: <id>)`, after the title and before any note on fields the store holds differently; when the identifier reads back empty the answer has no such part. A record that follows is checked like any undo; it can be refused for fields that the recreate or this server's own later operations changed, with the comparison's text, which names another app or the calendar server (#540).

When the undo of a whole series' delete brought at least one occurrence edited on its own back as a separate event, no record SHALL follow. When the recreated series reads back under the removed identifier, nothing SHALL be flagged either: the older records still name the series that exists. Otherwise the server SHALL flag every undo and redo record that names the removed series and whose undo looks the series up: a create, an update of a one-off event, a move, a whole-series update that undo could restore, and the copy of a move by copy. A delete record, a batch, and the record of an update that touched the series and that undo does not restore (its undo is refused and the record discarded before any lookup) SHALL NOT be flagged or counted. The flag SHALL belong to the record, survive every operation that keeps the record, and go when the record goes. When at least one record was flagged, the answer of a single delete's undo SHALL end with: `Older undo entries of this series were not moved to the recreated series, because <n> of its occurrences that had been edited on their own came back as separate events. An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.` For the members of a batch undo that flagged records, the batch's answer SHALL carry the batch form, with `<n>` summed over those members: at its end when the batch was restored whole, followed by what was kept when a partial restore (#287) kept items; the text of a batch undo that stops part-way SHALL carry it for the members it restored, before the failed item's own error. The batch form is for one member `Older undo entries of a recurring event this batch recreated were not moved to its recreated series, because <n> of its occurrences that had been edited on their own came back as separate events.`, for `<k>` members `Older undo entries of <k> recurring events this batch recreated were not moved to their recreated series, because <n> of their occurrences that had been edited on their own came back as separate events.`, each followed by ` An undo of such an entry that is not found will answer that, and the entry can only be given up with discard_id.` A batch whose members flagged nothing SHALL answer the text it answered before. The undo of a flagged record that is not found SHALL answer, in place of the generic not-found: `Cannot undo: the recurring event '<title>' was deleted and then recreated by an undo as a new series, and occurrences of it that had been edited on their own came back as separate events, so the series this entry names no longer exists. This entry was not moved to the new series. Nothing was written and this history entry was kept. To go on, ask the user whether to give up this undo; if they agree, read undo_history and call undo with discard_id set to its id.` None of these texts SHALL hold an identifier, a calendar or account name, a date, or any title but the entry's own recorded title, shown as undo texts show titles.

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
- **THEN** the batch's answer ends with the batch form of the sentence (a partial restore adds what it kept after it), and a part-way text carries it before the failed item's own error, the separate events summed over those members; without such a member the text is the one of before

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

<!-- @trace
source: idd-538-fix1
updated: 2026-11-17
code:
  - CHANGELOG.md
-->