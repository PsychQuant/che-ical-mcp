## ADDED Requirements

### Requirement: `EventKitManaging` protocol exposes only the methods currently tested

The shim protocol SHALL declare only the EventKit surface that at least one landed test file invokes. Adding a method to the protocol WITHOUT a corresponding test use SHALL be rejected in review.

#### Scenario: Initial shipment contains exactly the cleanup-handler surface

- **WHEN** this change lands
- **THEN** `EventKitManaging` declares exactly three methods: `listReminders(completed:calendarName:calendarSource:)`, `deleteRemindersBatch(identifiers:onlyCompleted:)`, `requestReminderAccess()`

#### Scenario: Protocol expansion requires a landing test

- **WHEN** a future change adds a method to `EventKitManaging`
- **THEN** the same change MUST add at least one test in `Tests/CheICalMCPTests/` that invokes the new method via `FakeEventKitManager`

### Requirement: `CheICalMCPServer.init` accepts an injected `EventKitManaging` with production default

Dependency injection SHALL use a default-argument initializer. Production code SHALL NOT need to change its instantiation.

#### Scenario: Production instantiation unchanged

- **WHEN** `main.swift` (or any production caller) invokes `CheICalMCPServer()` with no arguments
- **THEN** the server uses `EventKitManager.shared` as its `EventKitManaging` dependency

#### Scenario: Test instantiation injects fake

- **WHEN** a test invokes `CheICalMCPServer(eventKitManager: FakeEventKitManager(...))`
- **THEN** the server uses the supplied fake for every call it would otherwise make on `.shared`

### Requirement: `FakeEventKitManager` is scriptable per test

The fake SHALL allow each test to pre-configure: what `listReminders` returns (including empty, duplicates, mixed completed/incomplete), whether `deleteRemindersBatch` succeeds per-ID, and whether `requestReminderAccess` throws.

#### Scenario: Scripted `listReminders` return values

- **WHEN** a test sets `fake.listRemindersResult = [reminderA, reminderB]`
- **AND** the handler under test calls `listReminders`
- **THEN** the fake returns `[reminderA, reminderB]`

#### Scenario: Invocation recording for assertions

- **WHEN** the handler calls `deleteRemindersBatch(identifiers: ["x", "y"], onlyCompleted: true)`
- **THEN** the fake records the call so the test can assert on both the identifiers passed and the `onlyCompleted` flag

##### Example: Binding-mode onlyCompleted assertion

- **GIVEN** a fake with `listRemindersResult = [completed("a"), notCompleted("b")]`
- **WHEN** the test calls `handleCleanupCompletedReminders` with `reminder_ids: ["a", "b"], dry_run: false`
- **THEN** the fake records `deleteRemindersBatch(identifiers: ["a", "b"], onlyCompleted: true)`
- **AND** the returned `BatchDeleteResult` has `failures` containing `b` with message `"Reminder is no longer completed"`

### Requirement: `CleanupHandlerTests` pins documented contract invariants

The test file SHALL include at least one test case per invariant established in #21 and #28 so a future refactor that breaks one fails loudly.

#### Scenario: R2-F2 arithmetic invariant pinned

- **WHEN** a cleanup call returns a response with `total`, `deleted_count`, `failures.count`, and `remaining`
- **THEN** the test asserts `total == deleted_count + failures.count + remaining` across at least one test case with deduplication and one with partial failures

#### Scenario: #28 F1 onlyCompleted invariant pinned

- **WHEN** a binding-mode call includes an identifier whose underlying reminder `isCompleted == false`
- **THEN** the test asserts the response's `failures[]` contains that identifier with a message indicating it is no longer completed
- **AND** the test asserts the reminder was NOT passed to `eventStore.remove`

#### Scenario: F1 guard ordering pinned at integration level

- **WHEN** a filter-mode call supplies `calendar_source` without `calendar_name`
- **THEN** the test asserts `ToolError.invalidParameter` is thrown
- **AND** the test asserts `listReminders` was never called on the fake

#### Scenario: F8 3-branch response shape stability pinned

- **WHEN** the handler returns from any of the three response branches (dry-run, execute-empty, execute-non-empty)
- **THEN** the response JSON contains the stable key set: `dry_run`, `mode`, `total`, `deleted_count`, `deleted_ids`, `failures`, `remaining`

### Requirement: Test infrastructure has zero production runtime impact

The production binary SHALL behave identically before and after this change.

#### Scenario: No new dependencies in release build

- **WHEN** `swift build -c release` is run
- **THEN** the binary's linked module list is unchanged aside from protocol declarations in existing modules

#### Scenario: No new Swift warnings

- **WHEN** `swift build` is run at HEAD after this change
- **THEN** no new warnings are emitted compared to the pre-change baseline

### Requirement: Existing `EventKitManager` call sites outside the cleanup handler are NOT refactored in this change

Fifteen-plus direct `eventKitManager.` call sites in `Server.swift` SHALL remain using the singleton directly. Retrofitting them is deferred to future changes that introduce their own handler tests.

#### Scenario: Non-cleanup handlers continue using the singleton directly

- **WHEN** a handler other than `handleCleanupCompletedReminders` (e.g., `handleCreateEvent`, `handleListEvents`) is invoked
- **THEN** the code path is unchanged relative to the pre-change baseline
- **AND** `swift test` shows no regression in pre-existing handler-adjacent tests
