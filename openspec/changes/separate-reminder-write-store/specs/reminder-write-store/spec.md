## Purpose

Keeps a failed write of an existing reminder or reminder list from landing later: such writes commit on a separate, short-lived store, so a failure is dropped with that store and never reaches the server's long-lived store.

## ADDED Requirements

### Requirement: A failed write of an existing reminder or list does not stay pending in the long-lived store

The server SHALL commit every write of an existing reminder or reminder list on a separate write store: an update, a completion, a removal, a rename or recolor of a list, a removal of a list, and every undo and redo that changes or removes an existing reminder. It SHALL look the object up by its identifier on the write store. Of the closed field list (for a reminder `title`, `location`, `notes`, `url`, `timeZone`, `startDateComponents`, `dueDateComponents`, `priority`, `isCompleted`, `completionDate`, `alarms`, `recurrenceRules` and `calendar`; for a list `title` and `cgColor`) it SHALL write onto that object the fields whose value on the caller's object differs from the caller's object rolled back and the fields the request names (with the ones they derive), and SHALL NOT write any other field. It SHALL write start and due through `ReminderDateSync.restore`, with the write store's value for whichever of the two the call did not change, and the zone after them; it SHALL write alarms through `AlarmSnapshot.restore` against the write store's own alarms, and SHALL build recurrence rules as new objects with the same values. When the commit fails, the write store SHALL be dropped and the caller's object SHALL be rolled back, so nothing of the failed change is committed later by the long-lived store. When the commit succeeds, the caller's object SHALL be refreshed, so it reads the committed values. Creates, including the #237 second save of a create, and every write of an event or an event calendar SHALL stay on the long-lived store.

#### Scenario: A failed update, then another write

- **GIVEN** an update of an existing reminder whose commit on the write store fails
- **WHEN** another reminder is saved afterwards
- **THEN** a fresh store reads the first reminder unchanged

#### Scenario: A successful update

- **GIVEN** an update of an existing reminder that commits on the write store
- **WHEN** the call returns
- **THEN** the caller's object reads the new values and has no unsaved changes

#### Scenario: A field the call did not change

- **GIVEN** a reminder list whose color was changed through another store after the server last read it
- **WHEN** `update_calendar` renames it
- **THEN** the list has the new title and keeps the color changed elsewhere

#### Scenario: A create

- **WHEN** a reminder is created
- **THEN** it is saved on the long-lived store

---
### Requirement: One write store per call, at most four open

Each call SHALL use one write store, opened when its first write needs it and released when the call ends; a batch call (`delete_reminders_batch`, `cleanup_completed_reminders`, an undo or redo of a batch record) SHALL share one write store across its rows, through a lease bound to the call's task and not shared with other calls. After any write in a lease fails, the lease SHALL drop its store, and the next write SHALL use a new one. At most four write stores SHALL be open at once; when four are open, a call that needs another SHALL be refused with an error, and a fifth SHALL NOT be opened. A new store that sees no sources SHALL be refused the same way. A batch refused this way before any row is removed SHALL fail as a whole; a batch row that fails with a write-store error SHALL keep that error's own code (`write_store_busy`, `write_store_lookup_failed`, `write_store_read_back_failed`) and write a stderr line.

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

---
### Requirement: The saved reminder is read back under the identifier it has after the save

After a successful commit the server SHALL take the identifier from the write store's object. When it differs from the caller's identifier, the server SHALL resolve the reminder again by it on the long-lived store, and `update_reminder` SHALL build its read-backs, its response (`id`, `id_changed`, `previous_id`) and its undo record from that reminder. When the reminder cannot be read back after the save, the call SHALL first record its undo entry from what the write store's object held after the commit (for a list, the #273 marker), then fail with a store error that says the change was saved and where its undo is, and nothing SHALL be rolled back; an undo or redo whose save lands but cannot be read back SHALL count as done and SHALL say so.

#### Scenario: A move to a list in another account

- **GIVEN** an `update_reminder` whose save gives the reminder a new identifier
- **WHEN** the call returns
- **THEN** `id` is the new identifier, `id_changed` is true, and the undo record names the new identifier

#### Scenario: A requested value equal to a stale cache

- **GIVEN** a reminder whose title the server cached as A, and another store changed it to B
- **WHEN** `update_reminder` sets the title to A
- **THEN** the title is A, and the fields the request does not name keep their stored values

#### Scenario: A save that lands but cannot be read back

- **GIVEN** an `update_reminder` whose commit lands and whose read-back fails
- **WHEN** the call answers `writeStoreReadBackFailed`
- **THEN** the top undo record is this update, and undo reverts it rather than an older operation
