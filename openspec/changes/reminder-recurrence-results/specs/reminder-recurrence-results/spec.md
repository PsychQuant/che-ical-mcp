## ADDED Requirements

### Requirement: Read recurrence metadata without changing legacy fields

The list and search reminder handlers SHALL emit has_recurrence, recurrence_rules and due. Rules SHALL retain ordinal weekdays, all public integer selectors and termination constraints. Existing event output and reminder envelopes SHALL remain unchanged.

#### Scenario: Last Monday of each month
- WHEN a rule uses Monday with weekNumber -1
- THEN the output retains both the weekday and its negative ordinal.

#### Scenario: Floating or date-only due date
- WHEN the due components do not specify a timezone or time
- THEN due.date_time is null and available wall-clock components are retained.

### Requirement: Separate write outcome from observed reminder state

A successful save SHALL return operation.status succeeded even when the returned reminder is incomplete. The handler SHALL preserve legacy action and is_completed semantics. Reopening SHALL be identified by operation.type reopen.

#### Scenario: Recurring reminder advances on save
- WHEN a save succeeds and its object advances to an incomplete occurrence
- THEN the response reports the completed operation independently of that object's state.

### Requirement: Report only observed successors

The completion result SHALL contain next_occurrence with confirmed, unknown or not_applicable status. confirmed SHALL require an observed, same-identity incomplete reminder with a valid later due date and matching recurrence/calendar; a rule whose occurrence_count is exactly one lower with every other field equal SHALL count as matching, since a rollover lowers it on iCloud (#429). The observation that decides the status SHALL be taken once, synchronously, from the saved object before any suspension point; the handler SHALL NOT poll or force a refresh for it. A confirmed result MAY add one re-read in that same synchronous stretch, for the next occurrence's relative alarms only (#423). Missing, ambiguous or unchanged observations SHALL be unknown. A failed observation SHALL NOT repeat the write or report the successful write as failed.

#### Scenario: No successor can be identified
- WHEN completion saves successfully but the known ID cannot identify a successor
- THEN next_occurrence.status is unknown and operation.status remains succeeded.

### Requirement: Identity-guarded undo/redo for recurring completions

A recurring completion whose pre-write snapshot has a due and rules SHALL be recorded with that snapshot. Undo and redo SHALL refresh the store, resolve the recorded identifier and act only when the current item still matches the recorded occurrence identity (id, list, source, due, rules; completion state and title excluded). When the identifier resolves to a different occurrence, the operation SHALL fail with an explicit message and the history entry SHALL be discarded, never re-appended. When the item cannot be found, the failure SHALL be transient and the entry SHALL be kept. A recurring snapshot without a due or without rules SHALL use the legacy identifier-keyed record.

#### Scenario: Identifier advanced to the next occurrence
- WHEN undo resolves the recorded ID to an item whose due differs from the snapshot
- THEN it refuses, reports the reason on the wire, and the entry is removed so earlier operations remain undoable.

#### Scenario: Unchanged occurrence
- WHEN undo resolves the recorded ID to an item matching the snapshot's identity
- THEN it restores the recorded completion state.
