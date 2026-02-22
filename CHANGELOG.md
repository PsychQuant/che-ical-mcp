# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
| 1.0.0   | 24          | Enhancement: flexible dates, fuzzy matching, filter/sort/limit, batch delete with dry_run |
| 0.9.0   | 24          | +4 (update_calendar, search_reminders, create_reminders_batch, delete_reminders_batch) |
| 0.6.0   | 20          | Enhancement: calendar_source parameter for disambiguation |
| 0.5.0   | 20          | +2 (delete_events_batch, find_duplicate_events) |
| 0.4.0   | 18          | +2 (copy_event, move_events_batch) |
| 0.3.0   | 16          | +4 (search_events, list_events_quick, create_events_batch, check_conflicts) |
| 0.2.0   | 12          | +7 (5 reminder tools, 2 calendar tools) |
| 0.1.0   | 5           | Initial release |
