## Problem

In a time zone that moves its clock from 23:59:59 straight to 01:00 (`America/Havana` on 2028-03-12), a date-only value naming that day is refused as "not a valid date" (PsychQuant/che-ical-mcp#546, rows 1 to 4), so an all-day event cannot be put on that day by date. EventKit also returns such an event's end at 00:59:59 of the next day in that zone (device, iCloud, `TZ=America/Havana`, 2026-11-22): `update_event` then counts two days, so a start-only move of a one-day event on that day makes it two days, and `list_events` shows the wrong hours (row 5; the issue's Google calendar gave the start at 23:00 the evening before instead).

## Root Cause

- `FlexibleDate.parse` reads a date-only value with a non-lenient `DateFormatter` in the zone; 00:00 of that day does not exist there, so the formatter returns nil.
- The output and `AllDayRange.planUpdate` read an all-day event's `startDate` / `endDate` as EventKit returns them, and on that day EventKit does not return (start of the day, last second of the last day).

## Proposed Solution

- When the date-only formatter returns nil in the zone, read the same text with the same formatter in UTC (no skipped time), and return the first instant of that day in the zone. `2026-02-30` and malformed text stay refused (#299).
- `AllDayRange.storedDays(start:end:calendar:)`: an all-day pair read as the days it stands for: a start that is not the start of its day stands for the nearest day start, the number of days is the elapsed time rounded to whole days; only a pair whose first day so read does not start at 00:00 is read anew, and a pair more than three hours from that reading is returned unchanged. The identity on every ordinary day, whatever the end.
- `planUpdate` reads the stored all-day pair through it before counting; `formatEventDict` (`list_events`, `list_events_quick`, `search_events`, `check_conflicts`) prints an all-day event's dates through it, in the host zone.

## Non-Goals

- Row 6 of #546: the store saves a timed event that spans the skipped hour in its own zone an hour short (recorded on #566); the server counts the days of what it reads.
- `copy_event`, undo restore, the duplicate check and occurrence-day matching (#568); a date-time inside the skipped hour (#567); the observations moved to #566.
- The update write order (#364): the device cells showed it does not change the result.

## Success Criteria

- A date-only value on such a day parses to 01:00 of that day; impossible and malformed dates are still refused.
- A one-day all-day event on that day, moved by `start_time` alone, stays one day.
- The event dict gives that event from `T01:00:00` to `T23:59:59` of that day; every ordinary all-day pair and every timed event is printed as before.

## Impact

- Affected specs: new capability `all-day-skipped-midnight`.
- Affected code: `Sources/CheICalMCP/FlexibleDate.swift`, `Sources/CheICalMCP/EventKit/AllDayRange.swift`, `Sources/CheICalMCP/Server.swift` (`formatEventDict`).
