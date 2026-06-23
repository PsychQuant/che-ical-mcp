---
name: week
description: Show this week's calendar overview
allowed-tools:
  - mcp__che-ical-mcp__list_events_quick
  - mcp__che-ical-mcp__list_reminders
---

# Weekly Overview

Provide a comprehensive view of the user's week:

1. **Events**: Use `list_events_quick` with range "this_week"
   - Optional: Use `week_starts_on` parameter to control week start:
     - `system` (default): Use system locale
     - `monday`: ISO 8601 standard (Europe, Asia)
     - `sunday`: US, Japan convention
     - `saturday`: Middle East convention
2. **Tasks**: Use `list_reminders` with completed=false

Present as a day-by-day breakdown:
- Monday: [events]
- Tuesday: [events]
- etc.

Highlight:
- Busy days vs free days
- Any scheduling patterns
- Upcoming deadlines from reminders
