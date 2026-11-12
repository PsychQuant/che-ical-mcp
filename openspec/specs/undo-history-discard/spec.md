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
- **WHEN** undo meets the record of an `update_event` that, when it was saved, passed only event_id, span and title, notes or location, with span all through the series' own identifier, on an iCloud calendar, on a series that starts and ends within the dates undo lists its occurrences over (at most four years; never a series with no end) and whose first occurrence was not edited or deleted on its own (through the series' identifier such a series goes through an occurrence's own identifier, #428, or a stand-in, #326, or shows a first occurrence that is not its first slot), with no location written over a place with coordinates (the series' own or that of an occurrence edited on its own), with the same occurrences edited or deleted on their own listed before and after the save, and where each occurrence edited on its own, in each field it wrote, either followed the update (it had the series' old value and took the new one) or kept an own value different from both, and nothing else of it changed (the call wrote no recurrence; the slots compare to the second, with nil and empty text the same). The two shapes are inferred across the three fields from what was measured (follows: notes and location; keeps: title), so an occurrence that already held the written value is in neither, unless the written value equals the old one; the inverse was measured only on a series that had not started. An occurrence edited on its own and moved more than a year outside the listed dates is not listed: its slot counts as deleted, and it is not checked or compared. `undo_history` lists such a record as `Updated recurring event: <title before the update> (whole series; undo restores its <fields>)`
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
