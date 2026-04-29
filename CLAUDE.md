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

When adding a test, ask: am I exercising a pure function (→ `*Tests`), the handler boundary (→ `*HandlerTests`), or the outer dispatch shell (→ `*DispatchTests`)? Mismatched suffix is a `idd-verify` finding worth flagging.
