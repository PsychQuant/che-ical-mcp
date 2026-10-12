## MODIFIED Requirements

### Requirement: Stale and busy protection
The manager SHALL reject removal from an empty stack, removal with a nonmatching id, and removal during an active undo or redo. Failure SHALL leave both stacks unchanged. Normal not-found errors SHALL preserve the history record for retry. An undo refused because the item no longer holds the state the recorded operation left SHALL write nothing and SHALL preserve the history record (#236), except in the five discard scenarios below (#204 identity lost, the successor shape of a recurring completion without an occurrence snapshot, the update of a recurring event, the update or move of a one-off event that repeats at undo time, and a span "future" delete in one of the three cases of the scenario "Delete of an occurrence and the following ones"); no other refusal discards its record.

#### Scenario: Item changed after the operation
- **WHEN** undo finds that the event or reminder was changed after the recorded operation, in a field the undo would overwrite or delete and that is not already at the value the undo writes
- **THEN** nothing is written, the error names the changed fields, the record stays on top with the same id, and undo with that id as discard_id removes it

#### Scenario: Series occurrences could not be checked
- **WHEN** undo of `create_event` for a recurring event cannot look for occurrences edited on their own (the series has no identifier or calendar)
- **THEN** nothing is written, the error names `unchecked_occurrences`, and the record stays on top with the same id until it is discarded

#### Scenario: Item not found
- **WHEN** undo cannot find the item under its recorded identifier
- **THEN** nothing is written, the record stays on top with the same id, and the error names the item and discard_id

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
- **WHEN** undo meets the record of an `update_event` that touched a recurring event: one occurrence (span "this" with `occurrence_date`, or a detached occurrence addressed by its own identifier), an occurrence and the following ones (span "future"), the whole series (span "all"), or an update that made a one-off event repeat or removed a series' repetition
- **THEN** nothing is looked up or written, the error names the kind of change and says to revert it in Calendar if it should be reverted, and the record is discarded, so older records stay reachable; `undo_history` lists such a record as `Updated recurring event: <title> (undo not available)`

#### Scenario: Update of a one-off event
- **WHEN** undo meets the record of an `update_event` on an event that repeated neither before nor after the update, and the event still neither repeats nor is a detached occurrence
- **THEN** it restores the recorded values as for any update, subject to the post-state check

#### Scenario: Update or move of a one-off event that repeats at undo time
- **WHEN** undo meets the record of an `update_event`, or of a `move_events_batch` move that was not a series move, on a one-off event, and the event now repeats or is a detached occurrence (a later update or another app made it so)
- **THEN** nothing is written, the error says the event repeats now (or is an edited occurrence) and how to revert the change if it should be reverted (a move: move it back), and the record is discarded; a move of an item that was already an edited occurrence is refused the same way

#### Scenario: Delete of an occurrence and the following ones (#244)
- **WHEN** undo meets the record of a `delete_event` with span "future" in exactly one of these three cases, and in no other: (1) `event_id` named a detached occurrence, whose span "future" delete also removes the following occurrences of its series; (2) on a series, the delete did not start at the series' first occurrence (it started at a later one, the last one, or the first one left after earlier deletes); (3) on a series, the delete started at the series' first occurrence and the series' identifier still resolved after it; or the record of a `delete_events_batch` that holds such a delete
- **THEN** nothing is looked up or written (for a batch, no member is undone, the refusal coming before the first member runs), the error says to restore the occurrences in Calendar if they should come back, and the record is discarded, so older records stay reachable; `undo_history` lists the single record as `Deleted occurrences of recurring event: <title> (undo not available)`

#### Scenario: Delete of one occurrence (#244)
- **WHEN** undo meets the record of a `delete_event` with span "this" on a recurring event (or a detached occurrence), or such a member of a `delete_events_batch`
- **THEN** it recreates that occurrence as a one-off event at its start and end, never a second series, unless the series already holds that slot (the scenario "Occurrence delete whose slot the series already holds (#285)"); an absolute-date alarm of the series becomes an alarm at the occurrence's start, and the undo text names `absolute_alarms` (for a batch member, the batch's undo text names it once); `undo_history` lists the record as `Deleted occurrence of event: <title> (undo restores it as a one-off event)`

#### Scenario: Delete of a whole series that holds no exceptions (#244, #285)
- **WHEN** undo meets the record of a `delete_event` (or a `delete_events_batch` member) with span "future" that started at the series' first occurrence, after which the series' identifier no longer resolved, or with span "all", and the record holds no exceptions of the series because they could not be checked when the series was deleted (the series had no identifier or calendar)
- **THEN** it recreates the series from the recorded snapshot, rules included; occurrences deleted or edited on their own before the delete are not part of the snapshot, so they come back as plain occurrences of the series (an edited one without its edit), and the undo text says the series was restored from its rules and that its exceptions were not checked (a batch's undo text says it once); `undo_history` lists the record as `Deleted event: <title> (undo recreates the series from its rules: occurrences deleted on their own earlier come back, edited ones without their edits)`, and a batch record that holds such members as `Batch (<N> operations; undo recreates <K> series from its rules: occurrences deleted on their own earlier come back, edited ones without their edits)` (`their rules` when K is more than one, `1 operation` when N is one), K counting only the members that hold no exceptions, at any depth, unless the batch also holds, at any depth, a member whose undo is refused (the scenario above), when it is listed as `Batch (<N> operations; undo not available: a member deleted an occurrence and the following ones of a recurring event)`

#### Scenario: Delete of a whole series restores its exceptions (#285)
- **WHEN** undo meets the record of a `delete_event` (or a `delete_events_batch` member) with span "future" that started at the series' first occurrence, after which the series' identifier no longer resolved, or with span "all", and the record holds the series' exceptions: the occurrences that existed, and the occurrences edited on their own, over the series' scan window (`seriesScanWindow`: from one day before the first occurrence to the end of the rule, at most 1460 days), listed before the delete removed anything
- **THEN** it recreates the series from the recorded snapshot, rules included; then, inside the recorded window only, it removes every occurrence of the recreated series whose slot (compared to the second) is not the slot of an occurrence that existed and was not edited on its own before the delete, using the two-pass removal and compensating delete of `excluded_occurrence_dates` (#182), so an occurrence deleted on its own earlier stays deleted; and it recreates each occurrence that was edited on its own as a one-off event at its own (edited) start, with its own fields; the slot the rule gave it (taken from the `/RID=` of its identifier) is what decides whether it is inside the window; the undo text names how many occurrences stayed deleted and how many edited occurrences came back as one-off events that no longer belong to the series; `undo_history` lists a single record as `Deleted event: <title> (undo recreates the series and its exceptions within the checked window: occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events)`, and a batch record that holds such members as `Batch (<N> operations; undo recreates <K> series and their exceptions within the checked window: occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events)` (`its exceptions` when K is one, `1 operation` when N is one), joined with the clause of the scenario above by `; ` when the batch holds members of both kinds; a batch undo names this once, without counts

#### Scenario: Occurrences outside the checked window (#285)
- **WHEN** undo restores a series with recorded exceptions and the series has occurrences outside the recorded window (an open-ended series, a rule longer than 1460 days, or an occurrence edited or deleted on its own outside it)
- **THEN** it does not remove or recreate anything outside the window, so those occurrences are whatever EventKit generates from the rules, and the undo text says that exceptions outside the checked window are not restored

#### Scenario: Series' first occurrence is an exception (#285)
- **WHEN** undo restores a series with recorded exceptions and the series' first occurrence was deleted or edited on its own
- **THEN** it is kept from the rule, not removed and not recreated as a one-off event, because removing it would remove the series' anchor (excluding it is refused on create for that reason, #182; on iCloud the identifier stops resolving, #284); the undo text says so

#### Scenario: Edited occurrence moved across the window edge (#285)
- **WHEN** an occurrence edited on its own has its rule slot inside the checked window but was moved outside it, or the reverse
- **THEN** the exceptions are listed over the window and a year on each side of it, as separate queries (the four-year query limit is per query, so the margins do not depend on the window's length), and judged by rule slot: one whose slot is inside the window is restored as a one-off event wherever it was moved within that range, one whose slot is outside is left to the rule; one moved more than a year past the window is not seen, its slot is removed as a slot deleted on its own, and the undo text says so

#### Scenario: Restoring the exceptions fails part-way (#285)
- **WHEN** removing a surplus occurrence, or recreating an edited occurrence as a one-off event, fails after the series was recreated
- **THEN** the recreated series and every one-off event created so far, including one whose save threw after the store may have taken it, are deleted again, nothing of the restore is left behind, the error says the restore failed and nothing was written, and the record is put back for a retry; if that compensating delete itself fails, the error says that the series was recreated with some exceptions applied and to check Calendar, the record is discarded because a retry would create a second series, and the undo is never reported as successful

#### Scenario: Recorded exceptions do not match the recreated series (#285)
- **WHEN** undo has recreated a series with recorded exceptions and the recorded slots do not describe it: no occurrence of the recreated series is listed, a recorded slot is not generated, or the series' own first slot is not generated
- **THEN** nothing is removed and no one-off event is created, the series stands as its rules made it, and the undo text says the recorded exceptions did not match and none was applied; an empty listing at delete time is not recorded as "no exceptions" but as not listed

#### Scenario: Cleanup fails after restoring the exceptions fails (#285)
- **WHEN** restoring the exceptions fails and the recreated series is deleted again, but a one-off event created before the failure cannot be removed
- **THEN** the error says the series was deleted again and that an occurrence remains in the calendar (to check before a retry, which would add it again); it does not say the series exists. A one-off whose save threw and that cannot be removed is reported as possibly remaining, because it may never have been written

#### Scenario: Occurrence delete whose slot the series already holds (#285)
- **WHEN** undo meets the record of a `delete_event` with span "this" (or such a member of a `delete_events_batch`) and the calendar of the snapshot already holds a recurring event with the same title and the same start as the occurrence's slot, as when the series was restored from its rules before this record
- **THEN** it writes nothing, answers success with a text saying the occurrence is already restored by its series, and the record is used up; a one-off event is created only when no such event holds the slot

#### Scenario: Batch member cannot be restored (#248)
- **WHEN** undo of a batch record finds, before its first write, that a member it would recreate (a deleted event or reminder) has no calendar or list to be recreated in, looked up as the restore looks it up (by recorded identifier; a same-named calendar or list in another account does not count), or one that does not allow changes
- **THEN** a refresh of the store is requested and the calendars and lists are read once more (the refresh runs in the background, so a later retry may see what this read does not); if one is still missing, or is there but does not allow changes, nothing of the batch is written, the error counts the items this check stops, says what kind of calendar or list stops them, naming the items but no calendar, list or account, says how many have their calendar or list in place and that discard_id drops every item of the entry, and the record stays on top, whole, with the same id; a batch that also holds a delete of an occurrence and the following ones (#244) is refused by that instead, and its record is discarded. A partial restore is #287

#### Scenario: Batch undo fails part-way (#248)
- **WHEN** a batch undo fails on a member after earlier members were restored
- **THEN** the record is put back holding only the members not yet restored, under the same id and timestamp, with the failing member placed to run last, so the next undo restores the members never attempted before it retries the failing one (each member restores one new item and reads no other member's result, a deleted occurrence too); if the failing member's calendar or list is by then missing or read-only, the next undo is refused whole by the pre-check instead; a member whose error is permanent would be dropped and the members never attempted kept, and with none left the record discarded (no batch member's write throws such an error today); the error says how many were restored and how many remain and names what the members it restored did not restore as they were (an occurrence's absolute-date alarm, a series recreated from its rules alone, the fields a new store holds differently for a reminder whose save reported a failure but was found, #261), which the retry's text does not repeat

#### Scenario: Batch undo fails on its first write (#248)
- **WHEN** the first write of a batch undo fails and other members have not been attempted
- **THEN** no member is confirmed restored and the later members are not attempted; the failing member may still have been written (an event whose save failed after the store took it) or left pending (a reminder whose removal after a failed save also failed), so the error asks to check before running undo again; the record stays under the same id with the failing member placed to run last, so the next undo tries the others first; a permanent member error would drop that member and keep the others

#### Scenario: Batch undo restores a reminder the store holds differently (#248, #261)
- **WHEN** a batch undo recreates a reminder whose save reported a failure, and a new store finds it with compared fields differing from what was saved
- **THEN** the member counts as restored and is not recreated by a retry; the batch answer names that reminder with its own differing fields (the first five such reminders, then how many more), from the names the restore returns and never from its text; a batch that stops part-way names them in its error instead, once; a nested batch would pass its reminders' names up (no tool records one today)

#### Scenario: Batch undo of one member left fails (#248)
- **WHEN** a batch undo has one member left to run, no other member is restored by that undo, and that member's write fails
- **THEN** the member error stands and the record stays as it was, under the same id, as for a single record; as on a first write, the failing member is not confirmed restored but may still have been written or left pending, and that error does not ask to check first; a permanent member error discards the record

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
