---
name: calendar-management
description: Guide for effective use of che-ical-mcp for macOS Calendar & Reminders management. Use when user asks about calendar events, reminders, scheduling, or time management.
allowed-tools:
  - mcp__che-ical-mcp__list_calendars
  - mcp__che-ical-mcp__create_calendar
  - mcp__che-ical-mcp__delete_calendar
  - mcp__che-ical-mcp__list_events
  - mcp__che-ical-mcp__create_event
  - mcp__che-ical-mcp__update_event
  - mcp__che-ical-mcp__delete_event
  - mcp__che-ical-mcp__list_reminders
  - mcp__che-ical-mcp__create_reminder
  - mcp__che-ical-mcp__update_reminder
  - mcp__che-ical-mcp__complete_reminder
  - mcp__che-ical-mcp__delete_reminder
  - mcp__che-ical-mcp__search_events
  - mcp__che-ical-mcp__list_events_quick
  - mcp__che-ical-mcp__create_events_batch
  - mcp__che-ical-mcp__check_conflicts
  - mcp__che-ical-mcp__copy_event
  - mcp__che-ical-mcp__move_events_batch
  - mcp__che-ical-mcp__delete_events_batch
  - mcp__che-ical-mcp__find_duplicate_events
---

# macOS Calendar & Reminders Management

This skill guides you through effective use of che-ical-mcp for calendar and task management on macOS.

## Date/Time Format

**CRITICAL**: Always use ISO8601 format with timezone for all date/time parameters:
```
2026-01-18T14:00:00+08:00  (correct)
2026-01-18 14:00           (wrong - will fail)
```

Use the user's local timezone. For Taiwan: `+08:00`

## Tool Categories

### 1. Discovery (Start Here)
Before creating or modifying, always check existing state:

```
list_calendars          → See all calendars and their sources
list_events_quick       → Quick view: "today", "this_week", "next_7_days"
list_reminders          → See tasks by list or completion status
```

### 2. Events (Calendar)
| Task | Tool | Key Parameters |
|------|------|----------------|
| View schedule | `list_events` | start_date, end_date, calendar_name |
| Quick view | `list_events_quick` | range: "today", "tomorrow", "this_week", week_starts_on |
| Create event | `create_event` | title, start_time, end_time, calendar_name (required) |
| Search | `search_events` | keyword/keywords, match_mode ("any"/"all") |
| Check availability | `check_conflicts` | start_time, end_time |

**Week Start Day (v0.8.2+)**: For `this_week`/`next_week` ranges, use `week_starts_on`:
- `system` (default): Use system locale
- `monday`: ISO 8601 (Europe, Asia)
- `sunday`: US, Japan
- `saturday`: Middle East

### 3. Reminders (Tasks)
| Task | Tool | Key Parameters |
|------|------|----------------|
| List tasks | `list_reminders` | calendar_name, completed (true/false/omit) |
| Create task | `create_reminder` | title, calendar_name (required), due_date |
| Complete | `complete_reminder` | reminder_id, completed (true/false) |

### 4. Batch Operations (Efficiency)
| Task | Tool | When to Use |
|------|------|-------------|
| Create multiple | `create_events_batch` | Recurring meetings, series |
| Move multiple | `move_events_batch` | Calendar migration |
| Delete multiple | `delete_events_batch` | Cleanup old events |
| Find duplicates | `find_duplicate_events` | Before merging calendars |

## Common Workflows

### Schedule a Meeting
```
1. check_conflicts(start_time, end_time)  → Ensure no overlap
2. create_event(title, start_time, end_time, calendar_name, location?, alarms_minutes_offsets?)
```

### Weekly Review
```
1. list_events_quick(range: "this_week")  → See upcoming events
2. list_reminders(completed: false)       → See pending tasks
3. search_events(keywords: ["important"]) → Find priority items
```

### Calendar Migration
```
1. list_calendars()                       → Identify source/target
2. find_duplicate_events(calendars, date_range)  → Check for duplicates
3. move_events_batch(event_ids, target_calendar) → Move events
```

## Source Disambiguation

When multiple calendars have the same name (e.g., "Work" in both iCloud and Google):

```
create_event(
  calendar_name: "Work",
  calendar_source: "iCloud",  ← Specify the source
  ...
)
```

Available sources: "iCloud", "Google", "Exchange", "CalDAV", "Local"

## Best Practices

1. **Always specify calendar_name** for create operations (v0.8.0+)
2. **Use batch operations** for multiple similar actions
3. **Check conflicts** before scheduling important events
4. **Use search** instead of listing all events when looking for specific items
5. **Prefer list_events_quick** over list_events for common ranges
6. **Specify week_starts_on** when user's locale differs from expected (v0.8.2+)
