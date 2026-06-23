---
name: remind
description: Create a reminder from natural language
allowed-tools:
  - mcp__che-ical-mcp__list_calendars
  - mcp__che-ical-mcp__create_reminder
---

# Quick Reminder Creation

Create a reminder from the user's natural language input.

## Process

1. **Parse input**: Extract task title, due date/time, priority
2. **Get reminder lists**: Use `list_calendars` with type="reminder" if needed
3. **Create reminder**: Use `create_reminder`

## Examples

User: "Remind me to buy milk"
→ create_reminder(title="Buy milk", calendar_name="Reminders")

User: "Call mom tomorrow at 5pm"
→ create_reminder(title="Call mom", due_date="2026-01-19T17:00:00+08:00", calendar_name="Reminders")

User: "Submit report by Friday - high priority"
→ create_reminder(title="Submit report", due_date="...", priority=1, calendar_name="Reminders")

## Priority Values
- 1 = High priority
- 5 = Medium priority
- 9 = Low priority
- 0 = No priority (default)

## Tips
- Ask user for reminder list if they have multiple
- Default to "Reminders" list if not specified
