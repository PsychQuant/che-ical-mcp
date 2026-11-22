## Problem

In a time zone that moves its clock from 23:59:59 straight to 01:00 (`America/Havana` on 2028-03-12), a date-only value naming that day is refused as "not a valid date" (PsychQuant/che-ical-mcp#546, rows 1 to 4), so an all-day event cannot be put on that day by date. EventKit also returns such an event's end at 00:59:59 of the next day in that zone (device, iCloud, `TZ=America/Havana`, 2026-11-22): `update_event` then counts two days, so a start-only move of a one-day event on that day makes it two days, and `list_events` shows the wrong hours (row 5; the issue's Google calendar gave the start at 23:00 the evening before instead).

## Root Cause

- `FlexibleDate.parse` reads a date-only value with a non-lenient `DateFormatter` in the zone; 00:00 of that day does not exist there, so the formatter returns nil.
- The output and `AllDayRange.planUpdate` read an all-day event's `startDate` / `endDate` as EventKit returns them, and on that day EventKit does not return (start of the day, last second of the last day).

## Proposed Solution

The round-one amendments in the `idd-546-fix1` change describe the revised inputs, date shapes, display and occurrence window.

- Keep the existing formatter first. For all-day endpoints and occurrence selectors, parse the date in UTC after the local formatter refuses it, check the exact spelling, and find the first instant of the same day in the parsing zone.
- Use `AllDayRange.storedDays` to correct the recognized iCloud and Google pairs in the server process zone. Use the normal display-zone rules for local strings. Apply the same correction in `update_event` when a stored all-day event stays all-day.
- Bound the occurrence lookup by consecutive day starts so the following day's first hour is outside the gap day.

## Non-Goals

查詢區間、衝突判定、全天場次的日期歸屬、比對與複製維持使用儲存值，待 #568 處理。維護者決定保留第 6 列於 #546 的範圍。轉換前讀回的定時結束時間已少一小時，哪一層縮短仍待釐清（量測見 #566），因此第 6 列仍待 #546 處理，PR #571 不應結束該議題。

## Impact

- Affected specs: new capability `all-day-skipped-midnight`.
- Affected code: `Sources/CheICalMCP/FlexibleDate.swift`, `Sources/CheICalMCP/EventKit/AllDayRange.swift`, `Sources/CheICalMCP/Server.swift` (`formatEventDict`).
