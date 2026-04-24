## Why

Three rounds of 6-AI verification on #21 and one round on #28 shipped **four P1/P2 bugs that landed on `main` and were only caught post-hoc**:

- #21 R1 F1 — destructive silent-widen (calendar_source alone → all accounts)
- #21 R2-F1 — type-coercion bypass (`{"calendar_source": 123}` slipped past the F1 guard)
- #21 R2-F2 — arithmetic inconsistency (`total` vs deduped count)
- #28 F1 — binding mode dispatched to `deleteRemindersBatch` without checking `reminder.isCompleted`, violating the schema's explicit "no longer completed → failures[]" promise

Every one of these would have been caught by a handler-level integration test that calls `handleCleanupCompletedReminders` with scripted EventKit inputs and asserts on the response. The project can't write such tests today because `EventKitManager` is a singleton that talks directly to the macOS TCC / Reminders daemon — unusable in CI and destructive on a dev machine.

The discussion that preceded this proposal (`/spectra-discuss` on 2026-04-25) converged on a **narrow-scope** approach: protocol only the 3 methods the cleanup handler uses, inject via `CheICalMCPServer.init`, fake scripted per test. Unblocks #32 sanitizer testing and future handler-integration tests without forcing a repo-wide protocol-fication.

## What Changes

- Extract `EventKitManaging` protocol with the 3 methods `handleCleanupCompletedReminders` uses: `listReminders(completed:calendarName:calendarSource:)`, `deleteRemindersBatch(identifiers:onlyCompleted:)`, `requestReminderAccess()`
- `EventKitManager` conforms to the new protocol (behavior unchanged; existing callers unaffected)
- `CheICalMCPServer.init(eventKitManager: any EventKitManaging = .shared)` — new initializer with default argument preserving production behavior
- `FakeEventKitManager` (new, in `Tests/`) — scriptable in-memory fake with canned `listReminders` results and recording of `deleteRemindersBatch` calls
- `CleanupHandlerTests` (new) — pins the cleanup handler's behavior across dry-run vs execute, filter-mode vs binding-mode, onlyCompleted enforcement, `total` arithmetic, and response shape stability

## Non-Goals

- **Do not protocol-fy other handlers.** 15+ other `eventKitManager.` call sites stay direct-singleton. They will be protocol-fied on demand when their own integration tests land (#22/#23 retrofit, future handler tests).
- **Do not introduce a DI container** (Resolver / Swinject). One injection point, one default argument — no framework needed.
- **Do not build a reusable in-memory reminder fixture.** `EKReminder` / `EKEvent` have ~50 Foundation properties; thorough faking is a rabbit hole. The fake is per-test scripted, not a shared state machine.
- **Do not retrofit #22/#23 tests in this PR.** Separate follow-up; this PR ships with a working cleanup handler test only.
- **Do not block on #32** (`failures[].error` sanitizer). #32 uses the infra this PR lands but does not depend on it structurally.

## Capabilities

### New Capabilities

- `eventkit-handler-test-harness`: Protocol-oriented test harness for handler-to-EventKitManager integration tests. Defines `EventKitManaging` protocol, `FakeEventKitManager` test helper, and establishes the pattern for all future handler integration tests.

### Modified Capabilities

(none — no existing capability's requirements change. The cleanup handler keeps its existing behavioral contract from #21/#28; this PR only adds a new way to verify that contract.)

## Impact

- **Affected specs**: new `specs/eventkit-handler-test-harness/spec.md`
- **Affected code**:
  - `Sources/CheICalMCP/EventKit/EventKitManager.swift` — declare `EventKitManaging` protocol + conformance on the existing class
  - `Sources/CheICalMCP/Server.swift` — replace `private let eventKitManager = EventKitManager.shared` with initializer-injection via new `init(eventKitManager:)`
  - `Tests/CheICalMCPTests/FakeEventKitManager.swift` — new, scriptable fake
  - `Tests/CheICalMCPTests/CleanupHandlerTests.swift` — new, pins cleanup handler contract
  - `CHANGELOG.md` — Unreleased entry under `### Added` / `### Tests`
- **No changes to**: any other Swift source file, `mcpb/manifest.json`, `README.md`, other tests
- **Production behavior**: no runtime change. `CheICalMCPServer()` keeps using `.shared`; protocol is purely additive
