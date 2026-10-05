# Unblocking undo history

A missing event or reminder does not prove permanent deletion. Normal undo retains transient failures so a source or permission problem can be repaired and retried.

Undo also refuses, and keeps the record, when the item was changed after the operation in a way the undo would overwrite or delete (#236): the error names the changed fields. Whoever made the change decides: ask the user whether to change it back and undo again, or to give up that undo and discard the record as below. Three create-undo refusals leave only the choice whether to discard: occurrences of a series edited on their own (`modified_occurrences`), which cannot be put back into the series; a series whose occurrences could not be checked (`unchecked_occurrences`, the series has no identifier or calendar); and a series whose rule was shortened (`recurrence`; an update or delete of an occurrence and the following ones does this), whose cut-off part cannot be put back. Any other change of the rule can be changed back, so it is an ordinary refusal.

Four refusals discard the record themselves, so older records stay reachable:
1. a recurring reminder completion whose identifier now resolves to another occurrence (#204);
2. a completion recorded without an occurrence snapshot when the reminder still repeats with the opposite completion;
3. any `update_event` that touched a recurring event (one occurrence, also a detached occurrence addressed by its own id, span "future" or "all", or rules added or removed), listed as `Updated recurring event: <title> (undo not available)` and never undone;
4. an `update_event` or a one-off `move_events_batch` move recorded on a one-off event when that event repeats, or is an edited occurrence, by the time of the undo; a move of an item that was already an edited occurrence is always refused this way. Revert a move by moving the event back.

For 3 and 4, revert the change in Calendar if it should be reverted; a safe restore is tracked in #263.

To intentionally abandon the newest record, call undo_history, inspect the first entry, and pass its id to undo as discard_id. Example: `{"discard_id":"<id returned by undo_history>"}`. This removes only that current top record. It does not edit events/reminders and does not add a redo record; discarding history cannot be undone. Existing redo records are preserved.

The server rejects malformed IDs, stale IDs, an empty stack, and discard requests while undo/redo is running. Read undo_history again after a stale error; do not blindly reuse an ID. IDs are stable across a failed undo and expire when records are discarded, evicted or the process restarts. Event, reminder and batch records follow the same rule. The UUID selects a record; it does not grant additional access.
