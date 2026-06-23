---
name: quick-event
description: Quickly create a calendar event from natural language
allowed-tools:
  - mcp__che-ical-mcp__list_calendars
  - mcp__che-ical-mcp__check_conflicts
  - mcp__che-ical-mcp__create_event
---

# Quick Event Creation

Parse the user's natural language input and create a calendar event.

## Process

1. **Parse input**: Extract title, date, time, duration, location from user's request
2. **List calendars**: Show available calendars if not specified
3. **Check conflicts**: Verify the time slot is available
4. **Create event**: Use `create_event` with proper ISO8601 datetime format

## Examples

User: "Meeting with John tomorrow at 2pm for 1 hour"
→ Parse: title="Meeting with John", date=tomorrow, start=14:00, duration=1h
→ Create: start_time="2026-01-19T14:00:00+08:00", end_time="2026-01-19T15:00:00+08:00"

User: "Dentist on Friday 10am at 123 Main St"
→ Parse: title="Dentist", date=Friday, start=10:00, location="123 Main St"
→ Create with location parameter

## Important

- Always confirm the calendar to use if user hasn't specified
- Default event duration: 1 hour if not specified
- Always use local timezone (e.g., +08:00 for Taiwan)
