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
- **THEN** it recreates that occurrence as a one-off event at its start and end (never a second series); when the series already holds that slot it writes nothing (the scenario "Occurrence delete whose slot the series already holds"); an absolute-date alarm of the series becomes an alarm at the occurrence's start, and the undo text names `absolute_alarms` (for a batch member that wrote its one-off event, the batch's undo text names it once, from what the member's undo returned, #323); `undo_history` lists the record as `Deleted occurrence of event: <title> (undo restores it as a one-off event)`

#### Scenario: Delete of a whole series that holds no exceptions (#244, #285)
- **WHEN** undo meets the record of a `delete_event` (or a `delete_events_batch` member) with span "future" that started at the series' first occurrence, after which the series' identifier no longer resolved, or with span "all", and the record holds no exceptions of the series because they could not be checked when the series was deleted (the series had no identifier or calendar, or none of its occurrences was listed inside the delete window)
- **THEN** it recreates the series from the recorded snapshot, rules included; occurrences deleted or edited on their own before the delete are not part of the snapshot, so they come back as plain occurrences of the series (an edited one without its edit), and the undo text says the series was restored from its rules and that its exceptions were not checked (a batch's undo text says it once, from what the members' undos returned, and says how many series when more than one did so, #323); `undo_history` lists the record as `Deleted event: <title> (undo recreates the series from its rules: occurrences deleted on their own earlier come back, edited ones without their edits)`, and a batch record that holds such members as `Batch (<N> operations; undo recreates <K> series from its rules: occurrences deleted on their own earlier come back, edited ones without their edits)` (`their rules` when K is more than one, `1 operation` when N is one), K counting only the members that hold no exceptions, at any depth, unless the batch also holds, at any depth, a member whose undo is refused (the scenario above), when it is listed as `Batch (<N> operations; undo not available: a member deleted an occurrence and the following ones of a recurring event)`

#### Scenario: Delete of a whole series restores its exceptions (#285)
- **WHEN** undo meets the record of a `delete_event` (or a `delete_events_batch` member) with span "future" that started at the series' first occurrence, after which the series' identifier no longer resolved, or with span "all", and the record holds the series' exceptions: the occurrences that existed, and the occurrences edited on their own, over the series' delete window (`deleteWindow`, #319: at most 1460 days, one EventKit query, starting three years (1094 days) before the delete or one day before the first occurrence, whichever is later, and moved earlier when the rule ends sooner so that it ends one day after the end of the rule, a count's end being the latest slot it can reach, which moves the window earlier but does not cut it, a count whose end cannot be shown placed as open-ended, and any count whose window around the delete starts after its first occurrence also listed over the window from its first occurrence, both windows recorded and every judgment made inside either; a record with two windows is listed as `within the checked windows (from … up to …, and from … up to …)`), listed before the delete removed anything; only the series' own occurrences are snapshotted
- **THEN** it recreates the series from the recorded snapshot, rules included; then, inside the recorded window only, it removes every occurrence of the recreated series whose slot (compared to the second) is not the slot of an occurrence that existed and was not edited on its own before the delete, using the two-pass removal and compensating delete of `excluded_occurrence_dates` (#182), so an occurrence deleted on its own earlier stays deleted; and it recreates each occurrence that was edited on its own as a one-off event at its own (edited) start, with its own fields; the slot the rule gave it (taken from the `/RID=` of its event identifier or external identifier, else from its occurrence date or, without one, its start, read as the requirement on an edited occurrence's recorded slot reads it) is what decides whether it is inside the window; the undo text names how many occurrences stayed deleted and how many edited occurrences came back as one-off events that no longer belong to the series; `undo_history` lists a single record as `Deleted event: <title> (undo recreates the series and its exceptions within the checked window (from <start> up to <end>): occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events; not for a first occurrence edited or deleted on its own, one moved more than a year outside the checked window or windows, or a record that does not match the recreated series)`, and a batch record that holds such members as `Batch (<N> operations; undo recreates <K> series and their exceptions within the checked window or windows: occurrences deleted on their own earlier stay deleted, edited ones come back as one-off events; not for a first occurrence edited or deleted on its own, one moved more than a year outside the checked window or windows, or a record that does not match the recreated series)` (`its exceptions` when K is one, `1 operation` when N is one), joined with the clause of the scenario above by `; ` when the batch holds members of both kinds; a batch undo names this once, with totals over the members whose undo returned that their exceptions were applied (how many series, how many occurrences stayed deleted, how many came back as one-off events, and in how many the first occurrence was kept from the rule) and, separately, how many series' recorded exceptions did not match, built from what each member's undo returned and never from its text or its record (#323); a batch undo that stops part-way says the same for the members it restored

#### Scenario: Occurrences outside the checked window (#285)
- **WHEN** undo restores a series with recorded exceptions and the series has occurrences outside the recorded window (a series that began more than three years before the delete, an open-ended series, a rule longer than 1460 days, or an occurrence edited or deleted on its own outside it)
- **THEN** it does not remove or recreate anything outside the window or windows, so those occurrences are whatever EventKit generates from the rules, and the undo text says that exceptions outside the checked window (or windows) are not restored, names each window's start and end to the minute and how it is placed, and says whether the series has occurrences before it, after it, or both, or may have occurrences after it (a count whose end is only bounded or cannot be shown) (#319); a record with two windows (a count) says instead that the series may have occurrences outside those windows, between them where they do not meet and after them; a batch undo states how the window or windows are placed, without days

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
- **WHEN** undo has recreated a series with recorded exceptions and the recorded slots do not describe it: no occurrence of the recreated series is listed, a recorded slot is not generated, or the series' own first slot is inside the recorded window and not generated (a first slot before the window cannot be listed and is not required, #319)
- **THEN** nothing is removed and no one-off event is created, the series stands as its rules made it, and the undo text says the recorded exceptions did not match and none was applied; an empty listing at delete time is not recorded as "no exceptions" but as not listed

#### Scenario: Cleanup fails after restoring the exceptions fails (#285)
- **WHEN** restoring the exceptions fails and the recreated series is deleted again, but a one-off event created before the failure cannot be removed
- **THEN** the error says the series was deleted again and that an occurrence remains in the calendar (to check before a retry, which would add it again); it does not say the series exists. A one-off whose save threw and that cannot be removed is reported as possibly remaining, because it may never have been written

#### Scenario: Occurrence delete whose slot the series already holds (#285, #321)
- **WHEN** undo meets the record of a `delete_event` with span "this" (or such a member of a `delete_events_batch`), whose record names the series the occurrence belonged to and the slot its rule gave it, and the calendar of the snapshot already holds an occurrence of that series (an event with rules of its own, detached, or with a `/RID=` identifier; not a plain one-off event) whose own rule slot is that slot (to the second; listed a year on each side of the slot, so an occurrence edited and moved to another day counts) or of a series that an undo of its whole-series delete recreated in this server process, as when the series was restored from its rules before this record
- **THEN** it writes nothing, answers success with a text saying the occurrence is already restored by its series (for an occurrence edited on its own before its delete, that its slot is held as the rules give it and its edit did not come back), and the record is used up; the title is not compared, so a recurring event of another series with the same title at that time does not hold the slot, and an occurrence retitled or moved before its delete is matched by its slot; a one-off event is created only when no such occurrence holds the slot; in a batch, the batch's undo text counts such members as already restored by their series and names no `absolute_alarms` for them (#323)

#### Scenario: Occurrence record that does not name its series (#321)
- **WHEN** undo meets the record of a deleted occurrence (an occurrence delete, or the rule-less whole-series delete of an occurrence edited on its own) that holds no series identifiers or no slot (none could be read when it was deleted)
- **THEN** it writes the occurrence as a one-off event without checking whether a series holds its slot, and the undo text says the record does not say which series it belonged to and to check Calendar for a second event at that time; a batch's undo text, and a batch undo that stops part-way, count such members and say the same

#### Scenario: Edited occurrence deleted by its own identifier beside its series (#321)
- **WHEN** undo meets the rule-less record of a whole-series delete addressed by the identifier of an occurrence edited on its own (`delete_events_batch` with that identifier and the series' own, span "all"), and the series, or a series recreated from it, already holds the occurrence's slot
- **THEN** it writes nothing and answers as for an occurrence whose slot the series already holds; undo runs a batch's members newest first, so the series' member restores the series before; when the series' member failed and is retried last, the occurrence's member runs first and writes its one-off event

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
- **THEN** the record is put back holding only the members not yet restored, under the same id and timestamp, with the failing member placed to run last, so the next undo restores the members never attempted before it retries the failing one (each member restores one new item and reads no other member's result, with one exception: the duplicate guard of a deleted occurrence's record, and of the rule-less record of an occurrence edited on its own and deleted by its own identifier, sees a series only once it is recreated, so it relies on the series running first, as it does in record order reversed; when the series' member failed and is moved to run last, the occurrence's member runs first on the retry and writes its one-off event, and a series then restored from its rules alone brings that slot back too, one visible duplicate (scenario "Edited occurrence deleted by its own identifier beside its series"); a series member whose exceptions restore failed and whose compensating delete failed too is the one member that throws a permanent error, and is dropped); if the failing member's calendar or list is by then missing or read-only, the next undo is refused whole by the pre-check instead; a member whose error is permanent would be dropped and the members never attempted kept, and with none left the record discarded (the series member described above is the one write that does); the error says how many were restored and how many remain and names what the members it restored did not restore as they were (an occurrence's absolute-date alarm, a series recreated from its rules alone, the fields a new store holds differently for a reminder whose save reported a failure but was found, #261), which the retry's text does not repeat

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


<!-- @trace
source: idd-542-archive-series-exceptions
updated: 2026-11-23
code:
  - Tests/CheICalMCPTests/SeriesExceptionsSpecDocsTests.swift
-->

---
### Requirement: Records follow an identifier this server's calendar change gave

Among the writes that change an event's calendar, only the writes of this server listed here SHALL move records: an in-place move of `move_events_batch` and the undo of that move; `update_event` when all five conditions below hold; and the undo of an `update_event` on a one-off event that the update left one-off, with or without `keep_later_edits`. The undo of a delete moves records under the requirement "Records follow an item the undo of its delete recreated", and under no other rule. When one of these writes moves an event to another calendar and the store gives the event a new identifier, the server SHALL move every undo and redo record that names the event by its old identifier to the new one, so that an older record still finds the event. Any other write that gives an event a new identifier, other than the undo of a delete under that requirement, SHALL NOT move records. One such write is `update_event` with span `future` from the series' first occurrence and `calendar_name`: it fails condition 2, so no record follows, although within a Google account it moved the whole series under a new identifier and the undo of the series' creation then answered not found (#551). A removed identifier held by a delete record SHALL NOT be touched. The identifier comparison SHALL treat a series identifier and an occurrence identifier of that same series as the same identifier, and SHALL treat an empty identifier as no change.

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
source: idd-docs-verify-leftovers
updated: 2026-11-18
code:
  - README_zh-TW.md
  - README.md
  - CHANGELOG.md
-->

---
### Requirement: An edited occurrence's recorded slot is read as an instant, and a whole-series delete forecasts its undo

An occurrence edited on its own may carry its original time after `/RID=` in its event identifier or external identifier. If neither supplies a readable RID, the slot reader falls back to the occurrence date or start. Measured on iCloud (#539), when the occurrence was edited while its timed series had no time zone that time is wall-clock time written as UTC; otherwise it is an instant, and one series can hold both. Every undo SHALL read that time as `main` before #539 reads it (as an instant; an all-day one as its local day): the undo of a whole-series delete, with its capture, restore, consistency check, placement of one-off events, removal of surplus slots and counts, and the check of #321 whether a restored series holds the slot of a deleted occurrence, in the undo of one occurrence's delete and of a split move's source. PR #558 read the time both ways in rounds 0 to 4, in the whole-series undo and then in the check of #321, and each verify round found a shape in which that did worse than `main`. On a host not at offset 0, the record of an occurrence edited while its series had no time zone is then usually no slot of the recreated series, and the undo applies none of the series' exceptions and says the recorded exceptions did not match; in some shapes the record is a slot and is applied, and in some the calendar after the undo has two events at one start. These are `main`'s results; #539 stays open for them.

A whole-series delete SHALL use its own recorded capture for the forecast without additional store reads. It SHALL parse the forecast anchor and expand the rule only for a recorded whole-series delete and only after any structural batch refusal has been accounted for. When it records a whole-series delete, it SHALL report an `undo_note` with the count of captured edits absent from the predicted restore listings, provided the forecast can model those listings and the count is positive. A real `delete_events_batch` SHALL give it in `rules_alone_on_undo` and omit all forecast rows if the batch includes a recorded delete of an occurrence and the following ones that makes the batch undo refuse. The forecast is computed from the recurrence rule. The store may list different slots at undo. The undo itself SHALL check the actual recreated series with the listed occurrences' occurrence dates or starts before attempting exception writes.

The forecast SHALL model each recorded window from a proven stored first slot, positive finite duration, and one simple daily or weekly rule in an unchanged recurrence time zone at undo. A weekly rule with more than one distinct weekday is outside the model. The 20,000-slot limit applies to expansion from the first slot to one second past the last recorded window, before filtering to those windows. The projection SHALL exclude a start exactly at the window end and abstain within one second of that edge when the times differ. Uncertain window starts, overlapping end times at the window start and rule starts on the local rule-end day also cause abstention. The forecast SHALL compare the in-window anchor and kept slots before counting absent edit slots. Other reasons it can abstain include a stand-in or unproven first slot, failed capture or no detached record, an unfollowed rule, an offset change and a kept slot absent from the projection. A delete without the note can still come back from its rules alone.

With span `all`, a batch dry run SHALL use the existing requested-ID state to answer each ordinary preview row and separate series identities to decide whether to forecast. A forecast key keeps the identifier through the part before `/RID=`, or the whole identifier when that marker is absent. The preview SHALL skip a forecast after a successful earlier row of the same series or after a successful earlier row whose series cannot be identified. A requested ID that differs from the resolved ID without an external identifier tying the row to a series counts as unknown, as does the first-edited-occurrence deletion route. The preview SHALL decide from the event, capture windows and call state whether to admit a forecast capture, and admit at most 16 additional store listings per call for that purpose. A later delete may use a differently placed capture window. A dry run with span `future` gives no forecast.

#### Scenario: A floating edit comes back as on main

- **WHEN** a weekly timed series has no time zone, a later occurrence is retitled and another later occurrence is moved and both edits are captured using the slots as recorded, then the whole-series delete is undone
- **THEN** the undo leaves the calendar and answer `main`'s run of the same sequence leaves: if the instant reading leaves either record off the recreated rule, the series comes back from its rules and the undo text says the recorded exceptions did not match; when both records match listed slots and the capture passes the consistency check, undo attempts to restore matching edits as one-off events, skipping edits at the recreated first slot and applying the existing rollback handling if a write fails

##### Example: a floating edit comes back as on main

- **GIVEN** six weekly occurrences at 10:00 in each of `Asia/Taipei`, `America/Los_Angeles` and `UTC`, the third retitled and the fourth moved an hour while the series had no time zone
- **WHEN** the whole series is deleted and the delete is undone, through this server and through `main`
- **THEN** both leave the same calendar and answer: at `Asia/Taipei` and `America/Los_Angeles` the outcome is not applied and the six slots are back; at `UTC` it is restored with exceptions, 0 stayed deleted and 2 one-off events

##### Example: H1

- **GIVEN** a host at `+08:00`, a daily series at 06:00 with no time zone, its second occurrence retitled, the whole series then moved one day later, and the new first occurrence deleted on its own, the series object refreshing
- **WHEN** the whole series is deleted and the delete is undone
- **THEN** the calendar and the answer are `main`'s

#### Scenario: A series with a time zone is read as before

- **WHEN** a series has a time zone, one occurrence is retitled, the whole series is moved later the same day, and the series is deleted whole and the delete undone, or the retitled occurrence is deleted through its own identifier and that delete undone
- **THEN** the identifier is read as an instant only, and the undo does what it does on `main`

##### Example: S1

- **GIVEN** a host at `Asia/Taipei` and a daily series at 06:00 with time zone `Asia/Taipei`, its second occurrence retitled, then the whole series moved to 22:00 the same day
- **WHEN** the whole series is deleted and the delete undone
- **THEN** the series comes back from its rules alone with all six occurrences, and the undo text says the recorded exceptions did not match

#### Scenario: An edit made while the series had its zone

- **WHEN** a later occurrence is retitled while its series has a time zone, the zone is then cleared without changing the generated slots, another later occurrence is deleted on its own, and the whole-series delete is undone with both slots within the recorded window and the capture passing the consistency check
- **THEN** the edit comes back as a one-off event and the deleted occurrence stays deleted, as on `main`

#### Scenario: The undo of an occurrence's delete after its series was restored

- **WHEN** an occurrence edited on its own was deleted, the whole series was deleted and restored, and the occurrence's delete is undone
- **THEN** the calendar and both answers, outcomes and texts, are those of `main`'s run of the same sequence

##### Example: C1 the older record writes its edit as on main

- **GIVEN** a weekly series with a time zone, its second and fourth occurrences retitled, its zone then cleared at the same times, the second deleted through its own identifier, then the whole series deleted, on a host at `+08:00`, `-08:00`, `+05:45` or UTC
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s: the series comes back with the fourth as a one-off and the second's slot empty, and the second undo writes the second occurrence once with its edit

##### Example: C1 no second event after a move

- **GIVEN** the same series moved three hours later after the second occurrence was edited and before the fourth was, then given no time zone, the second deleted through its own identifier, then the whole series deleted
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s, with no two events at one start

##### Example: MA is as on main

- **GIVEN** the second and fourth occurrences of a weekly series edited while it had no time zone, the second deleted through its own identifier, then the whole series deleted, on a host at `+08:00`, `-08:00`, `+05:45` or UTC
- **WHEN** the series' delete is undone and then the second occurrence's delete
- **THEN** the calendar and both answers are `main`'s: away from offset 0 two events at the second occurrence's start, `main`'s own; at UTC one

#### Scenario: The delete forecasts a restore from the rules alone

- **WHEN** the delete records a whole series and its captured edit has a slot absent from the eligible model of the restore listings, with in-window anchor and kept slots accounted for
- **THEN** the answer forecasts that undo applies none of the recorded exceptions, with the count, and a real batch lists the series row in `rules_alone_on_undo` unless a recorded structural refusal suppresses the batch's forecast
- **AND** an eligible span `all` preview shows the note in the series row and in returned date-range rows that inherit its answer

##### Example: the delete forecasts a floating edit

- **GIVEN** six weekly occurrences at 10:00 before any offset change, its first slot proven, the third retitled and the fourth moved while the series had no time zone, both edits captured inside the modelled window
- **WHEN** the whole series is deleted
- **THEN** the forecast counts both edits at `Asia/Taipei` and `America/Los_Angeles`, and gives no note at UTC

##### Example: the dry run skips a series after deleting its edited first occurrence

- **GIVEN** a batch preview names the first edited occurrence and its series, and the requested ID for the occurrence resolves to a different ID
- **WHEN** the first row previews a deletion and the ordinary series preview picks a stand-in as on main
- **THEN** the series row keeps the ordinary preview answer and the forecast reads no capture for it

##### Example: the dry run identifies an opaque occurrence by its external identifier

- **GIVEN** a preview's earlier deleting row has an opaque occurrence ID and an external identifier shared with the series through its RID suffix
- **WHEN** the preview reaches the series and an unrelated series
- **THEN** it skips the earlier row's series and can forecast the unrelated one

##### Example: the dry run skips later forecasts after an unidentified earlier row

- **GIVEN** a preview's earlier deleting row was requested by a RID from an old series identifier but resolved to a different identifier without an external series key
- **WHEN** the preview reaches later rows
- **THEN** those rows still have their ordinary preview answers and no forecast is attempted

##### Example: the daily rule starts exactly at the window end

- **GIVEN** a simple open daily rule with a stable offset and a projected start exactly at the end of the delete window
- **WHEN** the forecast checks the projected listing
- **THEN** it excludes that start and can count the missing slot of an edited occurrence within the window


<!-- @trace
source: idd-539-fix7
updated: 2026-11-22
code:
  - .claude/rules/mcp-binary-version-testing.md
  - CHANGELOG.md
  - README.md
  - README_zh-TW.md
  - Sources/CheICalMCP/EventBatchDeletionSource.swift
  - Sources/CheICalMCP/EventDeletionSource.swift
  - Sources/CheICalMCP/EventKit/DeleteUndo.swift
  - Sources/CheICalMCP/EventKit/DeletedOccurrenceCheck.swift
  - Sources/CheICalMCP/EventKit/EventKitManager+SeriesExceptions.swift
  - Sources/CheICalMCP/EventKit/EventKitManager.swift
  - Sources/CheICalMCP/EventKit/SeriesExceptions.swift
  - Sources/CheICalMCP/EventKit/SeriesExceptionsStoreSource.swift
  - Sources/CheICalMCP/EventKit/SeriesExceptionsUndo.swift
  - Sources/CheICalMCP/Server.swift
  - Tests/CheICalMCPTests/DeleteUndoFollowWiringTests.swift
  - Tests/CheICalMCPTests/DetachedOccurrenceSpanTests.swift
  - Tests/CheICalMCPTests/EventRangeQueryTests.swift
  - Tests/CheICalMCPTests/FloatingSeriesUndoMatrixTests.swift
  - Tests/CheICalMCPTests/Helpers/FakeSeriesExceptionsStore.swift
  - Tests/CheICalMCPTests/Helpers/SeriesUndoOnMain.swift
  - Tests/CheICalMCPTests/ManifestParityTests.swift
  - Tests/CheICalMCPTests/OccurrenceOriginWiringTests.swift
  - Tests/CheICalMCPTests/SeriesDeleteForecastHandlerTests.swift
  - Tests/CheICalMCPTests/SeriesDeleteForecastTests.swift
  - Tests/CheICalMCPTests/SeriesDeleteForecastWiringTests.swift
  - Tests/CheICalMCPTests/UndoBatchWiringTests.swift
  - Tests/CheICalMCPTests/UndoForecastDocsTests.swift
  - Tests/CheICalMCPTests/WholeSeriesUndoChainOnMainTests.swift
  - Tests/CheICalMCPTests/ZonedSeriesUndoOnMainTests.swift
  - mcpb/manifest.json
-->

---
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


<!-- @trace
source: idd-540-fix1
updated: 2026-11-23
code:
  - Tests/CheICalMCPTests/UndoChangedSourceTests.swift
  - Sources/CheICalMCP/EventKit/UndoGuardErrors.swift
  - README.md
  - CHANGELOG.md
  - README_zh-TW.md
  - Sources/CheICalMCP/Server.swift
  - Tests/CheICalMCPTests/UndoChangedSourceDocsTests.swift
  - docs/UNDO_HISTORY.md
  - mcpb/manifest.json
-->

---
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

<!-- @trace
source: idd-540-fix1
updated: 2026-11-23
code:
  - Tests/CheICalMCPTests/UndoChangedSourceTests.swift
  - Sources/CheICalMCP/EventKit/UndoGuardErrors.swift
  - README.md
  - CHANGELOG.md
  - README_zh-TW.md
  - Sources/CheICalMCP/Server.swift
  - Tests/CheICalMCPTests/UndoChangedSourceDocsTests.swift
  - docs/UNDO_HISTORY.md
  - mcpb/manifest.json
-->