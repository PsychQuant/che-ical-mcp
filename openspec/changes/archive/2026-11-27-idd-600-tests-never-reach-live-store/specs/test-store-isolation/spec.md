## ADDED Requirements

### Requirement: No test reaches the live store or the shared undo history unless it opts in

Under XCTest, a DEBUG build SHALL stop the test process at each use of `EventKitManager.shared`, `CalendarUndoManager.shared`, `LiveAuthorizationStatusSource` and `SetupRunner.requestBoth`, unless the use runs inside `LiveStoreGuard.allowingLiveStore`. Release builds SHALL carry no check. Tests SHALL build the server with `TestServer.make`, which gives every source they leave out a double and an undo history of the server's own.

#### Scenario: A test builds the server with a source left at its default

- **WHEN** a test builds `CheICalMCPServer` with a source at `EventKitManager.shared`, or with the undo history at `CalendarUndoManager.shared`
- **THEN** the test process stops with the guard's message and the call stack, before any store is read

#### Scenario: A test opts in

- **WHEN** a test runs the use inside `LiveStoreGuard.allowingLiveStore`
- **THEN** the guard does not stop it; no test in the suite opts in
