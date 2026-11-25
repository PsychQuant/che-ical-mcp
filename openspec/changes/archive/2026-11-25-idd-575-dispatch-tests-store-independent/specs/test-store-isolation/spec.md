## ADDED Requirements

### Requirement: The dispatch round-trip tests reach no live store

The tests that dispatch every declared tool SHALL build the server with a test double for every source and a fresh undo history, so that a full local run queries no Calendar or Reminders store whatever access the test process has. They SHALL still fail when a declared tool is not dispatched, and when `cleanup_completed_reminders` is not dispatched.

#### Scenario: A local run with Calendar access granted

- **WHEN** the suite runs on a Mac where the test process has Calendar and Reminders access
- **THEN** `DispatchRoundTripTests` dispatches every declared tool through the double, which records `listCalendarValues` and `listCompletedReminderIdentifiers`, and no call reaches `EventKitManager.shared`
