<!-- SPECTRA:START v1.0.1 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra:*` skills when:

- A discussion needs structure before coding → `/spectra:discuss`
- User wants to plan, propose, or design a change → `/spectra:propose`
- Tasks are ready to implement → `/spectra:apply`
- There's an in-progress change to continue → `/spectra:ingest`
- User asks about specs or how something works → `/spectra:ask`
- Implementation is done → `/spectra:archive`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra:apply` and `/spectra:ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

## Test Naming Convention

`Tests/CheICalMCPTests/` follows three filename suffixes that signal what each test exercises. The suffix is **load-bearing** — pick the right one when adding a new file so reviewers (and Claude) can locate the right test layer fast.

| Filename pattern | Layer | What it tests |
|------------------|-------|---------------|
| `<Subject>Tests.swift` | Pure unit | Free functions / value types / pure helpers. No `FakeEventKitManager` and no `EventKitManager` *instances* (static-utility access like `EventKitManager.isNonInteractive` in `SetupCommandTests` is fine — it's a type-level probe, not handler integration). Examples: `BatchDeleteFilterTests`, `ReminderCleanupTests`, `EventKitErrorSanitizerTests`, `ParticipantFormattingTests`, `SetupCommandTests`. |
| `<Subject>HandlerTests.swift` | Handler integration | `handle*` methods from `CheICalMCPServer` driven through `FakeEventKitManager`-equivalent doubles. Tests the handler's full sanitize → dispatch → response shape, not the EventKit manager itself. **Canonical example: [`CleanupHandlerTests.swift`](Tests/CheICalMCPTests/CleanupHandlerTests.swift)** — copy its structure when adding a new handler test. |
| `<Subject>DispatchTests.swift` | Outer-catch / dispatch | `handleToolCallForTesting` outer-catch and the dispatch JSON envelope. Probes what surfaces when a handler throws an unexpected error type. Examples: `OuterCatchDispatchTests`, `DispatchRoundTripTests`. |

Helper files (e.g., `FakeEventKitManager.swift`) carry no `*Tests` suffix.

**Helpers/ subdirectory** (`Tests/CheICalMCPTests/Helpers/`, #83): shared test infrastructure that is NOT a test class is exempt from the `*Tests.swift` naming convention. Files here provide cross-test utilities (e.g. `StderrCaptureHarness.swift` centralizing the `dup2`/`Pipe` stderr-capture pattern that the sanitizer cluster's carve-out tests share). The subdirectory's existence signals "library code for tests, not tests itself" — auditors looking for tests should search the parent directory; auditors looking for shared utilities should look here.

When adding a test, ask: am I exercising a pure function (→ `*Tests`), the handler boundary (→ `*HandlerTests`), or the outer dispatch shell (→ `*DispatchTests`)? Mismatched suffix is a `idd-verify` finding worth flagging. Helpers go in `Helpers/` regardless of suffix.

## Test Seam Convention (DI for handlers)

`CheICalMCPServer` exposes EventKit primitives via two concurrent paths:

1. **Concrete singleton** — `eventKitManager: EventKitManager` (used by 30+ handlers). Production behavior. Not unit-testable in isolation.
2. **Per-feature narrow protocol** — e.g. `reminderCleanupSource: any EventKitManaging` (#31), used only by `handleCleanupCompletedReminders`. Defaults to `EventKitManager.shared` so production callers don't see the seam; tests inject a fake.

When a handler needs a test fake, **introduce a new narrow `*Source` protocol scoped to that handler's surface area** (1–3 methods is typical). Do NOT widen `EventKitManaging` to cover the new handler's needs — #31 D1 deliberately keeps that protocol tight to avoid forcing every fake to stub unrelated methods.

**Naming**: `<Domain>Source` (e.g. `EventBatchDeletionSource`, `ReminderTagSource`). The naming guidance applies to **new** protocols going forward; the existing `EventKitManaging` (#31, scoped narrow per its origin) keeps its name for compatibility — the protocol-typed parameter name (`reminderCleanupSource`) need not match the protocol's name (`EventKitManaging`). When introducing a new test seam, name the new protocol per `<Domain>Source` rather than reusing `EventKitManaging`.

**Injection point**: add a constructor parameter with `EventKitManager.shared` as the default. The concrete `eventKitManager` property stays — these coexist.

**Canonical example**: `reminderCleanupSource` in `CheICalMCPServer.init` + `Tests/CheICalMCPTests/CleanupHandlerTests.swift`. New handler tests should mirror that structure (the *injection pattern* — narrow protocol, default to shared singleton, inject in tests). The protocol *name* `EventKitManaging` is grandfathered; new protocols should use `<Domain>Source`.

This convention is **per-handler doc**, not a refactor: existing 30+ handlers continue to use `eventKitManager` directly — no migration debt. The seam appears only when a handler graduates into the test surface.
