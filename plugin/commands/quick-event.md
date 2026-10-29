---
name: quick-event
description: Quickly create a calendar event from natural language when the time and place are already known and stated directly. For deriving an event from a source — a meeting notice, an announcement, a message thread — where the time may have been corrected and the basis should be recorded, use the archive-event skill instead.
allowed-tools:
  - mcp__che-ical-mcp__list_calendars
  - mcp__che-ical-mcp__check_conflicts
  - mcp__che-ical-mcp__create_event
  - mcp__che-ical-mcp__search_events
  - mcp__che-ical-mcp__list_events
---

# Quick Event Creation

Parse the user's natural language input and create a calendar event.

## Process

If the input matches a module's trigger in [`rules/event-modules.md`](../rules/event-modules.md) (today: a conference program or a booking for a stay) and that module is on, build it as the module says and skip the steps below for what the module handles (a program, a stay); other private items in the same message, such as a flight, still go through them; if the module is off or no trigger matches, carry on below. (`search_events` and `list_events` in `allowed-tools` are there for the module's dedup; its updates ask for permission, because this command's own steps only create.)

1. **Parse input**: Extract title, date, time, duration, location from user's request
2. **Choose the calendar**: if the user named one, use it. Otherwise resolve it as [`rules/calendar-routing.md`](../rules/calendar-routing.md) says (a folder's `calendar_routing` rules); when no rule applies, show the available calendars and ask. This command does not read `default_calendar`.
3. **Check conflicts**: Verify the time slot is available
4. **Create event**: Use `create_event` with proper ISO8601 datetime format
5. **Report** how the calendar was decided (the `Routed to …` or `Not routed: …` line from the rule)

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
- Always use local timezone (e.g., +08:00 for Taiwan); a module's events follow the module (a conference's sessions use the conference's zone)
