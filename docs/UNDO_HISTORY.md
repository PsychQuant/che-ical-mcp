# Unblocking undo history

A missing event or reminder does not prove permanent deletion. Normal undo retains transient failures so a source or permission problem can be repaired and retried.

To intentionally abandon the newest record, call undo_history, inspect the first entry, and pass its id to undo as discard_id. Example: `{"discard_id":"<id returned by undo_history>"}`. This removes only that current top record. It does not edit events/reminders and does not add a redo record; discarding history cannot be undone. Existing redo records are preserved.

The server rejects malformed IDs, stale IDs, an empty stack, and discard requests while undo/redo is running. Read undo_history again after a stale error; do not blindly reuse an ID. IDs are stable across a failed undo and expire when records are discarded, evicted or the process restarts. Event, reminder and batch records follow the same rule. The UUID selects a record; it does not grant additional access.
