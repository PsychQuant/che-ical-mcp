# undo-history-discard Specification

## Purpose

Allow clients to explicitly abandon a blocked top undo record using stable identity, while preserving older history, redo records and in-flight operation safety.

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
The manager SHALL reject removal from an empty stack, removal with a nonmatching id, and removal during an active undo or redo. Failure SHALL leave both stacks unchanged. Normal not-found errors SHALL preserve the history record for retry. An undo refused because the item no longer holds the state the recorded operation left SHALL write nothing and SHALL preserve the history record (#236), except in the five discard scenarios below (#204 identity lost, the successor shape of a recurring completion without an occurrence snapshot, the update of a recurring event, the update or move of a one-off event that repeats at undo time, and the delete of an occurrence and the following ones that did not start at the series' first occurrence and remove it all); no other refusal discards its record.

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
- **WHEN** undo meets the record of a `delete_event` with span "future" that did not start at the series' first occurrence and remove it all (it started at a later occurrence, the last one or the first one left after earlier deletes included, or `event_id` named a detached occurrence, whose span "future" delete also removes the following occurrences of its series), or of a `delete_events_batch` that holds such a delete
- **THEN** nothing is looked up or written (for a batch, no member is undone, the refusal coming before the first member runs), the error says to restore the occurrences in Calendar if they should come back, and the record is discarded, so older records stay reachable; `undo_history` lists the single record as `Deleted occurrences of recurring event: <title> (undo not available)`

#### Scenario: Delete of one occurrence (#244)
- **WHEN** undo meets the record of a `delete_event` with span "this" on a recurring event (or a detached occurrence), or such a member of a `delete_events_batch`
- **THEN** it recreates that occurrence as a one-off event at its start and end, never a second series; an absolute-date alarm of the series becomes an alarm at the occurrence's start, and the undo text names `absolute_alarms` (for a batch member, the batch's undo text names it once); `undo_history` lists the record as `Deleted occurrence of event: <title> (undo restores it as a one-off event)`

#### Scenario: Delete of a whole series from its first occurrence (#244)
- **WHEN** undo meets the record of a `delete_event` (or a `delete_events_batch` member) with span "future" that started at the series' first occurrence, after which the series' identifier no longer resolved
- **THEN** it recreates the series from the recorded snapshot, rules included; occurrences deleted or edited on their own before the delete are not part of the snapshot, so they come back as plain occurrences of the series (#285)

#### Scenario: Batch member cannot be restored (#248)
- **WHEN** undo of a batch record finds, before its first write, that a member it would recreate (a deleted event or reminder) has no calendar or list to be recreated in, looked up as the restore looks it up (by recorded identifier; a same-named calendar or list in another account does not count)
- **THEN** nothing of the batch is written, the error names the item and the calendar or list, and the record stays on top, whole, with the same id

#### Scenario: Batch undo fails part-way (#248)
- **WHEN** a batch undo fails on a member after earlier members were restored
- **THEN** the record is put back holding only the members not yet restored, under the same id and timestamp, with the failing member placed to run last; the error says how many were restored and how many remain, and the next undo restores the members never attempted before it retries the failing one

#### Scenario: Batch undo fails on its first write (#248)
- **WHEN** the first write of a batch undo fails and other members have not been attempted
- **THEN** nothing is written, and the record stays whole under the same id with the failing member placed to run last, so the next undo tries the others first; a permanent member error discards the record as for a single record

#### Scenario: Rule of a created series shortened
- **WHEN** undo of `create_event` finds the series' rule shortened (one rule before and after, the same pattern, a smaller count, an earlier end, or an end where there was none), as an update or delete of an occurrence and the following ones leaves it
- **THEN** nothing is written, the record is kept, and the error offers only giving up the undo with discard_id, not changing the recurrence back; any other change of the rule is an ordinary refusal that can be changed back

#### Scenario: Redo refused
- **WHEN** redo of a completion finds the reminder changed after the undo
- **THEN** nothing is written and the record stays on the redo stack

#### Scenario: Redo of a record whose redo writes nothing (#247)
- **WHEN** the top of the redo stack is a record whose redo writes nothing: a create, delete, update or move, or a batch with any such member (only completion records are written again)
- **THEN** nothing is executed or written, the undo stack does not change, no undo or redo is left in progress, and redo answers `success: false` with an instruction that names the tool that repeats the operation; the record is then removed from the redo stack, so the instruction is returned once and the next redo reaches the record beneath it; the next undo does not undo that record a second time

#### Scenario: Repeated discard
- **WHEN** the same id is submitted after its record was removed
- **THEN** the second request fails and the next record remains intact

#### Scenario: Concurrent history execution
- **WHEN** undo or redo has begun and not finished
- **THEN** discard and another begin request fail with a busy error
