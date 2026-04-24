## Context

`CheICalMCPServer` directly captures `EventKitManager.shared` at `Server.swift:34`:

```swift
private let eventKitManager = EventKitManager.shared
```

`EventKitManager` is a singleton (`EventKitManager.swift:12`: `static let shared = EventKitManager()`) that wraps `EKEventStore`, which talks to the macOS TCC / Reminders daemon. In `swift test`:

- Without granted Reminders access → every call throws permission errors
- With granted access on a dev machine → tests mutate real reminder data

17 handler call sites depend on the singleton (`Server.swift` lines 1068, 1094, 1132, 1224, 1293, 1324, 1329, 1334, 1344, 1352, 1408, 1539, 1592, 1614, 1637, 1650, 1666, 1702, plus batch handlers).

The #21 and #28 verification rounds surfaced 4 P1/P2 bugs that shipped to main because no test could exercise `handleCleanupCompletedReminders` against scripted inputs. Post-hoc catches relied on Codex reading code + schema + git history to spot inconsistency — high-effort, unreliable, and doesn't scale.

## Goals / Non-Goals

**Goals:**

- Make `handleCleanupCompletedReminders` testable without macOS Reminders access
- Pin the handler's behavioral contract: dry-run vs execute, filter vs binding, `onlyCompleted` enforcement, R2-F2 arithmetic invariant, F8 3-branch response shape stability
- Establish a pattern other handler integration tests can adopt on demand
- Land #31's infra with **zero runtime behavior change** in production

**Non-Goals:**

- Protocol-fying every `eventKitManager.` call site (15+ other callers stay direct)
- Building a reusable in-memory `EKReminder` fixture with all 50+ Foundation properties
- Retrofitting integration tests for #22 / #23 / other batch handlers in this change
- Introducing a DI framework (Resolver, Swinject, Factory)
- Writing tests for `#32`'s sanitizer (that ships in its own change, but will use this harness)

## Decisions

### D1: Protocol scope is minimal — only 3 methods

`EventKitManaging` declares only:
- `listReminders(completed:calendarName:calendarSource:)` → `[EKReminder]`
- `deleteRemindersBatch(identifiers:onlyCompleted:)` → `BatchDeleteResult`
- `requestReminderAccess()` → `Void` (throws on denial)

**Alternatives considered:**

- **Protocol the full EventKitManager surface** (~30 methods): rejected because it requires faking 30 methods before any test lands, and 29 of them are unused by `handleCleanupCompletedReminders`. Protocol grows on demand as other handlers retrofit.
- **Protocol per-handler** (`CleanupReminderProvider`): rejected as overly fine-grained. Handlers and their EventKit dependencies cluster naturally by data type (events vs reminders), not per handler.

Expansion policy: when a future handler test lands (e.g., `CreateEventsBatchHandlerTests`), that change's author adds the handful of methods they need to `EventKitManaging`. No upfront commitment.

### D2: Injection via default-argument init, not DI container

```swift
init(eventKitManager: any EventKitManaging = EventKitManager.shared) {
    self.eventKitManager = eventKitManager
}
```

Production `CheICalMCPServer()` calls resolve to `.shared`; tests pass `FakeEventKitManager()`. One-line change at the only capture site, no framework introduced.

**Alternative considered**: DI container (Swift Resolver). Rejected — the project has one consumer, one provider, and ships a CLI binary. Containers optimize for multi-module apps with runtime configurability, neither of which applies here.

### D3: `FakeEventKitManager` is per-test scripted, not a stateful fixture

Each test instantiates its own fake with canned data:

```swift
let fake = FakeEventKitManager()
fake.listRemindersResult = [MockReminder(id: "a", completed: true), ...]
fake.expectDeleteCalled = ["a"]
```

Tests script: what `listReminders` should return, what `deleteRemindersBatch` should return, which calls should throw. Fake records invocations for assertion.

**Alternatives considered:**

- **Full in-memory reminder store**: rejected as a rabbit hole. `EKReminder` has ~50 properties tied to Foundation / EventKit internals; faking them comprehensively is a bigger project than the handler itself.
- **Real `EKEventStore` with an isolated test account**: rejected for CI hostility and test flakiness.

The scripted-per-test approach keeps each test's dependencies explicit and fully visible in the test body.

### D4: `MockReminder` is a minimal stand-in, not an `EKReminder` subclass

`EKReminder`'s initializer requires a real `EKEventStore`. The fake uses a lightweight struct or a protocol extraction — `CleanupReminderDouble` — that has just `calendarItemIdentifier: String`, `isCompleted: Bool`, `title: String?`, `calendar: EKCalendar?` (stubbed). The handler is refactored to accept the minimum surface it actually reads.

**Alternatives considered:**

- **Subclass `EKReminder`**: rejected — the class's init graph is sealed to EventKit; subclassing is fragile
- **Pass real `EKReminder` instances**: rejected — requires live `EKEventStore`, which is what we're trying to avoid

Impact: `handleCleanupCompletedReminders` already only reads 2 properties (`calendarItemIdentifier`, `isCompleted`). Narrowing the type dependency is a minor refactor, not a semantic change.

### D5: One test file — `CleanupHandlerTests`

Co-located with other handler tests in `Tests/CheICalMCPTests/`. Named after the subject (the handler), matching the repo's existing convention (`DispatchRoundTripTests`, `ResponseFormattingTests`, `ParticipantFormattingTests`).

Test cases:
- `testDryRunFilterModeReturnsPreviewWithoutDeleting`
- `testDryRunBindingModeReturnsSuppliedIds`
- `testExecuteFilterModeCallsDeleteRemindersBatch`
- `testExecuteBindingModeUsesSuppliedIds`
- `testBindingModeRejectsUncompletedReminder` — pins #28 F1
- `testTotalEqualsUniqueIdentifiersCount` — pins R2-F2
- `testResponseShapeStableAcrossThreeBranches` — pins F8
- `testF1GuardFiresBeforeListReminders` — pins integration-level guard ordering
- `testEmptyReminderIdsThrows` — pins binding-mode input validation
- `testDuplicateReminderIdsAreDeduped` — pins F2

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Protocol drift — `EventKitManager`'s real method adds a feature the protocol doesn't expose, tests miss it | Protocol is minimal; adding a method is explicit. Drift is visible in diff review. |
| Fake stale behavior — real EventKit changes its quirks (e.g., iCloud shared-list aliasing pattern), fake doesn't reflect | Accept: fake tests the handler's contract with its primitive, not EventKit's full behavior. Real-EventKit regression detection belongs to manual QA on dev machines |
| `CheICalMCPServer.init` signature change breaks external consumers | No external consumers — `main.swift` is the only caller. Default argument preserves existing call sites |
| `MockReminder` / `CleanupReminderDouble` drifts from `EKReminder` properties the handler doesn't use today but uses tomorrow | When the handler reads a new property, the fake must declare it — visible in compiler error. Low risk |

## Migration Plan

No data migration. Code changes:

1. Add `EventKitManaging` protocol to `EventKitManager.swift`; retrofit `EventKitManager` conformance (no behavior change)
2. Modify `handleCleanupCompletedReminders` to iterate `CleanupReminderDouble`-compatible protocol instead of concrete `EKReminder`
3. Change `CheICalMCPServer`'s `eventKitManager` property from `let = .shared` to init-injected with default
4. Update `main.swift` call site if needed (likely `CheICalMCPServer()` continues to work unchanged — default argument kicks in)
5. Add `FakeEventKitManager.swift` + `CleanupHandlerTests.swift` under `Tests/`

Rollback: revert the commit. No runtime state, no schema changes, no API surface exposed to MCP clients changed.

## Open Questions

### Resolved during apply (2026-04-25)

**Q: `EKReminder` is hard to instantiate in tests (tied to authorized `EKEventStore`). How does the fake return "reminders" without real EventKit access?**

A: Replace `listReminders(...) -> [EKReminder]` in the protocol with `listCompletedReminderIdentifiers(calendarName:calendarSource:) -> [String]`. The cleanup handler only reads `calendarItemIdentifier` from each returned reminder — the full `EKReminder` surface is unused in this handler. The production implementation wraps the existing `listReminders(completed: true, ...)` and maps to identifiers. The fake returns `[String]` directly. No `EKReminder` fakery needed.

D4 (`MockReminder` double) is accordingly superseded: no per-reminder double is needed because the handler's data dependency on `EKReminder` collapses to just the identifier string.

All other substantive decisions (scope, injection mechanism, fake shape, test naming) resolved in the `/spectra-discuss` session.
