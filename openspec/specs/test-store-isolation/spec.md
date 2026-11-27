# test-store-isolation Specification

## Purpose

Which tests may not reach a live Calendar or Reminders store (#575).

## Requirements

### Requirement: The dispatch round-trip tests reach no live store

The tests that dispatch every declared tool SHALL build the server with a test double for every source and a fresh undo history, so that a full local run queries no Calendar or Reminders store whatever access the test process has. They SHALL still fail when a declared tool is not dispatched, and when `cleanup_completed_reminders` is not dispatched.

#### Scenario: A local run with Calendar access granted

- **WHEN** the suite runs on a Mac where the test process has Calendar and Reminders access
- **THEN** `DispatchRoundTripTests` dispatches every declared tool through the double, which records `listCalendarValues` and `listCompletedReminderIdentifiers`, and no call reaches `EventKitManager.shared`

---
### Requirement: No test reaches the live store or the shared undo history unless it opts in

Under XCTest, a DEBUG build SHALL stop the test process at each use of `EventKitManager.shared`, `CalendarUndoManager.shared`, any manager's `eventStore` (`EventKitManager.forTesting` managers included), a new write store, `NewObjectSave`'s fresh store, `LiveAuthorizationStatusSource`, `SetupRunner.requestBoth`, and each member of the test target's shared store (`SharedTestStore.store`) that reads, writes, commits or refreshes it, unless the use runs inside `LiveStoreGuard.allowingLiveStore`. Release builds SHALL carry no check. Tests SHALL build the server with `TestServer.make`, which gives every source they leave out a double and an undo history of the server's own.

#### Scenario: A test builds the server with a source left at its default

- **WHEN** a test builds `CheICalMCPServer` with a source at `EventKitManager.shared`, or with the undo history at `CalendarUndoManager.shared`
- **THEN** the test process stops with the guard's message and the call stack, before any store is read

#### Scenario: A test opts in

- **WHEN** a test runs the use inside `LiveStoreGuard.allowingLiveStore`
- **THEN** the guard does not stop it; no test in the suite opts in

<!-- @trace
source: idd-600-tests-never-reach-live-store
updated: 2026-11-27
code:
  - CLAUDE.md
  - Tests/CheICalMCPTests/DispatchRoundTripTests.swift
  - CHANGELOG.md
  - Tests/CheICalMCPTests/Helpers/DispatchProbe.swift
-->