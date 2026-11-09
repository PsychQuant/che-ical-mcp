## Purpose

Keeps a failed write of an existing reminder or reminder list from landing later: such writes commit on a separate, short-lived store, so a failure is dropped with that store and never reaches the server's long-lived store.

## ADDED Requirements

### Requirement: A failed write of an existing reminder or list does not stay pending in the long-lived store

The server SHALL commit every write of an existing reminder or reminder list on a separate write store: an update, a completion, a removal, a rename or recolor of a list, a removal of a list, and every undo and redo of a reminder. It SHALL look the object up by its identifier on the write store and copy onto it, from the object the caller changed, only these fields: for a reminder `title`, `location`, `notes`, `url`, `timeZone`, `startDateComponents`, `dueDateComponents`, `priority`, `isCompleted`, `completionDate`, `alarms`, `recurrenceRules` and `calendar`; for a list `title` and `cgColor`. It SHALL build alarms and recurrence rules as new objects with the same values, and SHALL write a field only when its value differs. When the commit fails, the write store SHALL be dropped and the caller's object SHALL be rolled back, so nothing of the failed change is committed later by the long-lived store. When the commit succeeds, the caller's object SHALL be rolled back and refreshed, so it reads the committed values. Creates, including the #237 second save of a create, and every write of an event or an event calendar SHALL stay on the long-lived store.

#### Scenario: A failed update, then another write

- **GIVEN** an update of an existing reminder whose commit on the write store fails
- **WHEN** another reminder is saved afterwards
- **THEN** a fresh store reads the first reminder unchanged

#### Scenario: A successful update

- **GIVEN** an update of an existing reminder that commits on the write store
- **WHEN** the call returns
- **THEN** the caller's object reads the new values and has no unsaved changes

#### Scenario: A create

- **WHEN** a reminder is created
- **THEN** it is saved on the long-lived store

---
### Requirement: One write store per call, at most four open

Each call SHALL use one write store, opened when its first write needs it and released when the call ends; a batch call (`delete_reminders_batch`, `cleanup_completed_reminders`, an undo or redo of a batch record) SHALL share one write store across its rows, through a lease bound to the call's task and not shared with other calls. After any write in a lease fails, the lease SHALL replace its store before the next write. At most four write stores SHALL be open at once; when four are open, a call that needs another SHALL be refused with an error, and a fifth SHALL NOT be opened.

#### Scenario: A batch with a failed row

- **GIVEN** a batch removal whose second row fails at commit
- **WHEN** the third row is removed
- **THEN** it commits on a new write store, and the second row's change does not land

#### Scenario: The pool is full

- **GIVEN** four write stores open
- **WHEN** another call needs one
- **THEN** it is refused with an error and no store is opened

---
### Requirement: A lookup the write store cannot answer is a store error

When the write store does not return the object, or the calendar it is moved to, for an identifier the caller holds, the server SHALL report a store error that says nothing was written, and SHALL NOT report the reminder or list as not found.

#### Scenario: The write store cannot see the reminder

- **GIVEN** an existing reminder the long-lived store holds
- **WHEN** the write store returns nothing for its identifier
- **THEN** the call fails with a store error, not "not found", and nothing is written
