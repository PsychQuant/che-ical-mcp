## ADDED Requirements

### Requirement: Changed-after refusal names the sources it cannot tell apart

When an undo or a redo is refused because a field the write would overwrite or delete was changed after the recorded operation (for a redo, after the undo), and the change can be changed back, the error SHALL NOT claim one source of the change: the post-state check compares the item with the recorded state and does not know who changed it. The error SHALL name, as possible sources, another app, the calendar server, and this server's own later operations that have no entry in the history now: for an undo, a later operation without an entry in the undo history (for example one whose entry was given up with `discard_id`); for a redo, a later operation or undo without an entry in the redo history. For a reminder the error SHALL also name a failed write of this server that landed later (#274). The error SHALL NOT tell the reader that whoever made the change decides; it SHALL ask the user whether to change the field back or to give up the undo, as before. Nothing else about the refusal changes: nothing is written and the record is kept.

#### Scenario: Older record refused after the later record was discarded

- **WHEN** an event is created, then moved to another calendar with `move_events_batch`, the move's entry is given up with `discard_id`, and undo then meets the create record
- **THEN** the undo is refused naming `calendar`, nothing is written, the record is kept, and the error names another app, the calendar server and a later operation of this server without an entry in the undo history as possible sources, and does not say "Whoever made the change"

#### Scenario: Reminder refusal keeps the failed-write source

- **WHEN** the undo of a reminder record is refused because its title was changed after the operation
- **THEN** the error names another app, the calendar server, a later operation of this server without an entry in the undo history, and a failed write of this server that landed later
