# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.13.0] - 2026-06-23

**#164 — SwiftUI SetupWindow for interactive `--setup` (follow-up to #163).**

- **Added (#164)**: interactive `--setup` now presents a SwiftUI **SetupWindow** inside the foreground `NSApplication` (from #163) instead of firing the requests window-less. The window shows live Calendar / Reminders status, per-entity **Grant** buttons that call `requestFullAccess*` directly (the system dialog), the resolved absolute path of the binary being authorized (the buried `.mcpb` binary — with Copy / Open System Settings actions), and flips to "✅ Ready" the instant access is granted (1.5s live re-check). Mirrors che-apple-mail-mcp's `SetupWindow` (che-apple-mail-mcp#213), but richer because EventKit has a request API (FDA does not). Non-interactive / non-AppKit paths stay headless; the stdio MCP path never enters the window runloop.
- **Refactored (#164)**: extracted `SetupEntityState` + `SetupModel` (injectable `AuthorizationStatusSource` probe) so the window's status mapping, grant handling (incl. sanitized error), live refresh, and timer idempotency are unit-tested without an `EKEventStore` or SwiftUI render. `SetupRunner.runInteractive()` now delegates to `SetupWindow.run()`.
- 428 tests, 0 failures.

## [1.12.0] - 2026-06-23

**#163 — foreground `--setup` so the Calendar TCC dialog actually presents, + binary-specific `--setup` remediation in denial messages and the startup banner.**

- **Fixed (#163)**: interactive `--setup` ran its `requestFullAccess` calls from a bare CLI async context, which on macOS 14+/26 has no foreground-app context or running run loop to pump EventKit's system modal — so the **first** request (Calendar) silently returned denied with no dialog while a later one (Reminders) sometimes slipped through (the Calendar-denied / Reminders-granted asymmetry users hit). Interactive `--setup` now runs inside a foreground `NSApplication` (`setActivationPolicy(.regular)` + delegate + `app.run()`) via `SetupRunner`, mirroring che-apple-mail-mcp's `SetupWindow.run()` (che-apple-mail-mcp#213) — no SwiftUI window, EventKit presents its own modal; we only need the foreground context. The non-interactive path stays headless (status-only, never enters the run loop).
- **Added (#163)**: permission-denied tool responses and the startup banner now surface the **resolved absolute path of the running binary** plus a copy-pasteable `"<path>" --setup` command (via `EventKitManager.setupCommandHint` / `resolvedSetupCommandHint`, control-char sanitized). For the buried Claude Desktop `.mcpb` binary this is the actionable way to grant THIS binary's TCC permission; the `.mcpb` denial message now leads with `--setup` (foreground dialog) and keeps the plugin-install path as the fallback.
- **Refactored (#163)**: extracted `SetupEntityOutcome` + `SetupRunner.evaluateEntity(status:nonInteractive:request:)` — a pure, injectable seam so every setup branch (already-granted / granted / denied / skip-would-block / write-only / sanitized-error) is unit-testable without an `EKEventStore` or stdout capture.

## [1.11.1] - 2026-06-18

**#160 — `create_event` start < end validation (symmetric with `update_event`).**

- **Fixed (#160)**: `createEvent` had no time-range guard while `updateEvent` rejected `end <= start` for timed events. The asymmetry let `create_event` persist inverted / zero-duration timed events that `update_event` rejects. Extracted a shared static `EventKitManager.validateTimeRange(start:end:isAllDay:)` — throws `invalidTimeRange` when `start >= end && !isAllDay`, all-day events exempt — called from both `createEvent` (before save) and `updateEvent` (replacing the inline guard; original error message preserved via a `hint` parameter). New `TimeValidationTests` cases exercise the shared guard directly. 405 tests, 0 failures. 6-AI / multi-reviewer verified.

## [1.11.0] - 2026-06-10

**#154 — TCC healing re-prompt unblocked (personal-information entitlements).**

- **Fixed (#154)**: long-lived installs upgraded from the pre-v1.7.1 ad-hoc era could hit silent, permanent Calendar (or Reminders) denial on macOS 26.5: the TCC row stays pinned to the old build's cdhashes (csreq match fails at access time) while the healing re-prompt is policy-blocked because the hardened-runtime binary shipped **no** entitlements — and every status-API-based diagnostic (`authorizationStatus(for:)` per-call gate, `--print-tcc-path`, the v1.10.0 startup banner, System Settings) reports green. `Entitlements.plist` now ships `com.apple.security.personal-information.calendars` + `.reminders` (both unrestricted; reverses the #58 item 5 decision, which held on 26.4.1 but Apple has since tightened). First launch of the fixed build is finally allowed to re-prompt; approving rewrites the row keyed to the Developer ID requirement, healing it for all future upgrades. New `EntitlementsPlistTests` pins both keys in CI.
- **Added (#154)**: `scripts/sign-and-notarize.sh` step 2.5 release gate — verifies both personal-information entitlements on the **signed binary** (fail-fast before the 1-15 min notarization wait), catching a wrong/stale `ENTITLEMENTS` path that source-level tests cannot see.

**Cluster #131 + #143 + #144 — non-interactive EventKit access hardening.** PR [#142](https://github.com/PsychQuant/che-ical-mcp/pull/142) (#131), PR [#145](https://github.com/PsychQuant/che-ical-mcp/pull/145) (#143 #144). 6-AI verified.

- **Fixed (#131)**: GHA CI test hang root-caused — `AuthorizationGate.ensureAccess` now fast-fails `.notDetermined` in non-interactive sessions (SSH / launchd / CI) instead of blocking forever on a TCC dialog that can never appear. Removed the `-DCI_BUILD` compile-exclusion + the `skipIfCI()` guards so `DispatchRoundTripTests` and the binary-spawn `TCCDriftDetectorBannerTests` now run on CI (GHA green, all banner tests execute).
- **Fixed (#143)**: `--setup` no longer hangs in non-interactive sessions — it now checks `EKEventStore.authorizationStatus` before calling the blocking `requestFullAccess`. On `.notDetermined` in a non-interactive session it prints remediation and skips (exits non-zero) rather than blocking; an already-granted binary still reports success. New pure `setupAccessDecision(status:isNonInteractive:)` helper + decision-table tests. `--setup` uses a narrower non-interactive check (`TERM`/`ppid`) that deliberately excludes the `CI` env var, so a human in Terminal with `CI=1` still gets the dialog.
- **Changed (#144)**: renamed `isLaunchd` → `isNonInteractive` (the `AuthorizationGate` param + `EventKitError.accessDenied` case label were named `isLaunchd` but fed `isNonInteractiveSession` = launchd ∪ no-TTY ∪ CI) across `AuthorizationStatusSource` + `EventKitManager` + tests, and generalized the launchd-specific remediation wording ("restart the launchd job" → "restart the non-interactive job (launchd service, CI runner, etc.)") in both the launchd-only and SSH+non-interactive branches.

**Verify follow-ups (#146 / #147 / #149 / #150) — test + escape hardening.** PR [#148](https://github.com/PsychQuant/che-ical-mcp/pull/148) (#146 #147), PR [#151](https://github.com/PsychQuant/che-ical-mcp/pull/151) (#149 #150). 6-AI verified.

- **Fixed (#146 / #147)**: `--setup` error output now routes through `EventKitErrorSanitizer.escapeForStderr` (consistency with other stderr-boundary callers); `testIsNonInteractiveDetection` made robust to the `CI` env var (was env-fragile under `CI=1`).
- **Changed (#149)**: extracted a pure injectable `NonInteractiveDetection.isNonInteractive(env:ppid:includeCI:)` helper. Both the MCP server gate (`includeCI: true`) and `--setup` (`includeCI: false`, preserving the #143 CI carve-out) delegate to it, so the predicate is matrix-testable `(TERM, CI, ppid) × includeCI` via an independent oracle instead of inline process-global reads.
- **Changed (#150)**: `EventKitErrorSanitizer.escapeForStderr` now also escapes the C1 control band (`\x80..\x9F`), closing the 8-bit CSI (`\xC2\x9B`) terminal-hijack form; printable scalars start at `\xA0`, so the C1 range is control-only.

Cluster: 16 verify follow-ups from #108 (TCC has\*Access refactor) and #122 (TCC drift detector banner) — one PR ([#135](https://github.com/PsychQuant/che-ical-mcp/pull/135)), 4 commits, 367 tests pass (was 348).

### Breaking

- **Deploy floor raised to macOS 14.0 (Sonoma)** (#119): `Package.swift` `.macOS(.v13)` → `.macOS(.v14)`. Removes 5 `#available(macOS 14.0, *)` branches across `main.swift` + `AuthorizationStatusSource.swift` plus the `@available` class-level annotation on `AuthorizationGateTests`. macOS 13 (Ventura) users will hit a hard SDK-version mismatch rather than a silent dyld failure — `mcpb/manifest.json` now declares `compatibility.runtimes.macos = "14.0"` to surface this at install time. Rationale: macOS 14 (Sonoma) is ~2.5 years old as of this release, EventKit's per-call gate work (#108 Phase 2) is built on macOS 14 APIs, and maintaining dead pre-14 branches outweighed any negligible Calendar/Reminders MCP user share on macOS 13.

### Added

- **`TCCStatusFormatter` enum + 6 unit tests** (#117): extracts the inline `--print-tcc-path` status formatter into a unit-testable `TCCStatusFormatter.describe` covering all 5 `EKAuthorizationStatus` cases + `@unknown default` raw-value escape hatch. Closes the formatting-regression-only-caught-by-manual-smoke-test gap.
- **`BinaryPathResolver` enum + 7 unit tests** (#121, #128, #129): unifies argv[0] resolution across `--print-tcc-path`, the startup banner, and `--self-update`. Uses `realpath(3)` to walk multi-level symlink chains (closes #121 — single-hop `destinationOfSymbolicLink` left intermediate paths visible) and exposes `resolveWithPATHFallback` for bare-argv[0] `$PATH` walk used by `--self-update`.
- **`SubprocessRunner` helper** (#126): consolidates `sqlite3` + `ps` subprocess execution from `LiveTCCDatabaseSource` and `LiveProcessInventorySource` with hard-cap `DispatchSourceTimer` timeout (500ms default). Hung child processes (TCC.db locked / sandbox edge case) surface as explicit `failureReason: "sqlite3 timed out after 500ms"` instead of blocking MCP server startup.
- **`EventKitError.unsupportedEntityType(rawValue: UInt)` case** (#118): `LiveAuthorizationStatusSource.requestFullAccess` `@unknown default` now throws this typed error instead of returning `false` (which got misattributed downstream as user-denied). Future Apple-added `EKEntityType` cases surface as a build-version mismatch rather than a phantom denial.
- **`EventKitManager.forTesting(probe:)` DEBUG factory** (#115): test-only construction path with explicit AuthorizationStatusSource injection. New `EventKitManagerForTestingTests` exercises it so the seam is provably wired, not dead code.
- **Direct unit tests for `LiveTCCDatabaseSource` + `LiveProcessInventorySource`** (#124): 13 tests covering missing binaries, missing TCC.db, corrupt-db exit-status surfacing, synthetic-db happy path with real `sqlite3` seed, tiny-timeout race tolerance, exact-basename match positive + negative cases, deep-path basename extraction. Closes the CI coverage gap where Live impls were only exercised through the GHA-flaky binary-spawn integration tests.

### Changed

- **`AuthorizationGate.ensureAccess` now accepts `isSSH` / `isLaunchd` defaulted params** (#113): `EventKitManager.ensureCalendarAccess` / `ensureReminderAccess` pass `Self.isSSHSession` + `Self.isNonInteractiveSession` through to the gate. Restores the SSH-context and launchd-context-specific workaround text in `EventKitError.accessDenied` that the #108 Phase 2 refactor had hardcoded to `false`.
- **`EventKitManager.init` now `fileprivate`** (#115): singleton invariant (`EventKitManager.shared`) no longer relies on convention. Production code must use `.shared`; tests use the new `forTesting(probe:)` factory.
- **`AuthorizationStatusSource` protocol drops `Sendable` constraint** (#116, Option A from issue): `EKEventStore` is non-`Sendable`; the protocol constraint forced `@unchecked Sendable` workarounds on `LiveAuthorizationStatusSource` and `MockAuthorizationStatusSource`. Actor isolation in `EventKitManager` (the sole owner) provides the safety guarantee instead. `@preconcurrency import EventKit` suppresses the framework-side warning. Mock loses `@unchecked Sendable` cleanly.
- **`ProcessInventoryParser.parseRow` exact-basename match** (#125): comparison switched from `commPath.contains(processNameSubstring)` to `URL(commPath).lastPathComponent == processName`. Eliminates false positives like `/path/CheICalMCP-helper` and `/tmp/CheICalMCPLegacy.bak` from the banner's stale-process count. Known limitation: versioned binaries (e.g. `CheICalMCP-1.10.0`) are not matched — recommend opening a follow-up if package-manager distribution adopts that naming.
- **`MockAuthorizationStatusSource` gains explicit fresh-instance pattern comment** (#120): documents why the unsynchronized `requestCallCount` is safe (single-test ownership, never shared) so future copy-paste of the mock pattern doesn't propagate a hidden race.
- **`testBannerAppearsInDefaultMCPServerMode` adds `XCTAssertLessThan(elapsed, 1.5)` latency budget** (#127): encodes the Plan tier #122 target (200ms target, 1.5s assertion bound for local-host noise tolerance) so banner-emission regressions are caught in CI rather than discovered through user reports.

### Docs

- **`mcpb/README.md` post-install / upgrade narrative rewritten** (#114): drops the disproved "cdhash invalidation breaks TCC grants on each release" hypothesis; reframes the silent-failure mode as the in-process `has*Access` cache anti-pattern (fixed structurally in v1.9.0 via #108 Phase 2). Errata header in `CHANGELOG [1.8.1]` entry preserves the original wrong narrative for audit. Inline troubleshooting paragraph at line 115 also corrected — previously contradicted the lead paragraph.
- **`CLAUDE.md` gains 'Startup Banner CLI Skip List' section** (#130): documents the `--setup` skip decision (Option B from issue). Strategy Lock Acceptance Criterion #7 (`--setup runs drift check at start`) was silently retracted by the Plan tier; this commit makes the retraction explicit with the user-flow rationale (`--setup` is the remediation path, not a diagnostic surface). Future revisits must write a follow-up issue rather than flip the skip list silently.
- **`README.md` updated** to reflect macOS 14.0 floor + current v1.10.0 version (lines 237, 540, 544).

## [1.10.0] - 2026-05-12

### Added

- **TCC drift detector + startup banner** (#122, `Sources/CheICalMCP/EventKit/TCCDriftDetector.swift` + `TCCDatabaseSource.swift` + `ProcessInventorySource.swift`): emits a single-shot stderr banner at MCP-server-mode startup with version, binary path, PID, and any drift signals detected. Two signals: (1) **TCC.db path mismatch** — TCC has a grant for CheICalMCP but recorded against a different binary path than the running one (typical when `~/bin/CheICalMCP` and the `.mcpb` install path co-exist); the running binary will get `.notDetermined` even though "CheICalMCP" appears in System Settings. (2) **Stale running processes** — long-lived CheICalMCP processes started before the on-disk binary mtime hold cached auth state from older code (root cause confirmed during #122 reproduction: 37 stale processes from pre-v1.8.0 on the issuer's host). Banner is advisory and non-blocking; failed reads (sqlite3 unavailable, ps blocked, TCC.db locked) surface as skip reasons rather than aborting startup. Opt-out via `CHE_ICAL_MCP_NO_BANNER=<any non-empty>` for CI / automation. Skip applies to `--version` / `--help` / `--setup` / `--print-tcc-path` / `--self-update` / `--cli` paths.
- **Drift detection test seams** (#122): two narrow `<Domain>Source` protocols (`TCCDatabaseSource`, `ProcessInventorySource`) following the CLAUDE.md Test Seam Convention. Live implementations shell out to `/usr/bin/sqlite3 -readonly` and `/bin/ps -A` respectively, both returning skip reasons on failure rather than throwing. Pure `detect()` + `formatBanner()` make the drift logic unit-testable without subprocess spawn or TCC.db access. **18 new tests** (`TCCDriftDetectorTests.swift` 13 unit cases + `TCCDriftDetectorBannerTests.swift` 5 subprocess-integration cases) cover happy / skip / mismatch / stale / banner-format invariants. Integration tests use a copy-binary-to-temp-path pattern to verify alternate-path scenarios (proxy for `.mcpb` install path) without machine-specific TCC fixtures.

### Fixed

- **Pipe-deadlock bug in subprocess helpers** (#122): `Process.waitUntilExit()` was called before draining stdout/stderr pipes; `ps -A` output regularly exceeds the 64KB OS pipe buffer, blocking the child on write and deadlocking the parent's wait. Both `LiveTCCDatabaseSource` and `LiveProcessInventorySource` now read pipes via `readDataToEndOfFile()` first, then wait — child can drain naturally on stdout close. Surfaced during banner smoke-testing of #122; the unit-test suite never exercised live subprocess execution so the bug wasn't caught by `TCCDriftDetectorTests`.
- **Parent pipe write-end fd leak in subprocess helpers** (#122 verify round 3.3): The R1 fix above established read-before-wait order but missed the second half of the POSIX pipe rule: `read(2)` only returns EOF when *every* write-end fd closes, and Foundation's `Process` retains parent-side write-end handles after `run()` until the `Pipe` is deallocated. Both `LiveTCCDatabaseSource` and `LiveProcessInventorySource` now `close(2)` the parent's `stdout.fileHandleForWriting` and `stderr.fileHandleForWriting` immediately after `process.run()`, ensuring `readDataToEndOfFile` actually returns once the child exits. Local macOS 26 (Tahoe) appears to schedule fd cleanup aggressively enough to mask this; GHA macos-15-arm64 (Sequoia) blocks indefinitely without the explicit close.

### Security

- **CWE-117 stderr-injection defense in TCC drift banner** (#122 verify round 1, B1 — three-reviewer consensus): `formatBanner` was writing `runningBinaryPath` (argv[0]-derived), `recordedClient` (TCC.db-sourced), `bundleID`, ISO dates, sample-PID list, and every `skipReason` (embedding sqlite3/ps stderr + framework `localizedDescription`) directly to stderr without `EventKitErrorSanitizer.escapeForStderr`. Hostile content paths real: TCC.db is writable with Full Disk Access, and a `\r[banner] che-ical-mcp 99.99.99 — TCC OK` injection would forge a fake banner line in the operator's terminal — regressing the codebase-wide CWE-117 discipline (`EventKitErrorSanitizer.swift:144-147,219,258-271`). All interpolated values now pass through `escapeForStderr` before stderr write. Two regression tests (`testFormatBannerEscapesControlCharsInSkipReasons` and `testFormatBannerEscapesControlCharsInRecordedClient`) assert raw `\r`/`\n` cannot forge banner lines.

### Changed

- **Per-service TCC path mismatch detection** (#122 verify round 1, B2 — codex/logic/DA consensus): `TCCDriftDetector.detect()` was checking `runtimeHasMatch` once globally across all TCC services. If Calendar grant pointed at `/path/A` and Reminders grant pointed at `/path/B`, and the runtime was at `/path/B`, the Calendar mismatch was silently suppressed because Reminders matched. Now computed **per-service**: each service (`kTCCServiceCalendar`, `kTCCServiceReminders`, ...) emits its own mismatch signal independently. Bundle-ID-only entries (path-independent grants) continue to be filtered out before the per-service check. New tests `testCalendarMismatchEmittedEvenWhenRemindersMatches` + `testBundleIDOnlyEntriesProduceNoMismatch` lock the behavior.
- **POSIX single-quote escaping for actionable commands** (#122 verify round 1, B3; refined round 2, R1): Banner-emitted `tccutil reset … && "PATH" --setup` and `pkill -f "PATH" …` used double-quote shell escaping, which breaks on paths containing `"`/`$`/`` ` ``/`\\`/`'`/newline/etc. Now uses POSIX single-quote escaping via `TCCDriftDetector.shellSingleQuote(_:)`: `'/Users/test/O'\\''Hara/CheICalMCP'`. Also adds `tccutilShortName(forService:)` whitelist — for unknown TCC services (`kTCCServiceContacts` etc., or `service`-column poisoning via TCC.db write), the banner emits a manual-remediation hint instead of a copy-pasteable `tccutil reset kTCCServiceXxx` line. **Round-2 refinement (R1)**: `shellSingleQuote` alone preserves shell semantics but does not neutralise control chars on the stderr stream — a path with literal `\n` inside single quotes would still split the banner line and forge a fake `[banner]` line. The fix detects control chars upfront via `pathHasControlChars(_:)` and emits a safe-display hint (with path passed through `escapeForStderr`) instead of a copy-paste command when control chars are present. Avoids the double-escape regression Codex flagged where wrapping `shellSingleQuote(...)` in `escapeForStderr` would convert `\` in the `'\''` splice to `\\` and break POSIX shell parsing for paths with apostrophes. Six tests cover the helper, whitelist suppression, integration assertion, control-char detection, and the safe-display hint emission.
- **Removed dead `do/catch` wrapper in `emitStartupBanner`** (#122 verify round 1, F1): The catch block was unreachable — all internal calls use `try?` (non-throwing) or are non-throwing by design. Comment claimed "future maintenance could add a throwing path" but currently misleads reviewers into thinking there's a defense in place. Restructured without the wrapper.
- **Deleted misleading "PID 0 sentinel" comment** (#122 verify round 1, F2): Comment in `TCCDriftDetector.swift` claimed PID 0 sentinel handling that the code never implemented (no `if ownPID == 0` branch).
- **Defensive guard against empty `commPath` in `ps` parser** (#122 verify round 1, F6): Pathological `ps` rows (zombie / kernel-thread with stripped `comm`) could yield 6 valid `lstart` tokens followed by an empty 7th. Added `commPath.trimmingCharacters(in: .whitespaces).isEmpty` guard before the substring filter.
- **Explicit `TimeZone.current` pin on `LiveProcessInventorySource.lstartFormatter`** (#122 verify round 1, F8): Without explicit pin, formatter falls back to system default which is normally `TimeZone.current` but can drift on DST transitions. Pinning prevents mismatches against `attrs[.modificationDate]` Date comparison.
- **Static cached `TCCDriftDetector.iso8601Formatter`** (#122 verify round 1, F9): Banner emits once per startup so perf impact zero, but pattern is now consistent with `LiveProcessInventorySource.lstartFormatter` static caching.
- **CI: 8 tests compile-time excluded on GitHub Actions** (#122 verify round 3, tracked in #131): `TCCDriftDetectorBannerTests` (5 binary-spawn integration tests) and `DispatchRoundTripTests` (3 real-server dispatch tests) hang the GHA `macos-15-arm64` runner for 20m with zero test output until the job timeout cancels. R6 verbose+PTY diagnostic (`script -q /dev/null swift test --verbose`) finally surfaced the actual hang point: `DispatchRoundTripTests.testCleanupCompletedRemindersIsDispatched` invokes `executeToolCall` on a real `CheICalMCPServer`, which routes to a handler that calls `EventKitManager.shared` — and on macOS 15 in a headless sandbox with no TCC grants, EventKit framework **blocks indefinitely waiting for a TCC prompt** rather than returning `.denied` synchronously like macOS 26 (Tahoe). Both test files now use `#if !CI_BUILD` ... `#endif` guards activated by the workflow's `-Xswiftc -DCI_BUILD` flag. CI runs **330/330 tests**; local dev runs **338/338 tests**. Banner format invariants remain covered by the 13 mocked-source unit tests in `TCCDriftDetectorTests.swift`; the R3.3 production pipe-write-fd fix (above) stays as legitimate POSIX hygiene independent of which test happened to be the CI-hang trigger. Workflow also retains `--verbose` + PTY instrumentation as a diagnostic safety net for future test additions. **Removal criteria**: when #131 is properly resolved (likely via `FakeEventKitManager` injection on the dispatch tests + investigation of the banner test hang, which is a separate sub-cluster), drop both `#if !CI_BUILD` guards and the `-DCI_BUILD` workflow flag together.

## [1.9.0] - 2026-05-11

EventKit TCC access gate refactor (#108 Phase 2) — eliminates the `hasCalendarAccess` / `hasReminderAccess` actor-private cache anti-pattern in `EventKitManager`. Per-call `EKEventStore.authorizationStatus(for:)` cheap check now drives every tool call's access gate, aligning with Apple's documented pattern (TN3153 + `authorizationStatus(for:)` API guidance) and surfacing TCC state changes immediately as actionable `accessDenied` / `insufficientAccess` / `unknownAuthState` errors instead of being masked by stale cache. Bundles #109 `--print-tcc-path` diagnostic flag — prints binary path, bundle ID, current authorization status, and ready-to-paste `tccutil reset` / `sqlite3` commands for users troubleshooting TCC issues post-install.

### Changed

- **`EventKitManager` TCC access gate refactored to per-call status check** (#108 Phase 2, breaking internal API): replaced `requestCalendarAccess()` / `requestReminderAccess()` (cached granted state in `hasCalendarAccess` / `hasReminderAccess` flags) with `ensureCalendarAccess()` / `ensureReminderAccess()` (each tool call cheap-reads `EKEventStore.authorizationStatus(for:)` and dispatches via `AuthorizationGate.ensureAccess`). Cache removed entirely — every tool call sees fresh TCC state. Apple-recommended pattern per [TN3153](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos) — by calling `authorizationStatus(for:)` each time rather than caching, the app reflects user changes (System Settings toggle / TCC db reset / future macOS policy shifts) immediately. New constructor parameter `init(authorizationSource: AuthorizationStatusSource? = nil)` defaults to `LiveAuthorizationStatusSource` so production callers via `EventKitManager.shared` are unchanged; tests inject `MockAuthorizationStatusSource` to exercise the `AuthorizationGate` switch without real EventKit. **No MCP tool surface impact** — internal API only.

### Added

- **`AuthorizationStatusSource` protocol + `LiveAuthorizationStatusSource`** (#108 Phase 2, NEW `Sources/CheICalMCP/EventKit/AuthorizationStatusSource.swift`): narrow `<Domain>Source` test seam protocol per `CLAUDE.md` Test Seam Convention with two methods (`authorizationStatus(for:)`, `requestFullAccess(for:)`). Production wires `LiveAuthorizationStatusSource` sharing the `EventKitManager`'s `EKEventStore` instance. The `AuthorizationGate.ensureAccess` static helper implements the switch logic against `EKAuthorizationStatus` — `.fullAccess` short-circuits; `.writeOnly` throws new `insufficientAccess`; `.denied` / `.restricted` throws existing `accessDenied`; `.notDetermined` triggers expensive `requestFullAccess` and throws if denied after prompt; `@unknown default` throws new `unknownAuthState`. Both macOS 14+ and pre-14 (legacy `.authorized`) branches handled explicitly.
- **`EventKitError.insufficientAccess(type:)`** (#108 Phase 2): new error case for macOS 14+ `.writeOnly` partial-access state. Read operations cannot silently fall back — user must manually upgrade to full access in System Settings. Error message includes step-by-step upgrade instructions.
- **`EventKitError.unknownAuthState(type:statusValue:)`** (#108 Phase 2): defensive new error case for `@unknown default` in the authorization-status switch, guarding against future EKAuthorizationStatus enum cases this build doesn't recognize. Error message instructs user to run `--setup` from Terminal, `tccutil reset`, or upgrade CheICalMCP.
- **`Tests/CheICalMCPTests/AuthorizationGateTests.swift` (NEW)** (#108 Phase 2): 7 pure unit tests covering each `EKAuthorizationStatus` switch branch — `fullAccess` (short-circuits without calling request), `denied` (throws `accessDenied`), `restricted` (throws `accessDenied`), `writeOnly` (throws `insufficientAccess`), `notDetermined` with granted result (calls request once and returns), `notDetermined` with denied result (calls request once then throws), plus a separate test asserting `typeName` propagation into the `accessDenied` error. Uses `MockAuthorizationStatusSource` that records request-call count so silent-fail paths are explicitly asserted-against (assert `requestCallCount == 0` for `.denied` / `.restricted` / `.writeOnly`).
- **`--print-tcc-path` diagnostic flag** (#109): bundled into v1.9.0 per Phase 2 sister-bundle decision. Prints binary path, bundle identifier, current EventKit authorization status (Calendar + Reminders, with macOS-14-aware status string formatting), `tccutil reset` snippet (with bundle ID interpolated), `sqlite3` TCC.db query snippet, and System Settings paths. Designed for `.mcpb` installed users who need to locate the extracted binary path before running `--setup` from Terminal. Output exits before MCP server mode — purely diagnostic.

## [1.8.1] - 2026-05-11

> **Errata (2026-05-25, #114)**: the original narrative for this release framed the silent-failure as "cdhash changes on each release invalidate TCC grants". The cdhash hypothesis was **disproved** during #108 Phase 1 smoke testing — TCC grants for a notarized Developer-ID-signed binary survived 5 consecutive binary swaps because TCC keys entries by designated requirement (csreq) which is stable across cdhash changes for the same signing identity. The actual root cause is the in-process `has*Access` cache anti-pattern fixed structurally in v1.9.0 (#108 Phase 2). The `.mcpb` README + `--setup` workflow that shipped in 1.8.1 still helps for the **first-install** case (TCC entry truly absent), and the diagnostic instructions remain accurate; only the "Why this is needed" framing was wrong. See `mcpb/README.md` for the corrected narrative.

Documentation-only release. Adds the post-install / upgrade TCC permission setup guide for `.mcpb` installation path (#108 Phase 1). _Original (incorrect) framing kept here for audit; see errata above._ Diagnoses the silent-failure mode where reinstalling `.mcpb` invalidates the existing TCC grant (~~cdhash changed~~ — see errata) and the MCP subprocess context cannot surface a re-authorization dialog. Provides verified workaround (run `--setup` from Terminal once after install / upgrade) until the v1.9.0 structural fix (per-call `authorizationStatus` gate, Phase 2) ships.

### Fixed

- **`.mcpb` post-install / upgrade TCC permission workflow documented** (#108 Phase 1): new `mcpb/README.md` covers verify-current-state (TCC db SQL query), locate-extracted-binary (`find` snippet), run-`--setup`-from-Terminal, and troubleshooting (`tccutil reset` + manual System Settings toggle). Closes the documentation gap that left `.mcpb` upgrade-path users facing silent calendar tool failures without an obvious remediation path. Phase 2 (v1.9.0) landed the structural fix that removes the actor-private `hasCalendarAccess` / `hasReminderAccess` caches so subsequent TCC state changes surface as immediate `accessDenied` errors instead of silent failures. _(Per #114 errata: the actor-private cache was the actual root cause; the original "cdhash invalidation" framing here was a wrong hypothesis disproved by Phase 1 smoke.)_

## [1.8.0] - 2026-05-11

Wire-format consistency wave + response-shape parameters. Completes the #101 cluster (5 closed issues across 3 days) — event listing tools gain `detail_level` / `fields` / `display_timezone` / `limit` for LLM-friendly verbosity tuning, and all 5 list/search envelopes converge on top-level `<entity>_count` with pre-limit semantics. Two breaking wire-format changes (#102, #107) — MCP clients reading `metadata.returned` or `result_count` must update. Validator hardening (#101 F1-F3) closes a `Int.max` DoS trap and the type-coerce-bypass class on 2 more helpers. Runtime-anchored drift detection (#103) prevents `formatEventDict` ↔ `validEventFields` divergence.

### Added

- **Event listing response-shape parameters** (#101, originally PR #47 by @fabiocarvalho777, taken over with `Co-authored-by` after 6-AI verify FAIL): four optional parameters on `list_events`, `search_events`, and `list_events_quick`:
  - `detail_level` (string, `"summary"` | `"standard"`, default `"standard"`): preset response-verbosity tiers. `summary` returns 10 core fields (id/title/dates/timezone/is_all_day/calendar/location); `standard` returns all fields. Cuts token usage substantially when LLM consumers don't need notes/url/recurrence/attendees.
  - `fields` (string array): fine-grained field selection — overrides `detail_level` when both supplied. Unknown field names rejected with `invalidParameter` listing all available options. Non-array input or non-string elements throw with the offending index, not silently dropped (#28 R2-F1 type-coerce-bypass class).
  - `display_timezone` (string, IANA Region/City or `UTC`): converts `*_local` timestamp fields to specified zone. Strict membership check via `TimeZone.knownTimeZoneIdentifiers` rejects abbreviations (`PST`/`EST`) and POSIX-style offsets (`GMT+08:00`) that have ambiguous DST semantics. Per-event `timezone` field continues to report event's own zone. `list_events_quick` envelope `timezone` echoes the requested zone instead of system tz so renders are internally consistent (M4).
  - `limit` (integer): added to `search_events` and `list_events_quick` (was already on `list_events`). Loud-failure on type mismatch (per #25) — string `"5"`, fractional `5.5`, etc. throw rather than silent-coerce. Bounds: must be `> 0` and `≤ 10000` (defense-in-depth against accidentally-massive responses).

### Changed

- **envelope count fields unified to top-level `<entity>_count`, `search_reminders` gains `limit` parameter** (#107, breaking wire-format change): `list_events.metadata.returned` + `list_reminders.metadata.returned` removed; replaced with top-level `event_count` / `reminder_count` semantically aligned to pre-limit total (taken from `totalAfterFilter` before any prefix truncation). `search_reminders` adds optional `limit` parameter (max=10000 via `requireOptionalLimit`, defense-in-depth) so `reminder_count` semantic now exactly matches `event_count` across all 5 list/search envelopes. `metadata` wrapper retained for query state info (`total_in_range` / `total_after_filter` / `filter` / `sort` / `limit`). Callers compute truncation via `<entity>_count - len(events)` per existing `search_events` pattern. MCP clients reading `metadata.returned` need to update.
- **`search_reminders.result_count` → `reminder_count`** (#102, breaking wire-format change): renames the response envelope field on the reminder side, mirroring #101 M1 on the event side. The reminder tool family now matches the event family's `<entity>_count` convention. MCP clients hardcoding `result_count` need to update. _(Note: post-#107, this entry's "metadata.returned keeps post-limit semantics" caveat no longer applies — all 5 envelopes now use top-level `<entity>_count` with pre-limit semantic.)_
- **`search_events.result_count` → `event_count`** (#101 M1, breaking wire-format change): renames the response envelope field across event-listing tools (`list_events_quick.event_count` was already canonical). MCP clients hardcoding `result_count` need to update. _(Note: post-#107, `list_events.metadata.returned` is also removed in favor of top-level `event_count`.)_
- **`InputValidation.parseDisplayTimezone` strictness** (#101 B3): rejects Foundation-accepted abbreviations and POSIX offsets that varied semantics across hosts. Region/City IANA identifiers + `UTC` alias accepted; everything else rejected with `invalidParameter` listing examples. Adds determinism to `*_local` rendering at the cost of accepting a narrower input set.
- **`summary` detail_level description** (#101 LO1): tool schema now lists all 10 emitted fields (was misleadingly described as "title, times, calendar, location only").
- **`InputValidation.validEventFields` runtime-anchored drift detection** (#101 M3, strengthened by #103): bidirectional drift test catches forgotten updates when `formatEventDict`'s emission set changes. Initially landed (#101 M3) as a `validEventFields` ↔ `formatEventDictKeys` mirror-pair check (documentation-only contract, drift detection only when maintainer remembered to touch `Validation.swift`); strengthened in #103 to anchor against actual runtime emission via `EventFormattingSource` test seam — fake event drives `formatEventDict` through every conditional path, dict.keys becomes the source-of-truth compared bidirectionally with `validEventFields`. Manual mirror constant deleted.

### Security

- **`Int.max` boundary trap closed** (#101 F1, verify-fix from re-verify FAIL): `requireOptionalInt` and `requireIntIfPresent` now use `Int(exactly: d)` instead of `Int(d)`. Previously, a JSON payload `{"limit": 9223372036854776000}` (just above `Int.max`) decoded as `.double`, passed the bound check `d <= Double(Int.max)` (a tautology — `Double(Int.max)` rounds UP to 2^63 because `Int.max=2^63-1` is not exactly representable as `Double`), then `Int(d)` trapped the MCP server process. The cap at 10000 did not help — the trap fired inside `requireOptionalInt` BEFORE `requireOptionalLimit`'s cap check. Root-caused by 3-reviewer convergence (Logic + Security + Codex). DoS class; closed at root.
- **Validator-contract uniformity for `detail_level` + `display_timezone`** (#101 F2, verify-fix): both helpers previously used `arguments[K]?.stringValue` which returns `nil` for any non-string input, silently coercing to default. Same #28 R2-F1 type-coerce-bypass class as the B1/B2 fixes for `limit` + `fields`. Now distinguish absent (return default/nil) from present-but-non-string (throw `invalidParameter`). Restores the validator contract `Validation.swift:4-8` claims ("never silently drop or coerce").
- **`UTC` echo lossy fix** (#101 F3, verify-fix): `TimeZone(identifier: "UTC").identifier` returns `"GMT"` on Foundation/macOS (Foundation normalizes `UTC` to `GMT` internally). Previously the response `display_timezone` echo + envelope `timezone` field showed `"GMT"` for a requested `"UTC"`, lossy-by-spec. Helper signature changed from `displayTimezone: TimeZone?` to `requestedDisplayTimezone: String?`; all 4 echo sites in `Server.swift` now read raw user input via `arguments["display_timezone"]?.stringValue` so requested tokens round-trip verbatim.

## [1.7.2] - 2026-05-07

Hardening + features wave following the v1.7.1 security baseline. This release lands the post-merge sanitizer-hardening cluster (#73 #74 #80 #85 #86 #94), the install / CI / distribution infrastructure cluster (#49 #50 #51 #98), zh-TW docs sync (#75 #90), and post-v1.7.1 polish (#46 #57 #58 #60). 30+ commits since v1.7.1, all with `Refs #N` IDD discipline and 6-AI parallel verify before merge.

### Changed (post-v1.7.1 polish cluster — PR #63)

- **`scripts/build-mcpb.sh` step renumbering** (#57): seven script steps now use uniform `[1/7]` … `[7/7]` denominators instead of the mixed `[0/5]` / `[0.5/5]` / `[N/4]` / `[3.5/4]` pattern that PR #52 left behind when it inserted the sign + notarize step. Pure echo-string change; no behavior modification.
- **Redo error for `.createEvent` interpolates event title** (#46): `EventKitManager.executeRedo` for the `.createEvent` case now interpolates the original event title into the user-facing message ("Cannot redo creation of event '<title>' — please create it again manually"), using the same title-interpolation strategy as the sibling `.createReminder` arm. Also silences the SourceKit "immutable value 'title' was never used" warning on `main`.
- **`Sources/CheICalMCP/Entitlements.plist` documentation comment** (#58 item 5): adds an XML comment explaining intentional emptiness — hardened runtime alone is the macOS 26 TCC trigger, EventKit is user-prompt-driven and requires no entitlement key for outside-MAS distribution. Prevents future maintainers from over-claiming entitlements.
- **`Makefile release-signed:` cwd note** (#60 item 1): adds a comment on the `release-signed:` target noting it must be run from the repo root because it invokes `./scripts/build-mcpb.sh` via a relative path. Documents the `make -f /abs/path/Makefile release-signed` edge case identified during PR #52 verify.

### Hardening (post-v1.7.1 polish cluster — PR #63)

- **`scripts/sign-and-notarize.sh` pre-flight checks** (#59 items 1+3): adds two pre-flight checks — `xcrun` availability (clearer error than mid-flow `xcrun: error: unable to find utility "notarytool"` when Xcode Command Line Tools are missing) and Mach-O sanity check on `$BINARY` via `file ... | grep -q "Mach-O"` (catches fat-finger paths before `codesign` produces a cryptic "unsupported file type" error). Items 2+4 from #59 (idempotency optimization, cross-reviewer disagreement log) are deferred — see PR #63 description for rationale.

### Hardening (release-pipeline robustness — PR #76)

- **`scripts/sign-and-notarize.sh` post-notarize spctl cross-check** (#53): after `xcrun notarytool submit --wait` returns success, the new `[4/5]` step runs `spctl -a -vvv -t install $BINARY` and refuses to exit 0 unless the output matches `source=Notarized Developer ID`. Catches the partial-state race where notarytool reports success but Apple's CDN hasn't propagated the verdict — without this check, the binary would be packed into the .mcpb in a "signed but Gatekeeper-rejects" state and only fail on user first launch. Step counter renumbered `[1/4]…[3/4]` → `[1/5]…[5/5]` to absorb the new cross-check.
- **`scripts/build-mcpb.sh` pre-pack signature integrity check** (#53): whenever signing was requested (`$SHOULD_SIGN=true` — broader than `REQUIRE_CODESIGN`, so direct `./scripts/build-mcpb.sh` invocations with `DEVELOPER_ID` set also benefit), the script now runs (a) `codesign --verify --strict` for actual integrity, then (b) `codesign -dv | grep -F "Authority=$DEVELOPER_ID"` to confirm the EXACT identity the user asked for (not just "any Developer ID team"). Belt-and-suspenders against `sign-and-notarize.sh` exit-code loss in piped/CI invocations and against any post-sign tampering of the universal binary before `mcpb pack`.
- **`make verify-release-ready` target** (#48): new pre-flight that compares `AppVersion.current` against `git tag --sort=-creatordate | head -1` using `sort -V` for directional comparison. Three drift cases reported separately so the message is actionable — match (no bump needed), AHEAD (expected pre-release; tag when ready), BEHIND (downgrade alarm — DO NOT tag, investigate stale branch / bad merge first). `release-signed` now depends on this target so the warning surfaces every release-cut. Warning-only on drift; hard-fails ONLY when `Version.swift` cannot be parsed at all (because no other release target can succeed in that case anyway — `build-mcpb.sh` Step 0.5 also requires the same regex).

### Added
- **`cleanup_completed_reminders` tool** (#21): single-call cleanup of all completed reminders, eliminating the external list-then-delete loop that daily-cleanup automations used to require. `dry_run=true` default surfaces the exact scope before deletion (matches `delete_events_batch` safety pattern); optional `calendar_name` + `calendar_source` scope to a single list. Implementation composes existing `listReminders(completed:)` + `deleteRemindersBatch` primitives — no `EventKitManager` change. Inherits `deleteRemindersBatch`'s no-undo behavior (separate issue candidate to backfill).
  - `calendar_source` alone (without `calendar_name`) is rejected — EventKit cannot scope to "all lists on this account" and silently falling back to "all lists on all accounts" would be a destructive silent failure.
  - `limit` parameter (default 1000) caps each invocation; response includes `remaining` so callers can re-invoke to drain large backlogs without multi-MB responses or long blocking delete loops.
  - Dry-run preview returns only `reminder_id` (no titles/calendar names) — titles are attacker-controllable (malicious `.ics` invites, shared-list collaborators) and must not bypass the `UntrustedContentWrapper` boundary. Pipe through `list_reminders` (wrapped) when human-readable titles are needed.
  - Response shape is stable across dry-run / execute-empty / execute-non-empty branches: every response includes `dry_run`, `total`, `deleted_count`, `deleted_ids`, `failures`, `remaining`, and (when applicable) `message`. Dry-run reports zeros in the `deleted_*` fields so parsers don't need branch-aware key handling.
  - `total` reflects the **deduped** count of distinct reminders the tool will act upon. iCloud shared-list aliasing can cause `listReminders` to return the same reminder twice; the response fields use the post-dedupe count so `total == deleted_count + failures.count + remaining` holds as the caller's arithmetic sanity check.
  - `calendar_name` and `calendar_source` must be strings or absent. Non-string JSON input (e.g. `{"calendar_source": 123}`) is rejected with `invalidParameter` at the handler boundary — this prevents the type-coerce-to-nil bypass that would have silently widened cleanup to all accounts. `rejectSourceWithoutName` additionally rejects empty or whitespace-only `calendar_name` so the guard's safety is explicit, not coincidental on downstream `findCalendars` behavior.
- **`DispatchRoundTripTests`** (#21): guards against tool-name drift between `defineTools()` and the `executeToolCall` dispatch switch — catches the "compiles green, silently unroutable" class of bug that can't be caught by individual handler tests.
- **`ReminderCleanupTests`** (#21): pure-function unit tests for the `calendar_source` guard and the dedupe invariant F2 relies on.

- **`cleanup_completed_reminders` binding mode** (#28): new optional `reminder_ids: [String]` parameter. When supplied, the handler operates on exactly those IDs instead of re-listing completed reminders from the filter — so dry-run's "I approve these IDs" is honored verbatim by the execute call. Filter parameters (`calendar_name`, `calendar_source`, `limit`) are ignored in binding mode. Response includes a `mode` field (`"filter"` or `"binding"`) so callers can distinguish. Filter mode is unchanged (still re-derives the set for automation use).
  - Binding-mode execute path enforces the "only completed" invariant before deleting. A reminder un-completed in the Reminders app between dry-run and execute surfaces in `failures[]` with `"Reminder is no longer completed"` instead of being silently deleted (matches the schema's explicit promise).
- **`delete_events_batch` untrusted-content hardening** (#27): dry-run preview entries no longer echo `event.title` or `event.calendar.title` — both are attacker-controllable via malicious `.ics` invites or shared-calendar collaborators, and the handler is excluded from `UntrustedContentWrapper.readTools`. Mirrors the #21 F3 fix. Preview now returns only `event_id` + server-formatted dates; pipe through `list_events` for human-readable titles.
- **`list_reminders` / `list_reminder_tags` / `search_reminders` scope-invariant** (#29): all three handlers now reject `calendar_source` supplied without `calendar_name` (consistent with `cleanup_completed_reminders` as of #21). Non-string JSON input on either filter key is also rejected (R2-F1 type-coerce defense applied cross-handler). `search_reminders` was the same class bug, caught during #29 verification and folded into the same fix.
- **`ManifestParityTests`** (#30): new test guards drift between `Server.defineTools()` and `mcpb/manifest.json`. The #21 two-commit history — `feat` commit adding a tool to Swift, `docs` commit adding the manifest entry afterwards — demonstrated the failure mode. Now caught at `swift test` time.
- **`EventKitManaging` protocol + `FakeEventKitManager` + `CleanupHandlerTests`** (#31): protocol-oriented test harness for handler integration tests. `EventKitManaging` exposes the 2 methods `handleCleanupCompletedReminders` actually depends on (`listCompletedReminderIdentifiers` → `[String]` and `deleteRemindersBatch`); `CheICalMCPServer.init(reminderCleanupSource:)` accepts an injection with `EventKitManager.shared` as the default (production unchanged). `FakeEventKitManager` actor scripts return values and records invocations. `CleanupHandlerTests` (12 cases) pins #21 F1 guard ordering + integration-level type-coerce rejection (R2-F1), #21 F2 dedupe / R2-F2 arithmetic, #28 F1 `onlyCompleted` wiring, #21 F4 limit cap, #21 F8 response shape stability, and the binding-vs-filter mode branching. Narrow scope per `/spectra-discuss` convergence: protocol only covers methods the cleanup handler uses; other 30+ EventKitManager methods stay direct-singleton and will be protocol-fied on demand.
  - **Honest scope note**: integration tests pin the handler's contract with the EventKit primitive, not the primitive's internals. The destructive `if onlyCompleted && !reminder.isCompleted` guard inside `EventKitManager.deleteRemindersBatch` still requires its own test (tracked as #33). Deleting that guard would ship green against #31's suite. #31's closing summary references this gap explicitly.
- **`BatchDeleteFilter.shouldSkipUncompleted` extraction + 4-row truth table tests** (#33): closes the destructive-primitive test gap that #31 explicitly deferred. The `if onlyCompleted && !reminder.isCompleted` guard at `EventKitManager.swift:1383` was previously reachable only through real `EKEventStore` (TCC required), leaving the #28 F1 contract untested in CI. New `BatchDeleteFilter.shouldSkipUncompleted(isCompleted:onlyCompleted:) -> Bool` pure function carries the entire destructive rule; production code calls it instead of inline. New `BatchDeleteFilterTests` pins all 4 truth-table rows. The wire-visible message string (`"Reminder is no longer completed"`) is emitted by `EventKitManager` after the filter returns true; that contract is pinned by `CleanupHandlerTests` integration coverage, not duplicated here as a self-comparing constant test. 203 → 207 tests.

### Known follow-up (tracked separately)
- #32 _**(landed in this Unreleased window — see Security below)**_

### Security
- **`--self-update` SHA-256 verification before install (#98)**: closes the supply-chain gap that #49's verify (Codex Finding 1 HIGH) deferred — `--self-update` now downloads a `.sha256` companion file alongside the binary asset, computes the SHA-256 of the downloaded binary via `CC_SHA256` streaming hash, and refuses install on mismatch. Defense against in-flight tampering / mirror compromise / corrupted download. `scripts/build-mcpb.sh` now writes `mcpb/server/CheICalMCP.sha256` post-signature so release-time hash matches what `--self-update` will compute on the user's machine. Companion file format accepts both bare-hex and `shasum -a 256` standard output (`hash  filename`); BOM tolerated; first valid 64-hex token wins. Refuse-on-unparseable: if the release predates SHA-256 publication policy, install is rejected with explicit guidance to verify manually via codesign/spctl. 10 new tests pin parser + streaming-hash invariants (NIST FIPS 180-4 reference vectors for empty file + `"abc"`; deterministic-streaming check for 200 KB payload). Tests: 237 → 247 (+10). Codex Finding 1 Option B (Developer ID Team ID check via `codesign -dv`) deliberately not included — separate enhancement if Team ID hardcoding is acceptable; current Option A defense covers transit + mirror compromise.

### Added
- **`--self-update` CLI flag (#49)**: discoverable upgrade command for existing installs. Queries GitHub Releases API for the latest tag (`tag_name` field), compares against `AppVersion.current` via best-effort semver-ish parser, and (if newer) downloads the binary asset, makes it executable, and atomically replaces the current binary at its own path. Atomic-replace uses `rm -f` + `mv` (fresh inode, per #62 upgrade-trap fix — avoids macOS 26 stale code-signature SIGKILL on running MCP processes still holding the old inode). Closes the gap that plugin wrapper auto-download covers fresh-install only — existing v1.7.0 users couldn't auto-upgrade. Per #49 design discussion (4 options), chose **Option 3** (explicit user-invoked, discoverable via `--help` + README) over Option 1/2 auto-upgrade variants — auto would risk swapping binary mid-MCP-call. Network failure / parse / install errors all surface friendly `LocalizedError.errorDescription` strings (conform to `TrustedErrorMessage` so #41 carve-out keeps stderr clean). 11 new tests pin `stripTagPrefix` (leading `v` removal), `isNewer` (numeric semver-ish comparison: 1.7.10 > 1.7.9 numerically, prerelease lexicographic fallback), and `makeAssetDownloadURL` (URL shape pinned). Tests: 226 → 237 (+11).
- **`make install-signed` Makefile target (#50)**: Developer ID + hardened runtime signature WITHOUT notarization for fast maintainer dev iteration. Solves the macOS 26 TCC dogfood gap — ad-hoc signed binaries (`make install`) can't trigger Calendar / Reminders permission dialogs on macOS 26, breaking the maintainer's `--setup` flow verification. Trade-offs vs `release-signed`: signed-but-not-notarized → Gatekeeper online-checks on first launch (one-time stutter), suitable for maintainer dogfood / TCC flow verification on macOS 26, NOT for distribution to other users. Pre-condition: `DEVELOPER_ID` exported (`NOTARY_PROFILE` unused — no notarytool step).
- **`.github/workflows/test.yml` — PR-time test gate (#51 Layer 1)**: minimal CI workflow that runs `swift build` + `swift test` on every push/PR against `main`. Catches "PR breaks the test suite" before reviewer manual `swift test`. Runner pinned to `macos-latest` (EventKit is macOS-only). SPM `.build` cache keyed on `Package.resolved` for dependency-upgrade-aware invalidation. Concurrency group cancels in-progress runs on rapid push sequences. Layers 2 (lint workflows) + 3 (release automation with `.p12` cert in GH Secrets) deferred per #51 Strategy — see closing summary for trigger conditions.

### Documentation
- **`writeFailureLog` + R3 inline-write thread-safety best-effort posture (#70)**: documented the actual concurrency property of the 11 `FileHandle.standardError.write` sites — POSIX `write(2)` only guarantees atomicity for byte counts ≤ macOS `PIPE_BUF` (**512 bytes**, NOT 4096; that's Linux). Failure-line shape `<handler>(<identifier>) failed: <safeRawLog>\n` exceeds 512 bytes for any non-trivial `NSError.localizedDescription` (`maxRawLogChars` is 1024 chars alone). Concurrent `async` failing-tool-call races therefore CAN interleave on stderr; operators must NOT rely on `tail -f stderr | parse-by-line` producing perfectly framed records. Serial actor option (Option A — `StderrLogger.shared`) deferred — at this server's single-client concurrency profile, the contention window is narrow enough that touching every catch handler with `await` propagation exceeds the observability value. **Trigger to revisit Option A**: multi-tenant deployment / SRE interleaving complaint / structured stderr becoming load-bearing / `#66` periodic-summary mechanism. See `#70` closing summary for full deferral rationale.

### Tests
- **`Tests/CheICalMCPTests/Helpers/StderrCaptureHarness.swift` extraction (#83)**: centralized the `dup2`/`Pipe` stderr-capture pattern that #80 (`CLIRunnerStderrTests`) and #85/#86/#73/#74 (sanitizer cluster tests) had inlined separately. Provides `withCapturedStderr { ... } -> (result, stderr)` (full form, supports closure return + rethrows) and `capturedStderr(of:) -> String` (convenience for `() -> Void`). The dup2-deadlock fix discovered during #80 (must restore stderr BEFORE closing pipe write end, otherwise FD 2's dup keeps the write end open and `readDataToEndOfFile` blocks forever) is now in one place. Migrated `CLIRunnerStderrTests.swift` (171 → 124 LOC, -47) and 3 stderr-capture tests in `EventKitErrorSanitizerTests.swift` to use the helper. New `Helpers/` subdirectory exempt from `*Tests.swift` naming convention per CLAUDE.md addendum. Phase 3 of the diagnosis (R3 `deleteRemindersBatch` and R8 `Server.swift` outer-catch site-level carve-out tests) deferred — require new EventKit fakes / subprocess harness, separate scope.

### Security
- **`escapeForStderr` covers full C0 + DEL (#73)**: pre-fix only handled `\\` `\n` `\r`. ESC (`\x1b`) reached stderr verbatim — an attacker controlling `localizedDescription` (e.g. via event title interpolated by an EKError) could inject ANSI clear-screen + home-cursor sequences (`\x1b[2J\x1b[H`) that hijack the operator's terminal. NUL (`\x00`) had a similar gap (truncates C-string log readers like `tail` writing to syslog). Replaced 3-char `replacingOccurrences` fast-path with scalar walk: `< 0x20 || == 0x7F` → `\xHH` lowercase hex; legacy `\\`/`\n`/`\r` invariants preserved. Closes the residual that PR #65's outer-catch (#39) expanded surface to 11 stderr-write sites. Tests: 215 → 221 (+6 — ESC, NUL, BS, BEL, DEL, mid-range C0, ANSI clear-screen attack neutralization, Unicode passthrough, legacy backslash/LF/CR). C1 controls (`\x80..\x9F`) deferred — separate issue if alternate-form CSI hijacking becomes observed concern.
- **`sanitizeForInterpolation` defense-in-depth helper + 12-site retrofit (#74)**: new `EventKitErrorSanitizer.sanitizeForInterpolation(_:)` strips C0 + DEL (silent removal — empty replacement, no visible artifact) for user-controlled strings interpolated into response prose. Applied at every `executeUndo`/`executeRedo` title interpolation in `EventKitManager.swift` (12 sites total: 7 undo + 5 redo). Closes CWE-117 surface where an MCP host writing the wire `message` field to a non-escaping log writer (e.g. syslog) could be tricked into forged log entries via a malicious title (`"foo\n[ERROR] FORGED"`). Wire is already safe (JSON-encoded by `JSONSerialization`); helper provides server-side defensive layer regardless of host behavior. Per cluster Plan, kept SPLIT from `escapeForStderr` — different boundaries (response prose vs stderr operator log), different visibility intent (silent strip vs visible escape). Tests: 221 → 226 (+5). C1 explicitly NOT stripped per #74 scope.
- **`writeFailureLog` 1024-char cap on `rawLog` (#86)**: framework `NSError.localizedDescription` is theoretically unbounded. Pre-cap, batch handlers (e.g. `Server.swift:1836/2188-2274/2432-2546`, `EventKitManager.swift:838`) that fan out per malformed entry could amplify one oversize Apple error into MB-scale stderr volume. Cap fires before `escapeForStderr` (escape inflation can't expand the budget); suffix annotation `…[truncated N chars]` preserves the original size signal for operator debug. Tunable via `EventKitErrorSanitizer.maxRawLogChars`. Closes the DoS-amplification residual surfaced by 6-AI verify of #80 (security F#3). Tests: 212 → 214 (+2: long-rawLog truncation pin + short-rawLog passthrough sanity).
- **`CLIError.invalidJSON(_)` safety doc-comment (#85)**: `CLIError` conforms to `TrustedErrorMessage`, so `errorDescription` strings reach the wire (stdout JSON, escape-safe via `JSONSerialization`) but bypass `escapeForStderr`. Today's call sites pass static literals only, but a future contributor passing `error.localizedDescription` from a re-throw would route raw text through the carve-out unescaped — re-opening the CWE-117 window that #80 closed for the framework path. Doc-comment + grep audit becomes the future-contributor guard. Defense-in-depth (Option B over Option A enum-of-codes) per 6-AI verify of #80 (security F#2).
- **CLI runner stderr write delegated to `EventKitErrorSanitizer.writeFailureLog` (#80)**: `CLIRunner.run`'s catch was the 4th `FileHandle.standardError.write` site that escaped the R3/R7/R8 cluster's hardening — no trusted-branch carve-out (DoS-amplification window via `CLIError`, which conforms to `TrustedErrorMessage`) and no `escapeForStderr` (CWE-117 log-injection vector if a future macOS Calendar surface interpolates user-supplied event/reminder content with `\n`/`\r`). PR #79 verify surfaced the asymmetry; this issue closes it. `run()`'s catch now delegates to `writeFailureLog` (the canonical helper #72 established for R8), inheriting both invariants. To make the delegation unit-testable, the catch logic was extracted into `CLIRunner.handleRunError(_:toolName:)` (no `exit(1)`, returns to caller). Operator-facing stderr line shape changes from `CLIRunner failed: <log>` to `CLIRunner(<toolName>) failed: <log>` — `grep -rn "CLIRunner failed:"` confirmed only the source line itself matched repo-wide before the change. New `CLIRunnerStderrTests.swift` is the first stderr-capture test in the repo (pipe + `dup2(STDERR_FILENO, ...)` pattern; #83 will track extracting a shared harness for cluster-wide coverage). 4 tests pin: TrustedErrorMessage carve-out for both `CLIError` and `ToolError`, control-char escape on untrusted `NSError`, nil-toolName fallback to `<no-tool>`. Tests: 208 → 212 (+4).
- **#37 PR re-review — Codex adversarial findings landed** (commit `62d1031`): three additional trust-contract / sanitizer holes caught by `/codex:adversarial-review` after the 6-AI Round 1 verify. (1) `updateCalendar` and `copyEvent` previously built `EventKitError.calendarNotFound(identifier: "\(calendar.title) (read-only)")` — `calendar.title` is CalendarStore-sourced and could carry shared/subscribed calendar titles set by remote publishers. Fixed to echo the caller's own `identifier` / `toCalendarName` for the read-only refusal. (2) `CLIRunner.run` catch was bypassing the new sanitizer entirely; raw `error.localizedDescription` was being embedded in the stdout JSON `message` field. Extracted testable helper `CLIRunner.formatErrorForCLI(_:)` that routes through `EventKitErrorSanitizer.sanitizeForResponse(_:)`; CLI stdout now carries only sanitized codes, raw log goes to stderr. (3) `deleteRemindersBatch` cleanup catch was writing inline to stderr without applying the same control-char escape (`\\n`/`\\r`/`\\\\`) used by `writeFailureLog`. Promoted `EventKitErrorSanitizer.escapeForStderr` from `private` to `internal static` so the `sanitize(_:)`-bound R3 path can share the same escape without violating the spec's direct-binding requirement. Tests: 199 → 203 (+4: 1 read-only calendar regression + 3 CLI framework-error / trusted-passthrough pins). Round 2 verify is in-scope, no re-verify required per skill convention.
- **All non-cleanup batch handlers + outer `handleToolCall` catch sanitization** (#37): extends #32's sanitizer to **11 dispatch sites total = 10 `writeFailureLog` callers (R9) + 1 outer-catch site using `sanitizeForResponse` directly (R8)**. Originally 8 sites listed in the issue body; verify added `Server.swift:989` outer-catch (DA F3) and `findSimilarEvents` was caught via grep guard during apply. New `public protocol TrustedErrorMessage` is an empty marker that author-controlled error types opt into to assert their `errorDescription` is hand-written and safe to forward verbatim — `ToolError`, `EventKitError`, and `CLIError` conform; framework Foundation errors (`URLError`, `CocoaError`, `POSIXError`) deliberately do not. New `EventKitErrorSanitizer.sanitizeForResponse(_:)` type-dispatches: trusted → pass through; framework → existing `sanitize(_:)`. New `EventKitErrorSanitizer.writeFailureLog(handler:identifier:error:)` consolidates "sanitize + stderr + return code" into one call. Stderr writes escape `\n`/`\r` in `handler`/`identifier`/`rawLog` to prevent log-injection from user-supplied event titles or IDs (#37 verify F2). The trust marker on `EventKitError`'s `calendarNotFound` / `calendarNotFoundWithSource` / `multipleCalendarsFound` cases now suppresses the `available:` / `sources:` interpolation in `errorDescription` (#37 verify F1) — those cases would otherwise echo remote-publisher-controlled `EKCalendar.title` / `EKSource.title` strings (same #21/#27 threat class) through the trust path. Sites converted: `EventKitManager.swift:838` (`deleteEventsBatch`), `Server.swift:989` (outer `handleToolCall`, R8 path), `Server.swift:1836` (`createRemindersBatch`), `Server.swift:2188/2208/2227` (`createEventsBatch` parsers), `Server.swift:2274` (`createEventsBatch` save), `Server.swift:2318` (`findSimilarEvents`), `Server.swift:2432` (`moveEventsBatch`), `Server.swift:2474` (`deleteEventsBatch` series), `Server.swift:2546` (`deleteEventsBatch` dry-run preview). LOW-class wire output unchanged (`ToolError` parser messages appear verbatim); HIGH-class shifts from Apple text to stable `eventkit_error_<N>` codes; outer-catch wire shape (`"Error: <text>"`) preserved (no breaking change). 184 → 199 tests (+15: 7 sanitizer/marker + 1 NSError-not-trusted + 1 negative-code + 2 writeFailureLog + 1 control-char-passthrough + 3 outer-catch incl. trust-vs-framework distinguisher + 3 EventKitError trust-contract pins). #32's `deleteRemindersBatch:1387` continues to use `sanitize(_:)` directly per spec R3, completely unaffected.
- **`cleanup_completed_reminders` `failures[].error` sanitization** (#32): `EventKitManager.deleteRemindersBatch` previously echoed `error.localizedDescription` from `eventStore.remove` directly into `failures[].error`. Apple's current `NSError` text doesn't interpolate reminder content (verified during #21 R2 security review), but that's a load-bearing assumption on Apple's internal implementation. New `EventKitErrorSanitizer.sanitize(_:)` maps `Error` → `(code, rawLog)`. The `code` field — the only value forwarded to the MCP client — is derived **only** from `nsError.domain` + `nsError.code.magnitude` (never `userInfo`, never `localizedDescription`): `EKErrorDomain` → `eventkit_error_<N>`; other `NSError` → `error_<domain-slug>_<N>`; bridged Swift errors → `error_unknown`. The `rawLog` field IS `localizedDescription` verbatim, but writes only to stderr for operator debug — never to the response. `code.magnitude` ensures the spec value-domain regex `[0-9]+` is an invariant even when Foundation domains carry negative codes. No wire break: `failures[].error` remains a string. Narrow scope (matches #31 pattern): only the `deleteRemindersBatch` catch path is converted; sibling leaks (other batch handlers + outer `handleToolCall:989` catch for cleanup) are tracked in #37. Also benefits `delete_reminders_batch` since both tools share this manager method.

### Fixed
- **`formatJSON` crash on invalid JSON types** (#22): `JSONSerialization.data(withJSONObject:)` raises an Objective-C `NSInvalidArgumentException` on unsupported types (raw `Date`, `NaN`, `Infinity`, non-string dict keys) — an ObjC exception that Swift `try/catch` cannot capture, crashing the process in release builds. The previous `catch { return "[]" }` never actually handled this path. Now pre-checks with `JSONSerialization.isValidJSONObject(_:)` and throws `ToolError.invalidParameter`, which `handleToolCall` converts into MCP `isError: true`. Moved `formatJSON` / `actionResult` to top-level `ResponseFormatting.swift` to match the repo's utility-function pattern.
- **`findSimilarEvents` error swallowing in batch create** (#23): `try? await` in `handleCreateEventsBatch` was silently dropping EventKit errors during the similar-event hint lookup, so callers saw "no similar events" when the lookup had actually failed (mid-batch access revocation, predicate-breaking characters, actor reentrancy). Failures now log to stderr and surface in `response["similar_events_errors"]` so callers know the hint is incomplete; primary batch create/fail results unchanged.
- **Silent default-masking of numeric tool arguments** (#25): `arguments["priority"]?.intValue ?? 0` and similar patterns (`interval`, `tolerance_minutes`, `limit`) conflated "key absent" with "key present but unparseable". An LLM sending `priority: "high"` got `0` silently. New `InputValidation.requireIntIfPresent` helper separates the two — absent uses default, present must parse to an integer (whole-number doubles like `5.0` accepted for JSON-parser compatibility; strings and fractional doubles throw). 27-site audit; 5 call sites fixed, 22 boolean / string-enum defaults kept as legitimate "absent means default".

### Added
- **Build-time version consistency check** (#24): `scripts/build-mcpb.sh` now fails fast if `AppVersion.current`, `Info.plist` `CFBundleVersion`, and `mcpb/manifest.json` `version` drift apart. `server.json` is intentionally outside this check — it is an MCP Registry submission snapshot with an independent cadence (see README 'Release Process').

### Documentation
- **README Release Process table** (#24): documents the four version-carrying files, which are build-time coupled (three) vs independently updated (`server.json`), eliminating the 'is this a bug?' confusion that prompted the issue.

### Tests
- 18 new cases across `ResponseFormattingTests` (11) and `InputValidationTests` (7 for `requireIntIfPresent`). Total: 123 → 141.

## [1.7.1] - 2026-04-24

### Distribution
- **Upgrade trap fix** (#62): `make install` and `scripts/build-mcpb.sh` now `rm -f` the destination binary before writing. Without this, copying over an existing `~/bin/CheICalMCP` while old MCP server processes are still running reuses the same inode — and the macOS kernel caches code-signature hashes per-inode, so the new binary fails to exec with `load code signature error 2 / Taskgated Invalid Signature` SIGKILL. README user-facing install instructions also include `rm -f ~/bin/CheICalMCP` before `curl`. Discovered during macOS 26 TCC verification of #44.
- **macOS 26 codesigning + notarization** (#44): release binary is now signed with Developer ID Application + hardened runtime + notarized via `xcrun notarytool`. macOS 26 tightened TCC such that ad-hoc signed binaries can no longer trigger Calendar / Reminders permission dialogs — Developer ID + hardened runtime + notarization is the only path that lets end users grant access without manually re-signing the binary themselves.
  - New `scripts/sign-and-notarize.sh` wraps the codesign + ditto-zip + notarytool submit flow with pre-flight checks (cert in keychain, notarytool keychain profile configured) and friendly error messages including the submission ID for `xcrun notarytool log` post-mortem.
  - New `scripts/build-mcpb.sh` step `[3.5/4]` calls the signing script automatically. Auto-skips when `DEVELOPER_ID` env var is unset OR cert isn't in the keychain (so contributors / CI / forks can build a working unsigned `.mcpb` for testing without manually setting `SKIP_CODESIGN=1`).
  - New `Makefile` target `release-signed` is the canonical release-cut command.
  - `Sources/CheICalMCP/Entitlements.plist` (empty `<dict/>`) — minimal entitlements; hardened runtime alone is what macOS 26 requires for TCC. EventKit is user-prompt-driven (no entitlement key needed for outside-MAS distribution).
  - **Known limitation**: stapling skipped (raw Mach-O doesn't support `xcrun stapler staple`); Gatekeeper online-checks notarization on first launch, requiring one-time network access.
  - README "Release Process" gains a "Signing & Notarization" subsection with prerequisites, per-release flow, end-to-end verification (`spctl -a -vvv -t install`), and troubleshooting.

### Security
- **Input validation at MCP tool boundaries** (#20): `create_event`, `update_event`, `create_reminder`, `update_reminder`, and their batch counterparts now enforce length limits (title ≤ 255, notes ≤ 65535, location ≤ 1024) and a URL scheme allowlist (http / https only). Rejects `javascript:`, `file:`, `data:`, and other non-web schemes that could be rendered as clickable URIs by calendar clients.
- **Prompt-injection defense** (#20): Responses from tools that echo externally-sourced content (`list_events`, `search_events`, `list_events_quick`, `check_conflicts`, `find_duplicate_events`, `list_reminders`, `search_reminders`, `list_reminder_tags`) are wrapped with `[UNTRUSTED CALENDAR DATA ...]` markers over the MCP interface so consuming LLMs can distinguish data from instructions. CLI mode preserves pure JSON output.
- **Loud failures for LLM-malformed integer arrays**: `recurrence.days_of_week`, `recurrence.days_of_month`, and `alarms_minutes_offsets` now throw `ToolError.invalidParameter` on out-of-range or non-integer values. Previously the code silently dropped invalid elements with no warning, leaving callers unaware their input was partially ignored.
- **Force-unwrap crash eliminated** (originally from #20): `EKWeekday(rawValue:)!` in `EventKitManager.createRecurrenceRule` replaced with safe `compactMap`. With parse-boundary validation now in place, the safe-unwrap path is unreachable but retained for defense-in-depth.

### Fixed
- **`Info.plist` CFBundleVersion sync**: plist version was stuck at `1.4.1` since before the v1.5.0 release. Bumped to match `AppVersion.current`.

### Added (Tests)
- `InputValidationTests` (32 cases): URL scheme allowlist, length boundaries, Unicode grapheme semantics.
- `UntrustedContentWrapperTests` (10 cases): wrap format, allowlist membership (read tools included, write tools excluded).

## [1.7.0] - 2026-04-01

### Added
- **Attendee & organizer info** (#17): Event responses now include `attendees` array and `organizer` object (read-only from EventKit)
  - Each attendee: name, email, role, status, type, is_current_user
  - Organizer: name, email, is_current_user
  - Available in: `list_events`, `search_events`, `list_events_quick`, `check_conflicts`
  - Omitted when event has no participants

### Changed
- **Refactored event dict construction**: Extracted shared `formatEventDict` method, eliminating 3 duplicated event-to-JSON closures (~60 lines removed)
- **New `ParticipantFormatting.swift`**: Participant utilities as testable free functions

### Added (Tests)
- `ParticipantFormattingTests.swift`: 7 tests covering email extraction, role/status/type mapping

## [1.6.0] - 2026-03-31

### Added
- **`--setup` flag** (#13): Pre-authorize TCC (Calendars/Reminders) permissions for launchd and automation environments
- **Non-interactive session detection**: Detect launchd/SSH sessions via TERM, ppid, and environment variables; show targeted error messages with workaround instructions
- **`--cli` mode** (#14): Invoke all 28 tools directly from command line without starting MCP server
  - Flag-based mode: `CheICalMCP --cli list_events --start_date 2026-04-01 --end_date 2026-04-07`
  - JSON stdin mode: `echo '{"start_date":"2026-04-01"}' | CheICalMCP --cli list_events`
  - Smart type inference for bool/int/double/array parameters

### Changed
- **MCP Swift SDK 0.12.0**: Updated for Swift 6.3 compatibility
- **argv prioritized over stdin**: Fixes isatty hang in non-interactive environments

### Fixed
- **Non-interactive detection**: Improved SSH and launchd error handling (#13)
- **CLI arg parsing**: Native JSON types for stdin, smart type inference for argv (#14)

## [1.5.0] - 2026-03-28

### Added
- **Per-event timezone** (#12): `timezone` parameter on `create_event`, `update_event`, and `create_events_batch`; event output uses event's own timezone; naive datetimes parsed in event timezone
- **Clear due date** (#9): `clear_due_date` parameter on `update_reminder`
- **Weekday validation** (#5): `create_event` and `update_event` validate `start_time` weekday against `days_of_week`
- **Undo/redo system** (#8): 3 new tools — `undo`, `redo`, `undo_history`
- **Recurring event fixes** (#7): Occurrence-level delete and update with `occurrence_date`

### Changed
- **Swift 6 build** (#11): Updated build workflow and README for `make release`
- Tool count: 25 → 28

## [1.4.1] - 2026-03-25

### Improved
- **SSH session detection**: Detect SSH sessions via `SSH_CLIENT`/`SSH_CONNECTION` environment variables and show SSH-specific workaround instructions when calendar/reminder access is denied (#6)
- **SSH troubleshooting docs**: Added SSH Access section to README (EN + zh-TW) with two workarounds: run locally first to trigger TCC dialog, or grant Full Disk Access to sshd

## [1.4.0] - 2026-03-16

### Added
- **`searched_range` metadata in `search_events` response**: Returns the actual date range searched (`start`, `end`, `is_default_range`), enabling LLM consumers to verify coverage and self-correct when events are not found
- **`similar_events` hints in `create_events_batch` response**: Returns existing events with similar titles (by word match), helping LLMs reuse correct calendar names and avoid duplicates
- **`findSimilarEvents` internal method**: New EventKitManager method for title-based fuzzy matching with deduplication

### Changed
- **Fixed default search range**: `search_events` now defaults to ±2 years instead of `Date.distantPast`/`Date.distantFuture`. Apple's EventKit `predicateForEvents` can return incomplete results with extremely wide ranges, causing past events to be silently missed
- **Updated tool descriptions with LLM tips**: `search_events` and `create_events_batch` descriptions now include guidance for LLM callers (default range info, `searched_range` field, similar events hints)

### Summary
Improves `search_events` and `create_events_batch` for LLM reliability. Fixes a subtle EventKit bug where past events were silently missed, adds observability metadata, and provides deduplication hints. 25 tools (unchanged).

---

## [1.3.1] - 2026-02-26

### Changed
- **Clarified tag documentation**: Tags are MCP-level (stored as `#hashtag` text in notes), not native Reminders.app tags. Apple provides no public API for native tags. Updated tool descriptions, README, and CHANGELOG to reflect this accurately.

---

## [1.3.0] - 2026-02-25

### Added
- **Reminder tags** (MCP-level): `create_reminder`, `update_reminder`, and `create_reminders_batch` now accept a `tags` parameter. Tags are stored as `#hashtag` text in the reminder notes field, searchable and filterable through MCP tools. **Note:** These are MCP-managed tags, not native Reminders.app tags — Apple does not provide any public API (EventKit, AppleScript, or JXA) to create native Reminders tags programmatically
- **`list_reminder_tags`**: New tool to list all unique tags across reminders with usage counts
- **Tag filtering in `search_reminders`**: New `tag` parameter to filter reminders by tag
- **`clear_tags`**: `update_reminder` supports `clear_tags: true` to remove all tags from a reminder
- **Tags in output**: `list_reminders` and `search_reminders` now return a `tags` array and show clean notes (without the tag line)

### Changed
- Updated MCP Swift SDK dependency to 0.11.0
- `search_reminders` now accepts tag-only searches (without keywords)

### Summary
1 new tool (24 → 25 total). Tags feature enables MCP-level categorization and filtering of reminders through `#hashtag` text in notes. Note: Apple provides no public API for native Reminders tags.

---

## [1.2.0] - 2026-02-22

### Added
- **Idempotent writes**: All create operations (`create_event`, `create_events_batch`, `create_reminder`, `create_reminders_batch`, `create_calendar`) now perform check-before-write to prevent duplicate data when AI agents retry failed requests
- **Duplicate detection at lowest layer**: Idempotency checks implemented in `EventKitManager` (data access layer), protecting all callers automatically
- **Idempotency keys**: Events use `title + startDate + calendar`, reminders use `title + dueDate + list`, calendars use `title + entityType`
- **Skipped status in responses**: Batch operations now report `skipped` count and per-item `skipped: true` for duplicates
- **`find_duplicate_events` handler**: Exposed duplicate event detection as a standalone tool

### Summary
No new tools (24 total). Major reliability improvement: all write operations are now idempotent, preventing duplicate data creation when agents retry due to network errors or response loss.

---

## [1.1.0] - 2026-02-06

### Added
- **Recurrence rules**: `create_event`, `update_event`, `create_reminder`, and `create_events_batch` now accept a `recurrence` parameter to create recurring events/reminders (daily, weekly, monthly, yearly with interval, end date, occurrence count, days of week/month)
- **`clear_recurrence`**: `update_event` supports `clear_recurrence: true` to remove recurrence rules from existing events
- **Structured locations**: `create_event`, `update_event`, and `create_events_batch` now accept `structured_location` with coordinates (title, latitude, longitude, radius) for map-integrated event locations
- **Location triggers**: `create_reminder` and `update_reminder` now accept `location_trigger` to set geofence-based reminders that fire on enter/leave
- **`clear_location_trigger`**: `update_reminder` supports `clear_location_trigger: true` to remove location-based alarms
- **Rich recurrence output**: `list_events`, `search_events`, and `list_events_quick` now return full `recurrence_rules` details (frequency, interval, end date, days) instead of just `is_recurring: true`
- **Structured location output**: Event responses now include `structured_location` with coordinates when available
- **Location trigger output**: Reminder responses now include `location_trigger` details when geofence alarms are set

### Summary
No new tools (24 total). Two major feature enhancements: recurring event/reminder creation (previously infrastructure-only, now fully exposed via MCP) and location-based triggers for both events and reminders.

---

## [1.0.0] - 2026-02-06

### Breaking Changes
- **`list_events` response format**: Changed from plain array to `{"events": [...], "metadata": {...}}`
- **`list_reminders` response format**: Changed from plain array to `{"reminders": [...], "metadata": {...}}`

### Added
- **Flexible date parsing**: All date parameters now accept 4 formats:
  - ISO8601 with timezone: `2026-02-06T14:00:00+08:00`
  - Datetime without timezone: `2026-02-06T14:00:00` (uses system timezone)
  - Date only: `2026-02-06` (00:00:00 system timezone)
  - Time only: `14:00` (today at that time)
- **Fuzzy calendar matching**: Calendar lookup now falls back to case-insensitive matching; error messages include all available calendars/lists
- **`list_calendars` source_type**: Each calendar now includes a `source_type` field (Local/iCloud/Exchange/CalDAV/Subscribed/Birthdays)
- **`list_events` filter/sort/limit**: New parameters `filter` (all/past/future/all_day), `sort` (asc/desc), `limit`
- **`list_reminders` filter/sort/limit**: New parameters `filter` (all/incomplete/completed/overdue), `sort` (due_date/creation_date/priority/title), `limit`; each reminder now includes `is_overdue` and `creation_date` fields
- **`delete_events_batch` date range mode**: Can now delete by calendar + date range (not just by event IDs); includes `dry_run` mode (default: true) for safe preview before deletion
- **Unit tests**: Added `FlexibleDateParsingTests.swift`

### Summary
Major quality-of-life improvements focused on developer experience. No new tools added (24 total), but significant enhancements to existing tools.

---

## [0.9.0] - 2026-01-30

### Added
- **`update_calendar`**: Rename a calendar or change its color
- **`search_reminders`**: Search reminders by keyword(s) in title or notes, with AND/OR matching and completion status filter
- **`create_reminders_batch`**: Create multiple reminders in a single call with per-item success/failure tracking
- **`delete_reminders_batch`**: Delete multiple reminders in a single call with detailed results

### Summary
4 new tools added (20 → 24 total). This release rounds out Reminders support with search and batch operations, and adds calendar update functionality.

---

## [0.8.2] - 2026-01-30

### Fixed
- **Critical: `this_week`/`next_week` week boundary calculation** - Fixed an issue where week calculations depended on system locale, causing incorrect results for users with different cultural conventions for first day of week

### Added
- **New `week_starts_on` parameter for `list_events_quick`** - Supports international week definitions:
  - `system` (default): Uses system locale settings
  - `monday`: ISO 8601 standard (Europe, Asia)
  - `sunday`: US, Japan convention
  - `saturday`: Middle East convention
- Response now includes `week_starts_on` field showing the effective week start day used
- Unit tests for week calculation with different firstWeekday settings

### Changed
- Updated MCP Swift SDK dependency to 0.10.2 (strict concurrency improvements)

### Technical Details
Previously, `this_week` and `next_week` used `Calendar.current.firstWeekday` without explicit control. This caused:
- Users expecting Monday-start weeks (ISO 8601) to get Sunday-start results on US-locale systems
- Inconsistent behavior depending on system locale

The fix allows explicit control while defaulting to system locale for backwards compatibility.

---

## [0.8.1] - 2026-01-25

### Fixed
- **Critical: `update_event` time validation bug** - Fixed an issue where updating only `start_time` without `end_time` could result in an invalid event state (startDate > endDate), causing the event to become unsearchable or invisible in the calendar
- When only `start_time` is provided, the event's original duration is now automatically preserved
- Added explicit validation to reject events where start time is not before end time (for non-all-day events)

### Added
- New error type `invalidTimeRange` for clearer error messages when time validation fails
- Improved `update_event` tool description with clearer documentation about time handling
- Added `all_day` parameter to `update_event` tool for converting between timed and all-day events
- Unit test framework with time validation tests

### Technical Details
The bug occurred because `startDate` and `endDate` were updated independently. When moving an event from Jan 25 to Jan 31 with only `start_time`, the event would have:
- `startDate`: Jan 31, 14:00
- `endDate`: Jan 25, 15:00 (unchanged from original)

This invalid state caused EventKit to handle the event incorrectly. The fix preserves the original event duration when only the start time changes.

---

## [0.8.0] - 2026-01-16

### Changed
- **BREAKING**: `calendar_name` is now **required** for `create_event`, `create_events_batch`, and `create_reminder`
- Removed implicit default calendar behavior to prevent events being saved to unexpected calendars
- Improved error messages guide users to use `list_calendars` to see available options

### Why This Change
Previously, if `calendar_name` was not specified, events/reminders would be saved to the system's default calendar. This caused confusion when users had multiple accounts (iCloud, Google, Exchange) and didn't know where their data went. Now the API explicitly requires specifying the target calendar.

---

## [0.7.0] - 2026-01-15

### Added
- **Tool annotations**: Added MCP tool annotations for Anthropic Connectors Directory submission
- **Auto-refresh mechanism**: Improved event store refresh handling
- **Enhanced batch tool descriptions**: Clearer documentation for batch operations

---

## [0.6.0] - 2026-01-14

### Added
- **`calendar_source` parameter**: New optional parameter for disambiguating calendars with the same name across different sources (e.g., iCloud, Google, Exchange)
- Added to 10 tools: `list_events`, `create_event`, `update_event`, `list_reminders`, `create_reminder`, `update_reminder`, `search_events`, `list_events_quick`, `check_conflicts`, `create_events_batch`
- **`target_calendar_source` parameter**: For `copy_event` and `move_events_batch` tools
- **Improved error messages**: When multiple calendars share the same name, the error now lists all available sources for disambiguation

### Changed
- Refactored calendar lookup logic with new `findCalendar()` and `findCalendars()` helper methods
- Clearer error handling for calendar-not-found scenarios

## [0.5.0] - 2026-01-14

### Added
- **`delete_events_batch`**: Delete multiple events at once, much more efficient than calling `delete_event` multiple times
- **`find_duplicate_events`**: Find duplicate events across calendars before merging, matches by title (case-insensitive) and time (configurable tolerance)
- **Multi-keyword search**: `search_events` now supports multiple keywords with `match_mode` parameter (`any` for OR, `all` for AND)
- **PRIVACY.md**: Added privacy policy document explaining data handling

### Changed
- **Improved permission error messages**: When calendar/reminders access is denied, now provides clear instructions for granting permissions
- **Enhanced search_events response**: Now includes search metadata (keywords used, match mode, result count)

## [0.4.0] - 2026-01-14

### Added
- **`copy_event`**: Copy an event to another calendar, with optional `delete_original` flag for move behavior
- **`move_events_batch`**: Move multiple events to another calendar at once

## [0.3.0] - 2026-01-13

### Added
- **`search_events`**: Search events by keyword in title, notes, or location
- **`list_events_quick`**: Quick time range shortcuts (today, tomorrow, this_week, next_week, this_month, next_7_days, next_30_days)
- **`create_events_batch`**: Create multiple events at once with success/failure tracking
- **`check_conflicts`**: Check for overlapping events in a time range
- **Local timezone display**: All date responses now include both UTC and local time
- **Timezone field**: All responses include the current timezone identifier

## [0.2.0] - 2026-01-12

### Changed
- Complete rewrite from Python to Swift
- Native EventKit integration (no AppleScript)

### Added
- Full Reminders support: `list_reminders`, `create_reminder`, `update_reminder`, `complete_reminder`, `delete_reminder`
- Calendar management: `create_calendar`, `delete_calendar`
- Event alarms/reminders support
- URL support for events

## [0.1.0] - 2026-01-10

### Added
- Initial Python version
- Basic calendar event operations via AppleScript
- `list_calendars`, `list_events`, `create_event`, `update_event`, `delete_event`

---

## Tool Count by Version

| Version | Total Tools | New Tools |
|---------|-------------|-----------|
| 1.3.1   | 25          | Docs: clarified tags are MCP-level, not native Reminders.app tags |
| 1.3.0   | 25          | +1 (list_reminder_tags), MCP-level tags support in create/update/search/batch |
| 1.0.0   | 24          | Enhancement: flexible dates, fuzzy matching, filter/sort/limit, batch delete with dry_run |
| 0.9.0   | 24          | +4 (update_calendar, search_reminders, create_reminders_batch, delete_reminders_batch) |
| 0.6.0   | 20          | Enhancement: calendar_source parameter for disambiguation |
| 0.5.0   | 20          | +2 (delete_events_batch, find_duplicate_events) |
| 0.4.0   | 18          | +2 (copy_event, move_events_batch) |
| 0.3.0   | 16          | +4 (search_events, list_events_quick, create_events_batch, check_conflicts) |
| 0.2.0   | 12          | +7 (5 reminder tools, 2 calendar tools) |
| 0.1.0   | 5           | Initial release |
