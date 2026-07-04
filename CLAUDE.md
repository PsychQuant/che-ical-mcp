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

## Startup Banner CLI Skip List (#122 + #130)

The TCC drift detector startup banner (#122) intentionally **does NOT** run for these CLI side-channels: `--version`, `--help`, `--setup`, `--print-tcc-path`, `--self-update`, `--cli`. All of them exit before reaching the MCP server default branch where `emitStartupBanner()` lives.

**`--setup` deserves explicit justification** (#130 — surfaced as Codex M5 finding in `idd-verify #122`): the Strategy Lock comment on #122 included `--setup` running drift check at start as Acceptance Criterion #7, but the Plan tier (and shipped implementation) silently retracted it. **The retraction is intentional and stands**:

- `--setup` is the **manual remediation path**, not a diagnostic surface. Its job is to drive the macOS TCC permission dialog round-trip; the banner's drift signals are noise during that dialog flow and risk distracting users who are mid-prompt.
- Drift signals address "the running binary may not be the one TCC granted access to" — but `--setup` is specifically the binary the user just decided to authorize. Re-surfacing drift here would be cargo-culted output, not actionable.
- The diagnostic path that *does* surface drift signals is `--print-tcc-path` (which prints the banner-style binary path + bundle ID + TCC state). Users who want to see drift before running `--setup` already have a clear ordering: `--print-tcc-path` → review → `--setup`.

If a future use case argues for `--setup` triggering banner emission, **revisit by writing a follow-up issue with the user-flow rationale** — don't flip the skip list silently.

**Test coverage of the skip list is currently partial**: `testNoBannerForVersionFlag` + `testNoBannerForHelpFlag` exercise `--version` + `--help` only. The other 4 skip targets (`--setup`, `--print-tcc-path`, `--self-update`, `--cli`) are skipped structurally because they call `exit(0)` before `emitStartupBanner()` is reached (control-flow guarantee in `main.swift`), but there is no integration test asserting "binary spawned with `--setup` emits no banner". Adding 4 more `testNoBannerForXxxFlag` integration tests is tracked as a follow-up (low priority — the control-flow guarantee is straightforward to read).

**`#131` update (banner tests now run on CI)**: the `TCCDriftDetectorBannerTests` binary-spawn tests previously carried a runtime `skipIfCI()` guard while #131's GHA hang was unexplained. #131 is resolved (root cause = `AuthorizationGate` blocking on `requestFullAccess` for `.notDetermined` in a non-interactive session, now fast-failing), so the `skipIfCI()` guard is **removed** — all 5 banner tests run on CI. The earlier "skip limits GHA-hang exposure" caveat no longer applies: `spawnAndCaptureStderr` bounds every wait with a SIGTERM→SIGKILL escalation + 3s hard `waitUntilExit` cap (worst case ~6s/test, never the 20m job timeout), and the spawned binary inherits the same EventKit fast-fail under `CI=1`.

## Manifest `display_name` — no XML metacharacters (#166 CONFIRMED ROOT CAUSE)

**Invariant: `mcpb/manifest.json` `display_name` MUST NOT contain `&`, `<`, or `>`.** A literal `&` in `display_name` makes Claude Desktop 1.18286.0's tool-injection layer **silently drop the entire server from every conversation** — the transport handshake + `tools/list` complete (Desktop receives the full list) but no tool is ever injected, and nothing surfaces in any log (the drop is above the MCP-protocol layer). Claude Code has no such layer, so it worked end-to-end throughout.

This is the **confirmed** #166 root cause, proven by single-variable intervention on the exact failing Desktop install (2026-07-03): with the 29-tool binary and manifest otherwise byte-identical, changing `display_name` from `"macOS Calendar & Reminders"` → `"macOS Calendar and Reminders"` flipped the server from dropped → injecting real EventKit data. It also explains the regression timeline exactly — the `&` predated the 2026-07-02 Desktop update; the update changed how the injection layer handles it. `ManifestParityTests.testDisplayNameHasNoXMLMetacharacters` guards this at `swift test` time. Only `&` is confirmed-breaking; `<`/`>` are guarded alongside as same-class (XML/HTML metacharacter) defense-in-depth.

> **Method note (reusable)**: this was settled with a **local Developer-ID hotswap** (build + `codesign --sign "$DEVELOPER_ID" --options runtime`, then `cp` into the installed `.mcpb` `server/` dir + hand-edit the installed `manifest.json`, then user Cmd+Q → reopen). Notarization (403, expired Apple agreement) blocks *distribution* to other machines, NOT local testing — a locally-placed Developer-ID binary runs on macOS 26 and keeps its TCC grant (csreq keyed to Identifier + TeamID, not cdhash). This is how a Desktop-only injection bug was root-caused without a notarized release. **Desktop-injection causation can only be settled by direct single-variable intervention — two compelling correlations (H6 serverInfo.name n=4; tool schema-depth/desc-length outliers) both misled and were empirically refuted.**

> **Umbrella note (#166 display_name sweep — RESOLVED 2026-07-04)**: a sweep of all che-mcps `mcpb/manifest.json` files had found one other server with a `&` in `display_name` — **che-duckdb-mcp** (`"DuckDB Documentation & Database"`), which would have dropped identically under Desktop 1.18286.0. **Now fixed**: che-duckdb-mcp commit `82ab882` (`&` → `and`; `display_name` is now `"DuckDB Documentation and Database"`). A re-sweep of every che-mcps submodule manifest on 2026-07-04 came back clean — **no che-mcps `display_name` carries `&`/`<`/`>` any more.**

## MCP Server Identity Convention (#166 — hygiene, NOT the Desktop-drop cause)

**Invariant: the value passed as `Server(name:)` (i.e. the runtime `serverInfo.name`) MUST equal `mcpb/manifest.json` `name`.** Both are `che-ical-mcp` (kebab). This alignment was #166's earlier **leading hypothesis (H6)** — that Desktop 1.18286.0 reconciles `serverInfo.name` against the manifest id and drops the server on mismatch — but it was **empirically refuted**: fixing the name and swapping the corrected binary into the failing Desktop install did NOT restore injection; only removing the `&` from `display_name` did. **The invariant is retained anyway** because a server's `serverInfo.name` matching its manifest id is a baseline MCP expectation independent of the Desktop bug.

**Two distinct name constants in `Version.swift` — do not conflate them:**

| Constant | Value | Feeds | Must match |
|----------|-------|-------|-----------|
| `AppVersion.mcpServerName` | `che-ical-mcp` (kebab) | `Server(name:)` → `serverInfo.name` | `mcpb/manifest.json` `name` |
| `AppVersion.name` | `CheICalMCP` (Pascal) | `--version`, `--help` Usage lines, argv0 fallbacks | the on-disk binary filename |

`AppVersion.name` is the **binary/product name** and is correctly PascalCase (the executable is `CheICalMCP`); `mcpServerName` is the **MCP protocol identity** and must be the kebab manifest id. `ManifestParityTests.testServerInfoNameMatchesManifestName` enforces the invariant at `swift test` time (alongside the existing `tools[].name` parity guard). When cloning this repo's structure to a new MCP server, wire `Server(name:)` to a kebab constant that equals the manifest, **not** to the binary name.

> **Umbrella note (#166 sister sweep)**: the same `serverInfo.name` ≠ manifest-id mismatch exists in che-apple-notes-mcp (`CheAppleNotesMCP`) and che-xcode-mcp (`CheXcodeMCP`), and likely che-contacts-mcp (`CheContactsMCP`). **This is now moot for the Desktop-drop symptom** — the mismatch is refuted as the cause (the actual cause is the `display_name` `&`, above). These alignments remain worthwhile hygiene and ride along on each server's next release, but they are NOT a Desktop-injection fix. The one sibling that carried the actual Desktop-drop `&` was che-duckdb-mcp, **now fixed (`82ab882`, 2026-07-04)** — the umbrella `display_name` sweep is clean (see the note above).
