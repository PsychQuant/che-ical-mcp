## ADDED Requirements

### Requirement: Stable history identity
The server SHALL expose an id for each undo history entry, stable across pop and restore. History entries and counts SHALL come from one actor snapshot.

#### Scenario: History entry is retried
- **WHEN** an undo fails and its record is restored
- **THEN** its id equals the previously listed id

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

### Requirement: Stale and busy protection
The manager SHALL reject removal from an empty stack, removal with a nonmatching id, and removal during an active undo or redo. Failure SHALL leave both stacks unchanged. Normal not-found errors SHALL preserve the history record for retry.

#### Scenario: Repeated discard
- **WHEN** the same id is submitted after its record was removed
- **THEN** the second request fails and the next record remains intact

#### Scenario: Concurrent history execution
- **WHEN** undo or redo has begun and not finished
- **THEN** discard and another begin request fail with a busy error
