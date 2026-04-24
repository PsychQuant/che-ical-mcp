# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Follow-ups from the PR #26 multi-agent review — hardening that extends the 1.7.1 security wave. To be cut as 1.7.2 on the next release.

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

### Known follow-up (tracked separately)
- #31: handler-level integration tests for `handleCleanupCompletedReminders` (requires EventKitManager test-double infra).
- #32: `failures[].error` EventKit `localizedDescription` surface hardening.

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
