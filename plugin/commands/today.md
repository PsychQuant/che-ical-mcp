---
name: today
description: Show today's calendar events and pending reminders
allowed-tools:
  - mcp__che-ical-mcp__list_events_quick
  - mcp__che-ical-mcp__list_reminders
---

# Today's Schedule

Show the user their schedule for today:

1. **Events**: Use `list_events_quick` with range "today" to get all events
2. **Tasks**: Use `list_reminders` with completed=false to get pending tasks

Present the information in a clear, organized format:
- Group events by time
- Highlight any conflicts or overlaps
- Show reminders with due dates

If there are no events or reminders, let the user know their day is clear.
