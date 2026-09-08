# Changelog — che-ical-mcp plugin

All notable changes to the `che-ical-mcp` Claude Code plugin are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> The plugin version tracks the `CheICalMCP` binary version (the wrapper auto-downloads
> the matching GitHub Release). Entries below are the plugin-facing condensation that also
> appears in the **Changelog** section of [`README.md`](README.md); the binary's full,
> categorized changelog lives in the repository root [`CHANGELOG.md`](../CHANGELOG.md).
> Entries marked *plugin shell only* / *documentation only* / *metadata only* shipped no
> binary change.

## [Unreleased]

## [1.18.0] - 2026-09-09

- **`undo(discard_id)` clears a jammed history head (#206/#214)**: a blocked top record can be removed explicitly by the stable ID shown in `undo_history`; a missing target is no longer kept as a permanently "transient" entry for deleted reminders or dead events. Stale IDs and active history execution are rejected.
- **Completion dates survive undo/redo (#196/#211/#212)**: undo writes back the recorded `completion_date` instead of letting EventKit stamp the undo time; completing an already-completed reminder keeps its original instant; redo restores the saved instant.
- **Entity-specific recurrence read fields (#198)**: `event_recurrence_rules` / `reminder_recurrence_rules` distinguish the two rule formats; legacy `recurrence_rules` aliases are retained.
- **Event moves restore to the original calendar (#208)**: `copy_event delete_original` and `move_events_batch` record the source occurrence so undo puts it back where it came from, and both declare `destructiveHint`. All tool annotations now have an explicit tested policy (#209); `complete_reminder` is `destructiveHint: true` (#202).
- **BREAKING — every boolean tool argument is a strict JSON boolean (#207)**: `all_day`, `clear_*`, `include_completed`, `dry_run`, `delete_original` and per-item batch `all_day` reject strings/numbers with `<key> must be a boolean (true or false)`; omitted or `null` keeps the default.
- Reminder list/search filter, sort and limit inside the EventKit actor before building snapshots (#197); `list_reminder_tags` reads through the snapshot seam (#203); trailing tag parsing is linear, no exponential backtracking (#216); reminder write results are immutable Sendable snapshots (#215).

## [1.17.0] - 2026-09-07

- **Recurring reminders (#194)**: `list_reminders` / `search_reminders` expose `has_recurrence`, structured `recurrence_rules` (incl. `frequency_raw_value`) and a `due` object (`date` / `time` / `timezone` / `date_time`). `complete_reminder` separates the write outcome (`operation`) from the saved object (`observed`) and reports the successor as `next_occurrence` (`confirmed` / `unknown` / `not_applicable`), observed once synchronously after save; the message carries the next due in the reminder's own wall clock. Contract: `docs/REMINDER_RECURRENCE.md`.
- **Identity-guarded undo for recurring completions (#204)**: undo/redo act only while the identifier still resolves to the recorded occurrence; otherwise they refuse explicitly and drop the entry so older operations stay undoable.
- **BREAKING — strict boolean `completed` (#205)**: `complete_reminder`, `list_reminders` and `search_reminders` reject a string or number `completed` before any read or write; omitted or JSON `null` keeps the old meaning (complete / no filter).

## [1.16.1] - 2026-08-31

- **Series-deletion undo no longer fails with EKCADErrorDomain 1010** (#191): recurrence rules are captured as value snapshots and rebuilt on restore; a failed `undo` / `redo` now puts its record back on the stack instead of silently consuming it.
- **`all_day` + `timezone` is rejected explicitly** (#190) instead of silently degrading the event to a timed one; a non-object `recurrence` value is rejected instead of silently dropped (#184).

## [1.16.0] - 2026-08-31

- **New `archive-event` skill** (#180): archive an event from a narrative source (meeting notice, announcement, mail thread) with update-vs-create keyed on the original notice's Message-ID, mandatory estimate labelling + source citation, and three-tier calendar choice. `quick-event` description sharpened to mark the boundary.
- **`excluded_occurrence_dates`** (#182): skip specific dates in a recurring series at creation time via `create_event` / `create_events_batch`; responses echo the normalized dates + `exclusion_count`; one `undo` removes the whole series including exclusions.
- **Batch and series deletions now record undo entries** (#185): `delete_events_batch` and series deletion are each a single undo unit, consistent with `delete_event`.

## [1.15.0] - 2026-07-10

- **Versioned-host drift signal** (#175): the startup banner detects a Claude Code versioned host binary (`~/.local/share/claude/versions/<v>`) with EventKit not fully granted and points at the host-side System Settings toggle instead of `--setup`.
- **`--print-tcc-path` prints its execution context** (#169, #173): the parent process chain up to launchd plus a context-dependence warning; truncation, cycles and `ps` failures are surfaced instead of ending silently.

## [1.14.2] - 2026-07-07

_docs / skill layer only_

- **`troubleshoot-tcc` covers the host-app (responsible-process) TCC layer** (#168): the skill, `/check-tcc`, `mcpb/README.md` and `plugin/CLAUDE.md` document the two-layer authorization model and which System Settings toggles to flip for Claude Code vs Claude Desktop. Binary byte-identical to 1.14.1.

## [1.14.1] - 2026-07-05

_metadata only_

- Tool-count consistency across published surfaces (`server.json`, `PROMOTION.md`, `docs/COMPETITIVE_ANALYSIS.md` corrected to 29 tools). Binary functionally identical to 1.14.0.

## [1.14.0] - 2026-07-03

- **Claude Desktop tool-injection drop fixed** (#166): a literal `&` in `mcpb/manifest.json` `display_name` made Desktop 1.18286.0 silently drop the whole 29-tool server from every conversation (Claude Code was unaffected). Changed `&` → `and`; confirmed by single-variable intervention on the failing install + a `ManifestParityTests` regression guard. Also aligned `serverInfo.name` to the kebab manifest id (hygiene; empirically refuted as the cause).
- **#154 sister batch**: csreq-mismatch TCC drift signal (#155, `SecCodeCheckValidity` self-check for the silent-denial class), `.mcpb` denial message no longer dead-ends on `--setup` for the already-`.denied` signature (#158), macOS badge 13.0 → 14.0 (#157), swift-nio 2.96 → 2.101 (#159). 454 tests.

## [1.13.0] - 2026-06-23

- **SwiftUI SetupWindow** (#164): interactive `--setup` presents a live-status window (per-entity Grant buttons + resolved binary path) inside the #163 foreground `NSApplication`.
- **Desktop Calendar-denied fix** (#165): `isNonInteractive` misfired on `TERM == nil` for GUI-app-spawned servers → fast-failed before `requestFullAccess`, so the first-grant dialog never appeared through Claude Desktop; now uses a `CGSession` GUI-session signal. 429 tests.

## [1.12.0] - 2026-06-23

- **Foreground `--setup`** (#163): interactive `--setup` now runs inside a foreground `NSApplication` so EventKit's Calendar TCC modal actually presents (previously silently denied from a bare CLI async context). Denial messages + startup banner surface the resolved binary path + a copy-pasteable `"<path>" --setup` command for the buried `.mcpb` binary.

## [1.11.1] - 2026-06-18

- **`create_event` time-range validation** (#160): symmetric with `update_event` — rejects inverted / zero-duration timed events via a shared `validateTimeRange` guard. 405 tests.

## [1.11.0] - 2026-06-10

- **TCC healing re-prompt unblocked** (#154): `Entitlements.plist` now ships `com.apple.security.personal-information.calendars` + `.reminders`. Long-lived installs upgraded from the pre-v1.7.1 ad-hoc era could hit silent permanent Calendar denial on macOS 26.5 — the TCC row stays pinned to the old build's cdhashes while the healing re-prompt was policy-blocked (binary had no entitlements), with every diagnostic reporting green. First launch of this build is finally allowed to re-prompt; approving rewrites the row keyed to the Developer ID requirement. New `EntitlementsPlistTests` + value-aware signed-binary release gate.
- **BREAKING**: deploy floor raised to macOS 14.0 (Sonoma) (#119)
- Non-interactive EventKit access hardening (#131/#143/#144) + verify follow-ups (#146–#150); 401 tests

## [1.10.0] - 2026-05-12

- **TCC drift detector + startup banner** (#122): single-shot `[banner]` line on MCP-server-mode startup with version/path/PID + drift signals (TCC.db path mismatch per-service, stale running processes). Banner is advisory, stderr-only, opt-out via `CHE_ICAL_MCP_NO_BANNER=1`. Hardened against CWE-117 stderr-injection on every interpolated value (R1 sanitization).
- **R3.3 production POSIX hygiene fix**: parent pipe write-end fd close in `LiveTCCDatabaseSource` + `LiveProcessInventorySource`. R1's read-before-wait order fix was complementary; R3.3 completes the POSIX EOF contract that local macOS 26 masked via aggressive fd scheduling but GHA macos-15-arm64 reliably deadlocked on.
- **#131 CI hardening**: 8 tests (5 binary-spawn banner + 3 real-server dispatch) compile-time excluded on CI via `#if !CI_BUILD` + `-Xswiftc -DCI_BUILD` workflow flag. Root cause: EventKit framework blocks on TCC prompt in macOS 15 (Sequoia) headless CI sandbox, where macOS 26 (Tahoe) returns `.denied` synchronously. CI runs 330/330; local runs 338/338. Tracked in #131.

## [1.9.1] - 2026-05-11

_plugin shell only_

- 4 plugin-shell additions exposing v1.9.0 TCC features: `troubleshoot-tcc` skill (5-step diagnostic), `/check-tcc` slash command, `eventkit-error-debugging` rule (routes accessDenied/insufficientAccess/unknownAuthState investigations to TCC-first), CLAUDE.md plugin overview.

## [1.9.0] - 2026-05-11

- **TCC access gate refactor** (#108 Phase 2, closes #109): removes process-lifetime `hasCalendarAccess`/`hasReminderAccess` cache anti-pattern; replaces with per-call `EKEventStore.authorizationStatus(for:)` cheap check via new `AuthorizationGate` + `AuthorizationStatusSource` test seam. Aligns with Apple TN3153 documented per-call pattern — TCC state changes surface immediately as actionable `accessDenied`/`insufficientAccess`/`unknownAuthState` errors instead of silent fail.
- **`--print-tcc-path` diagnostic flag** (#109): prints binary path, bundle identifier, EventKit authorization status, `tccutil reset` snippet (with bundle ID interpolated), `sqlite3` TCC.db query snippet, and System Settings paths. Designed for `.mcpb` installed users who need to locate the extracted binary path before running `--setup` from Terminal.

## [1.8.1] - 2026-05-11

_documentation only_

- `mcpb/README.md` post-install / upgrade TCC permission setup guide (#108 Phase 1). Diagnoses the silent-failure mode where reinstalling `.mcpb` invalidates the existing TCC grant.

## [1.8.0] - 2026-05-11

- **Wire-format consistency wave** — closes #101 cluster (5 issues: #102 #103 #104 #106 #107) in 3 days, full IDD lifecycle + 6-AI ensemble verify per issue
- **Event listing response-shape parameters** (#47/#101): `detail_level` (`summary`/`standard`), `fields` allow-list, `display_timezone` (strict IANA), `limit` (cap 10000) — LLM token-usage tuning
- **Envelope unification — BREAKING wire-format** (#102/#107): `list_events`/`list_reminders` `metadata.returned` removed; all 5 list/search envelopes use top-level `<entity>_count` with pre-limit semantic; `search_reminders.result_count` → `reminder_count`; `search_reminders` gains `limit` parameter
- **Validator hardening** (#101 F1–F3): `Int.max` DoS trap closed, `detail_level`/`display_timezone` validators no longer silent-coerce non-string inputs, `UTC` echo round-trips verbatim
- **Runtime-anchored drift detection** (#103, strengthening #101 M3): `formatEventDict` ↔ `validEventFields` divergence test now via `EventFormattingSource` test seam + `FakeFormattableEvent`
- **CHANGELOG reclass** (#106): wire-format renames moved from `Fixed` → `Changed` (Keep a Changelog 1.1.0)
- **Release pipeline fix**: `build-mcpb.sh` pre-pack defense now derives Team ID from `DEVELOPER_ID` cert via `security find-identity` (was incorrectly comparing SHA hash against `Authority=` human-readable string)

## [1.7.2] - 2026-05-07

- **Tool count 28 → 29**: `cleanup_completed_reminders` (#21) — single-call cleanup of all completed reminders, `dry_run=true` default
- **`--self-update` flag** (#49): existing-install upgrade path with SHA-256 verification (#98). Wrapper auto-download covers fresh-install only; this fills the gap
- **Sanitizer hardening cluster** (#73 #74 #80 #85 #86 #94): full C0+DEL escape coverage, executeUndo/executeRedo title interpolation guard, CLIRunner stderr trusted-branch carve-out, DoS amplification cap, thread-safety doc with macOS PIPE_BUF=512
- **CI test workflow** (#51): PR-time `swift build` + `swift test` on macos-latest
- **`make install-signed`** (#50): maintainer dev TCC flow on macOS 26
- **Distribution polish**: README install snippets `rm -f` preamble (#90), zh-TW v1.7.1 sync (#75)
- All 30+ commits with `Refs #N` IDD discipline + 6-AI parallel verify before merge

## [1.7.2-pre] - 2026-04-22

_pre-release plugin shell bump only_

- Plugin wrapper now version-aware: re-downloads `~/bin/CheICalMCP` when binary lags upstream Release

## [1.7.1] - 2026-04-20

- Repo URL migration: kiki830621 → PsychQuant org (no behavior change)

## [1.7.0] - 2026-04-01

- Attendee + organizer info exposed on read paths
- Tool count reaches 28 (added `find_duplicate_events`, batch operations, etc.)

## [1.6.0] - 2026-03-30

- Tool surface broadened to cover full reminders CRUD + tag listing

## [1.5.0] - 2026-03-29

- Per-event timezone support (no longer pinned to system locale)
- Undo / redo on calendar mutations
- 28 tools total

**1.3.x – 1.4.x** (2026-02-22 – 2026-03-23)
- Day-of-week verification PreToolUse hook (catches "Friday 2026-04-26" mismatches)
- i18n SessionStart / current-time helper
- Alarms support on `update_event`

**1.0.0 – 1.2.x** (2026-02-06 – 2026-02-23)
- Initial stable release; iCal binary auto-install + update check

**0.8.x – 0.9.x** (2026-01-30)
- Week boundary calculation fix; `week_starts_on` parameter (`system` / `monday` / `sunday` / `saturday`)
- `update_event` time validation fix; `all_day` parameter

[Unreleased]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.17.0...HEAD
[1.17.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.16.1...v1.17.0
[1.16.1]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.16.0...v1.16.1
[1.16.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.15.0...v1.16.0
[1.15.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.14.1...v1.15.0
[1.14.1]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.14.0...v1.14.1
[1.14.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.12.0...v1.14.0
[1.12.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.11.1...v1.12.0
[1.11.1]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.11.0...v1.11.1
[1.11.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.10.0...v1.11.0
[1.10.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.8.1...v1.9.0
[1.8.1]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.7.2...v1.8.0
[1.7.2]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/PsychQuant/che-ical-mcp/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/PsychQuant/che-ical-mcp/releases/tag/v1.5.0
