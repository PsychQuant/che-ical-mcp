# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Event listing response-shape parameters** (#101, originally PR #47 by @fabiocarvalho777, taken over with `Co-authored-by` after 6-AI verify FAIL): four optional parameters on `list_events`, `search_events`, and `list_events_quick`:
  - `detail_level` (string, `"summary"` | `"standard"`, default `"standard"`): preset response-verbosity tiers. `summary` returns 10 core fields (id/title/dates/timezone/is_all_day/calendar/location); `standard` returns all fields. Cuts token usage substantially when LLM consumers don't need notes/url/recurrence/attendees.
  - `fields` (string array): fine-grained field selection — overrides `detail_level` when both supplied. Unknown field names rejected with `invalidParameter` listing all available options. Non-array input or non-string elements throw with the offending index, not silently dropped (#28 R2-F1 type-coerce-bypass class).
  - `display_timezone` (string, IANA Region/City or `UTC`): converts `*_local` timestamp fields to specified zone. Strict membership check via `TimeZone.knownTimeZoneIdentifiers` rejects abbreviations (`PST`/`EST`) and POSIX-style offsets (`GMT+08:00`) that have ambiguous DST semantics. Per-event `timezone` field continues to report event's own zone. `list_events_quick` envelope `timezone` echoes the requested zone instead of system tz so renders are internally consistent (M4).
  - `limit` (integer): added to `search_events` and `list_events_quick` (was already on `list_events`). Loud-failure on type mismatch (per #25) — string `"5"`, fractional `5.5`, etc. throw rather than silent-coerce. Bounds: must be `> 0` and `≤ 10000` (defense-in-depth against accidentally-massive responses).

### Changed

- **`search_reminders.result_count` → `reminder_count`** (#102, breaking wire-format change): renames the response envelope field on the reminder side, mirroring #101 M1 on the event side. The reminder tool family now matches the event family's `<entity>_count` convention. MCP clients hardcoding `result_count` need to update.
- **`search_events.result_count` → `event_count`** (#101 M1, breaking wire-format change): renames the response envelope field across event-listing tools (`list_events_quick.event_count` was already canonical; `list_events.metadata.returned` keeps post-limit semantics). MCP clients hardcoding `result_count` need to update.
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
