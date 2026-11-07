# che-ical-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**Give Claude native control of macOS Calendar and Reminders.** A Swift MCP server built directly on EventKit — 29 tools for events, reminders, tags, batch operations, conflict detection, and undo/redo. Not just calendar events: it drives Reminders and tasks too.

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## Install

**Claude Code** — register this repo as a marketplace, then install the plugin. The plugin bundles the `/today`, `/week`, `/quick-event`, `/remind` slash commands and a PreToolUse hook that verifies day-of-week on every event write:

```bash
claude plugin marketplace add PsychQuant/che-ical-mcp
claude plugin install che-ical-mcp@che-ical-mcp
```

**Claude Desktop** — download the latest `.mcpb` from [Releases](https://github.com/PsychQuant/che-ical-mcp/releases/latest) and double-click to install.

**Standalone MCP** — the 29-tool server on its own, no plugin extras:

```bash
mkdir -p ~/bin
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP && chmod +x ~/bin/CheICalMCP
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

On first use, macOS prompts for **Calendar** and **Reminders** access — click **Allow**. Building from source, upgrading in place, or running under SSH / launchd / VS Code? See [Installation](#installation) for the full guide.

---

## Why che-ical-mcp?

| Feature | Other Calendar MCPs | che-ical-mcp |
|---------|---------------------|--------------|
| Calendar Events | Yes | Yes |
| **Reminders/Tasks** | No | **Yes** |
| **Reminder #Tags** | No | **Yes** (MCP-level) |
| **Multi-keyword Search** | No | **Yes** |
| **Duplicate Detection** | No | **Yes** |
| **Conflict Detection** | No | **Yes** |
| **Batch Operations** | No | **Yes** |
| **Local Timezone** | No | **Yes** |
| **Source Disambiguation** | No | **Yes** |
| Create Calendar | Some | Yes |
| Delete Calendar | Some | Yes |
| Event Reminders | Some | Yes |
| Location & URL | Some | Yes |
| Language | Python | **Swift (Native)** |

---

## All 29 Tools

<details>
<summary><b>Calendars (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_calendars` | List all calendars and reminder lists (includes source_type) |
| `create_calendar` | Create a new calendar. A title is 1 to 255 characters and not only whitespace, also on `update_calendar`, and `type` is `event` or `reminder`. The limit is not a promise that a long title stays: a 255-character title was among those `list_calendars` stopped showing in one run (#449). If saving a reminder list reports an error but the list turns out to be saved, the call succeeds; if whether it was saved cannot be checked, the list is kept and the call fails with an error that says how to check before creating it again (#289); fields the store holds differently are listed in `store_differs` with a `note`, and creating it again with the same parameters may make a second copy (#261) |
| `delete_calendar` | Delete a calendar or reminder list (not undoable). `require_empty: true` refuses one that holds any event (checked only about 200 years either side of now; a passed check returns `checked_empty`, `searched_from` / `searched_to`) or any reminder (#328) |
| `update_calendar` | Rename a calendar or change its color (v0.9.0) |

</details>

<details>
<summary><b>Events (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_events` | List events with filter/sort/limit (v1.0.0) |
| `create_event` | Create an event (with reminders, location, URL, per-event timezone, recurrence with excluded dates) |
| `update_event` | Update an event (including timezone, recurrence, span for recurring) |
| `delete_event` | Delete an event (with occurrence support for recurring) |

> **A reminder's identifier given to an event tool (#260)**: `update_event`, `delete_event`, `copy_event`, `move_events_batch` and `delete_events_batch` answer `Event not found: <id>` (a row error in the batch tools) instead of ending the server. Without Reminders access EventKit may not report the item as a reminder; the event lookup's Objective-C exception is then caught, and the tool answers that the lookup failed and the event may still exist (#288). That was measured with the kind check switched off, and a run with Reminders access actually denied has not been done. The check itself (`calendarItem(withIdentifier:)`) is not wrapped, so if it raises there, the process can still end (#293).

> **Recurrence exclusions (#182)**: `create_event` (and each `create_events_batch` item) accepts `recurrence.excluded_occurrence_dates` to skip specific dates in a recurring series at creation time — applied with best-effort all-or-nothing semantics (any failure removes the entire new series via compensating delete; rollback failure is reported, never silent; the first occurrence cannot be excluded), and one `undo` removes the whole series including exclusions. The excluded dates are removed occurrences, not edited ones (checked on iCloud only, 2026-10-05; other stores were not checked), so they do not stop that undo; an occurrence edited on its own after the series was created does (#236). Known limitation: on idempotent retry, a duplicate recurring series with every requested date already absent is `skipped`, but extra exclusions already present on the existing series (beyond those requested) are not detected.

</details>

<details>
<summary><b>Reminders (8)</b></summary>

| Tool | Description |
|------|-------------|
| `list_reminders` | List reminders with filter/sort/limit, tags extraction (v1.0.0) |
| `create_reminder` | Create a reminder with due date, tags (v1.3.0); a bare `YYYY-MM-DD` due date makes it date-only (#267); with a due date, bare or timed, the response carries `date_sync` with `aligned` judged on the saved reminder (#301, #308; a timed due that lost its time zone on save is written again and saved a second time, as `update_reminder` does). If the save reports an error but the reminder turns out to be saved, the call succeeds; fields the store holds differently are listed in `store_differs` with a `note`, and creating it again with the same parameters may make a second copy (#261); a save that failed and could not be checked keeps the reminder and fails with an error that says how to check before creating it again (#289) |
| `update_reminder` | Update a reminder (including tags, `clear_due_date`) (v1.3.0) |
| `complete_reminder` | Mark as completed/incomplete |
| `delete_reminder` | Delete a reminder |
| `search_reminders` | Search reminders by keyword(s) or tag (v1.3.0) |
| `list_reminder_tags` | List all unique tags with usage counts (v1.3.0) |
| `cleanup_completed_reminders` | Delete all completed reminders in one call, dry_run preview by default (v1.7.2); one `undo` recreates what it deleted (#243) |


**Recurring reminders (#194):** list/search include `has_recurrence`, complete public `recurrence_rules`, and precision-aware `due`. Completion adds `operation` (write outcome) and `next_occurrence` (confirmed/unknown/not_applicable). Use `operation.status` rather than legacy `is_completed`: a successful completion may leave the next occurrence incomplete. Unknown successor information must not trigger a second write. A different-ID or unconfirmable successor is reported as `unknown`, never as the series having ended. Undo of a recurring completion is identity-guarded (#204): once the identifier no longer resolves to the recorded occurrence it refuses explicitly and drops its history entry instead of jamming the stack. **Breaking (#205):** `completed` must be a JSON boolean on `complete_reminder` / `list_reminders` / `search_reminders` — strings and numbers are rejected; omit or `null` keeps the old meaning. **Breaking (#207, unreleased):** the same contract now applies to every boolean tool argument (`all_day`, `clear_*`, `include_completed`, `dry_run`, `delete_original`). See [response contract and limitations](docs/REMINDER_RECURRENCE.md).

**Rescheduling reminders (#227/#235/#237):** In the rows measured, the Reminders.app list showed a reminder's earliest time-based alarm (#433), so `update_reminder` with a timed `due_date` moves the start date and every absolute-date alarm along with the due date (a bare date makes the reminder date-only instead, see below; by calendar days when the old due date has no time; otherwise by the exact difference). `clear_due_date` also clears the start date and removes absolute-date alarms. A move keeps any offset that already exists, so to repair a reminder whose alarm already disagrees with its due date pass `realign_to_due: true` (with `due_date`, or alone for the current due date; relative alarms stay, so an early relative alarm still sets what the list shows): the earliest absolute-date alarm lands on the due date, later ones keep their spacing after it, and the start date is set to the due date unless it already agrees with it (any time on its day for a date-only due; the due time, or its day at midnight or without a time, for a timed due). The response reports what moved in `date_sync`, and `date_sync.aligned` says whether, on the saved reminder, the start date and the earliest absolute-date alarm agree with the due date (an alarm set apart on purpose also reads `false`). A timed due date written to a floating reminder, such as a date-only one made in Reminders.app, keeps its explicit time zone. Undo restores the start date and alarms, location alarms included (#228).

**Alarms after completing a repeating reminder (#423):** completing a repeating reminder that has a location trigger leaves one plain relative alarm at 0 minutes (no location) on the next occurrence and on the completed copy (measured on iCloud; it does not appear without a location trigger, without recurrence or without a completion, and a later completion does not add another, whether the alarm is still there or was removed). Completing a reminder sets only the completion fields; EventKit or the store adds this alarm when that save rolls the reminder over, and which of the two was not told apart. After a confirmed rollover `complete_reminder` reads the next occurrence back and reports its relative alarms as `next_occurrence.alarms_minutes_offsets`, with `alarms_note` naming any that appeared on that read and were not there before the completion (an alarm from another app or a sync would look the same). When the next occurrence cannot be re-read, or changed in between, `next_occurrence.alarms_read_back` is `false` with `alarms_read_back_note` and no alarms are reported. With any other `next_occurrence.status` these fields are absent. Nothing is written (a default: removing the alarm was not chosen, since its purpose is unknown); `update_reminder` with `alarms_minutes_offsets` removed it in the cases tried. Whether it fires and whether Reminders.app shows it are not checked. The completed copy gets a new identifier and is not read.

**`recurrence` keys are checked (#434):** `create_event`, `create_events_batch`, `update_event`, `create_reminder` and `update_reminder` refuse any key in `recurrence` other than `frequency`, `interval`, `end_date`, `occurrence_count`, `days_of_week`, `days_of_month` and, on the two create-event tools, `excluded_occurrence_dates`, and write nothing for that item. Such a key used to be ignored, so `count` in place of `occurrence_count` created a series that never ends. The same tools refuse, and write nothing for that item: `end_date` together with `occurrence_count`; a non-empty `days_of_month` on a `daily` or `weekly` rule, which EventKit stores but does not use (measured on iCloud; monthly and yearly rules use it, and every frequency uses `days_of_week`); and any key of `recurrence`, or a read tool's `recurrence_rules`, `event_recurrence_rules` or `reminder_recurrence_rules` beside `recurrence` instead of inside it.

**`occurrence_count` on a yearly event rule with `days_of_week` (#444):** on a rule with `interval` 1 and no `days_of_month`, the store does not count occurrences, so 6 gave 22 (measured on iCloud). `create_event`, `create_events_batch` and `update_event` refuse a count there, even 1, and write nothing. For those days, use `monthly` with `interval: 12`, which holds the count, except that from a later occurrence with span `future` it can come out short (#443), or `end_date`. For once a year, use `yearly` without `days_of_week`. A yearly rule with `days_of_week` repeats in the start's month. `interval` above 1 and a non-empty `days_of_month` are not refused: the count held. The reminder tools are unchanged: there the count held.

**A rule belongs to the series (PR #439):** `update_event` refuses `recurrence` or `clear_recurrence` on one occurrence (`occurrence_date` with span `this`) and `clear_recurrence` with `occurrence_date` and span `future`, and writes nothing. In every release from v1.5.0 (measured on iCloud on v1.22.0, read at the other tags), a rule saved on one occurrence deleted the rest of the series, `clear_recurrence` with span `future` left only one event on the series' first day, and `clear_recurrence` with span `this` detached the occurrence as a one-off and left the series repeating. Use span `all` for the whole series, and span `future` with `occurrence_date` to change a rule from that occurrence on. To end a series at an occurrence, pass span `all` and `recurrence` with the series' whole rule and an `end_date` after that occurrence's start, such as 23:59:59 that day: a bare date ends before that day's occurrence, and later occurrences go, also one edited on its own (measured on iCloud). `clear_recurrence` with span `all` leaves one event on the first day and deletes the other occurrences. An id of the form `<series>/RID=<n>`, one occurrence edited on its own, is told the series' id. `recurrence` with `clear_recurrence` is refused too.

**A failed reminder write may still land (#274):** when a commit of an existing reminder or reminder list fails, the change can stay pending in the server's store, and the next save of anything can write it (measured on iCloud, with a failure induced for the test; no ordinary use was found that causes one). A deleted reminder then has no undo, and a deleted list goes with every reminder in it. It cannot be dropped without disturbing other calls, so the error says so, and a batch delete adds `failed_rows_note`. Reading back right after does not rule it out: what a read shows before the next save was not measured. EventKit refusals 18, 23 and 26 left nothing behind and answer as a plain error. The one exception to the warning is a failed second save of a due date (#237), which answers `date_sync.aligned: false` with no error, and what may land there is the date asked for. Events and event calendars did not behave this way.

**Changing a reminder's recurrence (#354):** `update_reminder` accepts `recurrence` (the object `create_reminder` takes, without `excluded_occurrence_dates`), which replaces the reminder's rule, and `clear_recurrence: true`, which removes it; the identifier, completion history and alarms stay. A rule change does **not** move the due date (a default, which can be revisited): measured on iCloud, after a weekly Thursday reminder is changed to Friday its pending occurrence stays on Thursday, and once that is completed the next one is on Friday (measured for a weekly rule on one weekday; for other rules this is expected, not measured). When the due date is not on the new rule's days the response adds `recurrence_note`; pass `due_date` to `update_reminder` to move it. The response reads back `has_recurrence`, `reminder_recurrence_rules` and `due` from the saved reminder after re-reading it (`recurrence_read_back: false` with `recurrence_read_back_note` when it cannot be re-read). `interval` must be 1 to 1000 and `occurrence_count` 1 to 10000 on every tool that takes `recurrence`: an interval below 1 or from 2^31 to 2^32, or an `occurrence_count` of 0, used to crash the server (measured), and the rest of the refused range is refused as unreasonable. Refused before anything is written: `recurrence` with `clear_recurrence` or with `clear_due_date`; a rule on a reminder that will have no due date; a rule on a completed reminder; and `clear_due_date` on a reminder that keeps repeating (a repeating reminder must have a due date; pass `clear_recurrence` with it to make it one-off). Undo restores the previous rule (tested in memory, and on a session MCP pending the release gate). How Reminders.app displays the off-rule occurrence was not checked.

**Relative alarms on reminders (#333):** `create_reminder`, each row of `create_reminders_batch` and `update_reminder` accept `alarms_minutes_offsets`, minutes before the due date (positive = before, negative = after; integers from -525600 to 525600, one year; the same bound now applies to the event tools), so the stored due date keeps its real time and the notification can come earlier (in the rows measured the list, and the one banner checked, showed the alarm time, see below). Only relative alarms are written: on `update_reminder` the list replaces the reminder's relative alarms and `[]` removes them, while absolute-date alarms (#227) and the location trigger (#229) are not changed. This differs from `update_event`, whose list replaces every alarm. A relative alarm needs a due date with a time: it is refused, with nothing written, when the reminder has no due date (the alarm would never fire) or a date-only one, because when Reminders fires a relative alarm on a day without a time has not been measured on a device (EventKit stores and reads it back; #333 step 0). On a recurring reminder EventKit is expected to move the alarm with each occurrence; that is not yet checked on a device (release gate). **What Reminders.app shows (#433):** in the 14 rows measured, the list row showed the earliest time-based alarm, relative or absolute, not the due time, so a reminder due 15:30 with `[15]` read 15:15 and with `[-15]` read 15:45. That is a fit to those rows, not a documented rule. The stored due date is unchanged (`list_reminders` reads 15:30). The one notification checked (#333: due 09:54, `[2]`) came early, and its banner showed the same time as the list row, 09:52, not the due time. No second banner was seen at the due time, but the first was still on screen, so one hidden behind it cannot be excluded. `alarms_note` says so when the earliest time-based alarm is not at the timed due time, on a call that passes `alarms_minutes_offsets`, `due_date` or `realign_to_due`. A call that touches none of them, such as a title change, gets no note, and neither does a date-only reminder, though #267 measured that the app goes on showing an absolute alarm's time there; so no note does not mean the list shows the due time. Measured list rows: `[15]`, `[60]`, `[2]`, `[15, 0]`, `[0]`, `[-15]`, absolute alarms at or before the due time, and `[15]` with an absolute alarm at the due time. Every other shape is inferred from them, for example `[60, 15]`, `[15, -15]`, `[-15, -60]`, `[1440]`, an absolute alarm after the due time, `[-15]` with an absolute alarm at the due time (no note), and `[15]` or `[0]` with an earlier one (note). They cannot decide `[0, -15]`: it gets no note for now, and release gate step 8 looks at it. The rows that showed the due time have no alarm before it, and an extra alarm at the due time did not bring it back (`[15]` with one read 15:15); firing was not checked on those 14 rows. An Early Reminder set in Reminders.app is different: the one made by hand read back with one absolute alarm at the due time and no alarm before it, so this server cannot write it. Keeping `alarms_minutes_offsets` is a default and can be revisited. The 14 rows were list rows of one iCloud list; the `[60]` and `[2]` rows came from an earlier disposable list (#333). Not checked: the detail panel, other devices, offsets that cross into another day (`[1440]`), when a `[-15]` alarm notifies, a past due date, a completed reminder, and whether `update_reminder` keeps an Early Reminder set in the app. The response lists the relative alarms read back as `alarms_minutes_offsets` (minutes before), with `alarms_differ` and `alarms_note` when they are not the ones asked for (when the display note applies too, the note says both). On a call with `alarms_minutes_offsets` (`create_reminder`, a batch row, `update_reminder`), if the reminder cannot be re-read after the save, or a create's `store_differs` lists `alarm count`, the response leaves `alarms_minutes_offsets` out and sets `alarms_read_back: false` with `alarms_read_back_note`. An `update_reminder` without `alarms_minutes_offsets` that changes the due date (`due_date` or `clear_due_date`) and leaves the saved reminder date-only or without a due date leaves its relative alarms in place and adds `alarms_note`: how many are left, that without a due date they never fire or that on a date-only reminder their firing has not been measured, and that `alarms_minutes_offsets: []` removes them (after `clear_due_date` the count is taken from the saved object, not re-read; a `due_date` whose re-read failed gets no such note, and `date_sync.aligned` is `false`); a skipped duplicate create gets `alarms_applied: false`. Undo of the update restores the previous alarms, location alarm included. Tested in memory: the restore, and the #236 guard comparing alarms by value (it names `alarms` when one changed elsewhere); what a synced store reads back is pending the release gate.

**Rows of `create_reminders_batch` are checked (#441):** a row with any key other than `title`, `notes`, `due_date`, `priority`, `calendar_name`, `calendar_source`, `tags` and `alarms_minutes_offsets` fails, with nothing written for it, and the other rows go on. Such a key used to be ignored, so `recurrence` on a row made a reminder that does not repeat. `recurrence` and `location_trigger` need `create_reminder`.

**Date-only reminders (#267):** a `due_date` given as a bare date (`2026-10-18`) to `create_reminder`, `create_reminders_batch` or `update_reminder` makes a date-only reminder, a date with no time, as Reminders.app makes one; read back, its `due.time` is `null`. On `update_reminder` the start date is set to that day, also one set apart from the due date, and absolute-date alarms are removed, because Reminders.app displays the earliest one and would go on showing its time (checked on device); relative and location alarms are kept, and `date_sync.absolute_alarms_removed` counts what went. Giving a timed reminder its own date removes the time. A due date with a time works as before. A bare-date `create_reminder` (and each created row of `create_reminders_batch`) reads the saved reminder back and returns `date_sync`, as `update_reminder` does: `date_sync.aligned` is `false` when the due came back with a time, came back missing, or the reminder could not be re-read (#301). A written due that reads back missing also gives `aligned: false` on `update_reminder`, where `aligned` used to be left out. In `list_reminders`, a date-only reminder is overdue only once its day has ended in the host time zone, and in `list_reminders` and `search_reminders` its `due_date` / `due_date_local` read as 00:00 of that day in the host time zone (#297).

**A reminder's own time zone (#241):** `list_reminders` and `search_reminders` report it as `item_timezone`, a time zone identifier (usually IANA), or `null` when the reminder stores no time zone: a floating timed reminder, a date-only reminder, or one without a due date (a floating timed reminder is `item_timezone` null with `due.time` set). The per-reminder `timezone` is the host time zone, the zone of the `*_local` strings, not the reminder's.

</details>

<details>
<summary><b>Advanced Features (10)</b> ✨ New in v0.3.0+</summary>

| Tool | Description |
|------|-------------|
| `search_events` | Search events by keyword(s) with AND/OR matching |
| `list_events_quick` | Quick shortcuts: `today`, `tomorrow`, `this_week`, `next_7_days`, etc. |
| `create_events_batch` | Create multiple events at once (with per-event timezone) |
| `check_conflicts` | Check for overlapping events in a time range |
| `copy_event` | Copy an event to another calendar; `delete_original` moves it like `move_events_batch` (recurring events refused) |
| `move_events_batch` | Move events to another calendar in place, keeping recurrence and attendees; `span` / `occurrence_dates` for recurring events (#226) |
| `delete_events_batch` | Delete events by IDs or date range, with dry-run preview (v1.0.0) |
| `find_duplicate_events` | Find duplicate events across calendars (v0.5.0) |
| `create_reminders_batch` | Create multiple reminders at once (v0.9.0); a row may carry `store_differs` and `note`, as `create_reminder` does (#261); a row whose save failed and could not be checked is kept and its error says how to check before creating it again (#289) |
| `delete_reminders_batch` | Delete multiple reminders at once (v0.9.0); one `undo` recreates them (#243) |

**Moving events (#226):** a move reassigns the event's calendar, so recurrence, attendees and every other field are kept. The identifier stays the same within an account and changes across accounts (each result reports `id_changed` and `new_event_id`). For a recurring event, `span: this` (default) moves only the occurrence named in `occurrence_dates`, which becomes a one-off; `span: all` moves the whole series; a recurring event without a date is refused. If an in-place move fails, the event is copied and the original removed, unless it has recurrence or attendees. Each result reports `method` (`in_place` / `copied` / `split` / `unchanged`) and any `not_carried_over` fields.

**Identifier after an update (#268):** `update_event` and `update_reminder` answer with the identifier the item has after the save. It changes in three cases only: a `calendar_name` in another account (the event part follows the #226 device finding; an edit of one occurrence with a calendar of another account is refused, since it would move the whole series), `update_event` with `span: "future"` from a later occurrence (the new series' identifier, also through the identifier of an occurrence edited on its own), and span `all` or `future` with the identifier of an occurrence edited on its own that is the first occurrence left after the first was deleted (what remains gets a new identifier). `id_changed` says whether it differs from the identifier you passed, and `previous_id`, present only when it changed, repeats that identifier. An edit of one occurrence (`occurrence_date`, span `this`) answers the series' identifier as `id` and adds `occurrence_id`, the identifier of that occurrence alone.

**Writes through an occurrence's own identifier (#416):** an occurrence edited on its own has its own identifier (on iCloud, the series identifier followed by `/RID=` and a number). What a span does through it depends on where the occurrence is:

- Span `this` edits or deletes that occurrence, with exceptions tracked in #426: a new `calendar_name` in the same account moves the whole series (in another account the call is refused), `clear_recurrence` answers `updated` and changes nothing, and `recurrence` fails with an EventKit error.
- `update_event` with span `all` or `future` can write only `title`, `notes`, `location` and `recurrence` through it. Any other field is refused and nothing is written, even a field that changes nothing, such as `all_day: false`. For the rest, use span `this` or the series' identifier, as below.
- `update_event` span `future` updates from that occurrence on. From a later occurrence it ends the series there and starts a new one, which can resend invitations; `id_changed` reports it.
- `update_event` span `all` updates every occurrence when it is the first one left. With an earlier occurrence left it would split the series, so it is refused and writes nothing: use the `id` that `list_events` shows for the occurrence that comes first in the series, by its original date. A series whose first occurrence was deleted has no whole-series update unless its first occurrence left was edited on its own (#326); what remains is span `future` from a later occurrence, or span `this` on each.
- A value the occurrence already holds is refused with both spans: it reaches no other occurrence, though the call would answer `updated` (measured). Leave the field out, or use the series' identifier.
- A write that starts a new series (span `future` from a later occurrence, or either span from the first one left after the first was deleted) is refused while the occurrence holds its own location, alarms, time zone, all-day flag, availability or coordinates, because the new series took its location and alarms (measured). Writing `location` replaces a location given as text.
- `days_of_week` in a new `recurrence` is checked against the occurrence's original day, so from an occurrence moved to another weekday a rule on the day it shows is refused. With span `future`, `occurrence_count` can give fewer occurrences than it says, through the series' identifier too (count 6 from the third occurrence gave 4, #443).
- The series' identifier is the `id` that `list_events` shows for an occurrence that was not edited on its own. With span `all` it took the other fields, with an edited occurrence in the series. Occurrences edited on their own keep what was edited, so use span `this` on them afterwards. `clear_recurrence` there leaves one event at the series' first date, without the edited occurrences. `all_day` there brings an edited occurrence's original slot back as an extra occurrence (#442), `clear_timezone` drops the last occurrence of a series with a count (#455), and a calendar of another account was not run. For a calendar of the same account, `move_events_batch` span `all` moves the whole series. For span `future`, use span `this` on this occurrence, then that `id` with the next occurrence's `occurrence_date` and span `future`; that leaves out `all_day`, `clear_recurrence` and `calendar_name`, which do not stay within the later occurrences (#451), and `clear_timezone`, which was not run.
- **Known limit (#428):** the series' identifier is refused when the first occurrence was edited on its own and still starts at its original time, or was deleted and the first one left was edited on its own. That shape has no tested way yet for what the series' identifier does above. The first occurrence's own `id` with span `all` still takes a new `title`, `notes`, `location` or `recurrence`, unless it holds values of its own that the call does not replace.
- **Calls these refusals took away (#416):** `start_time` alone with span `all` or `future` from an occurrence moved by a time, keeping the series' length, did what it says. It is refused with the other date fields, because the check cannot tell that shape from one that spreads. It can come back when #428 gives these shapes a way. Dates on the only occurrence left are refused too; span `this` does the same there.
- With span `this` or `future`, `occurrence_date` must be that occurrence's day, or the call is refused: it was ignored, and the write started at the occurrence the identifier names.
- `delete_event` span `future` deletes that occurrence and the later ones, so from the first occurrence it deletes the whole series.
- `delete_event` span `all` deletes that occurrence only, so it is refused and deletes nothing while another occurrence remains. To delete the whole series, use the `id` of the occurrence that comes first in the series: with span `all` when it has no `/RID=` part, with span `future` when it has one (that delete cannot be undone). A series that may reach past the scan, about five years, counts as having other occurrences. `delete_events_batch` by `event_ids` refuses that row, in the dry run too, and goes on with the others; occurrences named in the same call do not count as remaining, and with span `all` their rows run first, in the dry run too. By date range the row is not refused, so an edited occurrence that is the only listed occurrence of its series is deleted alone and the rest of the series stays (#427).
- `move_events_batch` span `all` moved the whole series and kept the identifier, within one iCloud account; across accounts was not measured.

This was measured on iCloud. The bare series identifier is itself refused when the series' first occurrence was edited on its own and still starts at its original time (#428), which is why the whole-series update and delete above go through the occurrence that comes first. On Google, #320 measured `/RID=` and `isDetached` as reliable, but these refusals did not run there. A source with no `/RID=`, which Exchange may be (not measured), cannot list the rest of the series from the identifier, so span `all`, and `update_event` span `future`, are refused there, also for a single event it wrongly reports as an edited occurrence; use span `this`. On iCloud an occurrence past the scan, in a series that reaches more than about five years from its start, is refused the same way, and the series' identifier takes the whole-series update and delete (measured on a series started about seven years ago).

**All-day dates with an offset (#372):** all-day dates are whole days read in this Mac's time zone. A `start_time` or `end_time` written with another offset is converted first and can land on another day (`2027-04-11T23:59:59+07:00` on a `+08:00` Mac is 04-12, so the event gets one more day). The event is still saved that way; `create_event`, each `create_events_batch` result and `update_event` (when the event is all-day after the call, for the dates it gave) add a `warnings` list whose entries name the `field`, its day in the written offset (`written_day`), the day in this Mac's zone the request's dates are written with (`host_day`; a skipped duplicate writes nothing, and its message says the existing event was not changed) and a `message`. The comparison is on the days, so an offset whose day agrees, or a value without an offset, gives no warning. Send all-day dates without an offset.

</details>

<details>
<summary><b>Undo/Redo (3)</b> ✨ New in v1.4.0</summary>

| Tool | Description |
|------|-------------|
| `undo` | Undo the most recent calendar/reminder operation |
| `redo` | Redo the last undone operation. Only completions are written again; for a create, delete, update or move, redo writes nothing, answers `success: false` with the tool to use, and drops that entry from the redo history (#247). Not replaying those writes is the design (#295): the tool that made them repeats them |
| `undo_history` | List undoable operations with timestamps |

**Undo does not overwrite a change a person made since (#236):** an undo of a create, update, move or completion first re-reads the event or reminder and checks that nothing the undo would overwrite or delete was changed since that operation (for a move, the calendar; for a recurring event created here, also occurrences edited on their own, looked for up to four years from the first occurrence; an occurrence counts when it differs from the series in any compared field, alarms, time zone, place and availability included, and one back at the series' values does not; availability counts only when both the occurrence and the series report one, so on a store that reports it on one side only an occurrence's own availability is not seen). A field already changed back to the value the undo writes does not count. Two changes a calendar app or server makes on its own are not treated as edits, so they never block an undo and an update-undo overwrites them: an alarm sound, and coordinates added to a place that had none. If something was changed, nothing is written, the error names the changed fields, and the entry stays in `undo_history`; whoever made the change should decide whether to change it back and undo again, or to give up that undo with `undo` + `discard_id`. Three create-undo refusals leave only the choice whether to discard: occurrences edited on their own, which cannot be put back into the series; a series whose occurrences could not be checked (`unchecked_occurrences`), which cannot be checked later either; and a series whose rule was shortened (`recurrence`; an update or delete of an occurrence and the following ones does this), whose cut-off part cannot be put back. Redo of a completion makes the same check against the state the undo left. An `update_event` that touched a recurring event (one occurrence, span "future" or "all", or rules added or removed) cannot be undone: `undo` on it writes nothing, says to revert the change in Calendar if it should be reverted, and drops that entry so earlier ones stay undoable (#262: such an undo used to delete the rest of a series). The undo of an earlier update or move of a one-off event is refused the same way if the event repeats or is an edited occurrence by the time of the undo (a move of an already edited occurrence included), so update-undo and one-off move-undo never write to a recurring event (a series move-undo still moves the whole series back, by design). A safe restore for recurring updates is #263.

**A series whose first occurrence was deleted (#326, #335):** its id still works. The tools reach it through its earliest remaining occurrence, looked for from a day before the series' first start up to 1460 days on, in the series' calendar: a move, a copy, a delete and an update of a single occurrence (`occurrence_date`, span `this`) work, and undo of those moves and deletes restores the series. A whole-series update, or a delete or update from a date on, is refused with an explanation when an occurrence edited on its own comes before the remaining ones. If every remaining occurrence starts more than 1460 days after the series' first start, none is found and the id answers `Event not found`: that cannot be told apart from a series with nothing left without a wider search, so change such a series in Calendar.

**Undo of deleted occurrences and availability (#244, #245):** undo of a `delete_event` that removed one occurrence of a recurring event (span "this") brings that occurrence back as a one-off event at its time, not into its series (EventKit cannot put it back), and an absolute-date alarm of the series becomes an alarm at its start (the undo text names it, once for a batch). Undo of a span "future" delete recreates the series only when the delete started at the series' first occurrence and removed all of it; otherwise (part of the series is left, the delete started at the last occurrence, or the id named an edited occurrence) it writes nothing, says to restore the occurrences in Calendar, and drops that entry. A `delete_events_batch` holding such a delete is refused before any of its events is restored. Undo of a whole-series delete (that span "future" case, or span "all") recreates the series from its rules and then restores its exceptions inside the scan window (from one day before the first occurrence to the end of the rule, at most four years): an occurrence deleted on its own earlier stays deleted, and one edited on its own comes back as a separate one-off event that no longer belongs to the series (#285); the undo text says how many of each. Occurrences are listed a year beyond each window edge and judged by their rule slot, so an edited occurrence moved out of the window still comes back as a one-off (one moved more than a year past it is not restored and its slot counts as deleted; if the record does not match the recreated series, no exception is applied and the text says so). The series' first occurrence is never removed: if it was edited or deleted on its own it is kept from the rule and the text says so. Exceptions outside that window, and those of a series that could not be listed when it was deleted, come back from the rules alone, which the text also says. Undoing the earlier delete of an occurrence that the restored series already holds writes nothing and says so. `undo_history` lists such a record as `Deleted event: <title> (undo recreates the series and its exceptions within the checked window: …)` and a `delete_events_batch` record holding one as `Batch (<N> operations; undo recreates <K> series and their exceptions within the checked window: …)` (a batch whose undo is refused says `undo not available` instead). Checked on iCloud with `delete_event` (span "future") and `delete_events_batch` (span "all"). Delete-undo now keeps an event's availability (free, busy…) where its calendar supports the value, and the create and update checks above compare it.

**Batch deletes undo as one entry (#185, #243, #248):** `delete_events_batch`, a series delete, `delete_reminders_batch` and `cleanup_completed_reminders` each record one undo entry holding the items the call actually removed, and it becomes the newest entry. One `undo` recreates them one save at a time within that single call (a cleanup holds up to its `limit`, 1000 by default, or every `reminder_ids` entry), each under a new identifier and with what the undo snapshot records; a reminder's subtasks are not recorded. Before the first write, the calendar or list each item goes back into is checked, by its recorded identifier as the restore looks it up (a same-named list in another account does not count); if one is missing or read-only (read again after a refresh is requested), nothing is written, the entry stays whole, and the error says how many items have their calendar or list in place; giving up with `discard_id` drops them all (a partial restore is #287). If a save still fails, the entry keeps only the items not yet restored, under the same id, with the failing one moved to run last, so the next `undo` restores the others first, unless the failing one's calendar or list is by then missing or read-only, which the check above refuses. Each such call clears the redo history, and only the newest 50 undo entries are kept.

</details>

---

## Installation

The quick paths live at the [top of this README](#install). This is the full reference — manual config, source builds, permission edge cases, in-place upgrades, and CLI mode.

### Requirements

- macOS 14.0+ (Sonoma or later — required since v1.11.0 for the full TCC permission API)
- Xcode Command Line Tools (only if building from source)

### Claude Desktop

**One-click (recommended):** download the latest `che-ical-mcp-<version>.mcpb` from [Releases](https://github.com/PsychQuant/che-ical-mcp/releases), double-click, and restart Claude Desktop.

**Manual config:** download the binary, then point `claude_desktop_config.json` at it.

```bash
curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o /usr/local/bin/che-ical-mcp
chmod +x /usr/local/bin/che-ical-mcp
```

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude Desktop:

```json
{
  "mcpServers": {
    "che-ical-mcp": {
      "command": "/usr/local/bin/che-ical-mcp"
    }
  }
}
```

### Claude Code — plugin (recommended)

```bash
claude plugin marketplace add PsychQuant/che-ical-mcp
claude plugin install che-ical-mcp@che-ical-mcp
```

- Inside Claude Code, the slash equivalents `/plugin marketplace add PsychQuant/che-ical-mcp` and `/plugin install che-ical-mcp@che-ical-mcp` work the same way.
- Add the marketplace through its **Git repo** (`owner/repo`), not a raw `marketplace.json` URL — the plugin `source` is a same-repo relative path (`./plugin`) that only resolves when added via Git.
- Also bundled in the `psychquant-claude-plugins` aggregator (`claude plugin install che-ical-mcp@psychquant-claude-plugins`); both serve the same versioned binary.
- The wrapper auto-downloads the binary to `~/bin/CheICalMCP` on first use if it isn't already there.

### Claude Code — standalone MCP

```bash
mkdir -p ~/bin

# If upgrading, remove the old binary first. On macOS 26 the kernel can kill a
# fresh binary that inherits a stale code-signature cache from the old inode —
# one a running MCP process may still be holding open.
rm -f ~/bin/CheICalMCP

curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP
chmod +x ~/bin/CheICalMCP

# --scope user: available in all projects  ·  --transport stdio: local stdin/stdout
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **💡 Tip:** Keep the binary in a local directory like `~/bin/`. Cloud-synced folders (Dropbox, iCloud, OneDrive) can trigger MCP connection timeouts when sync touches the file.

### Build from Source (optional)

```bash
git clone https://github.com/PsychQuant/che-ical-mcp.git
cd che-ical-mcp
make release && make install
claude mcp add --scope user --transport stdio che-ical-mcp -- ~/bin/CheICalMCP
```

> **⚠️ Swift 6 / Xcode 18 users:** Don't run `swift build` directly — the upstream MCP SDK has a concurrency error ([swift-sdk#214](https://github.com/modelcontextprotocol/swift-sdk/issues/214)). The Makefile auto-detects this and falls back to Swift 5 language mode.

### Grant Permissions

On first use, macOS will prompt for **Calendar** and **Reminders** access. Click **Allow** for both.

> **⚠️ macOS Sequoia (15.x) Note:** The permission dialog is attributed to the **parent application** that launched the MCP server, not the binary itself. This means:
>
> | Environment | Permission Attributed To |
> |-------------|------------------------|
> | Claude Desktop | Claude Desktop.app ✅ (works automatically) |
> | Claude Code in **Terminal.app** | Terminal.app ✅ (works automatically) |
> | Claude Code in **VS Code** | VS Code ❌ (may not show dialog) |
> | Claude Code in **iTerm2** | iTerm2 ✅ (works automatically) |
>
> **If the permission dialog doesn't appear** (common with VS Code), you need to add `NSCalendarsFullAccessUsageDescription` to VS Code's Info.plist:
>
> ```bash
> # Add calendar usage description to VS Code
> /usr/libexec/PlistBuddy -c "Add :NSCalendarsFullAccessUsageDescription string 'VS Code needs calendar access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
> /usr/libexec/PlistBuddy -c "Add :NSRemindersFullAccessUsageDescription string 'VS Code needs reminders access for MCP extensions.'" \
>   "/Applications/Visual Studio Code.app/Contents/Info.plist"
>
> # Re-sign VS Code (required after Info.plist modification)
> codesign -s - -f --deep "/Applications/Visual Studio Code.app"
>
> # Restart VS Code, then the permission dialog will appear
> ```
>
> **Note:** This modification will be overwritten when VS Code updates. You'll need to re-apply it after each VS Code update.

### Upgrading an existing install

The plugin wrapper auto-downloads on **fresh** installs but does not replace an existing binary. To upgrade in place:

```bash
~/bin/CheICalMCP --self-update
```

This queries GitHub Releases for the latest tag, downloads the new binary, checks it against the published SHA-256, the maintainer's Developer ID signature and Apple notarization, and only then atomically replaces the current one (any failed check leaves your install untouched). If it is running as an MCP server, restart your MCP host (Claude Desktop / Claude Code) afterward to pick up the new version. Manual fallback: `rm -f ~/bin/CheICalMCP && curl -L https://github.com/PsychQuant/che-ical-mcp/releases/latest/download/CheICalMCP -o ~/bin/CheICalMCP && chmod +x ~/bin/CheICalMCP`.

### CLI Mode (no MCP server)

All 29 tools can be invoked directly from the command line, no MCP server required:

```bash
# Flag-based: --key value pairs
CheICalMCP --cli list_events --start_date 2026-03-29 --end_date 2026-03-30

# JSON via stdin
echo '{"tool":"list_calendars","arguments":{}}' | CheICalMCP --cli

# From Claude Code via shell
claude -p "Run: ~/bin/CheICalMCP --cli list_events_quick --range today"
```

Handy for launchd jobs, shell scripts, CI pipelines, and agents that prefer a subprocess over the MCP protocol. TCC permissions still apply — run `CheICalMCP --setup` first if needed: from v1.23.0 a context without a Calendar and Reminders grant of its own uses the grant `--setup` creates ([#343](https://github.com/PsychQuant/che-ical-mcp/issues/343)).

---

## v1.0.0 Features

### Flexible Date Parsing

All date parameters now accept 4 formats:

| Format | Example | Interpretation |
|--------|---------|----------------|
| Full ISO8601 | `"2026-02-06T14:00:00+08:00"` | Exact date and time (offset preserved) |
| Without timezone | `"2026-02-06T14:00:00"` | Uses event `timezone` if provided, otherwise system timezone |
| Date only | `"2026-02-06"` | Midnight in event `timezone` or system timezone; for a reminder `due_date`, a date-only reminder with no time (#267, see "Date-only reminders") |
| Time only | `"14:00"` | Today at that time |

### Per-Event Timezone (v1.5.0)

Set the display timezone for individual events — essential for multi-timezone travel itineraries.

```
"Create a flight departure at 09:14 Berlin time"
→ create_event(title: "Flight LH123", start_time: "2026-04-08T09:14:00", timezone: "Europe/Berlin", ...)

"Update the hotel check-in to Dubai time"
→ update_event(event_id: "...", timezone: "Asia/Dubai")

"Remove the custom timezone from an event"
→ update_event(event_id: "...", clear_timezone: true)
```

- **`timezone`** parameter accepts IANA identifiers (e.g., `Europe/Berlin`, `America/New_York`, `Asia/Taipei`)
- When `timezone` is provided, naive datetimes (without offset) are interpreted in that timezone
  - except `update_event`'s `occurrence_date`, which names an occurrence of the event as it is now: without an offset it is read in the event's current time zone, as on `delete_event` and `move_events_batch` (#383, #270)
  - with an offset it is used as given, and its day is taken in the event's current time zone; the response's `occurrence_start` gives the start of the occurrence it matched
- Event output includes the event's own timezone in `timezone` field and formats `start_date_local`/`end_date_local` accordingly
- Event output also reports `item_timezone` (#386): the event's own time zone identifier (usually IANA), or `null` when the event stores no time zone (a floating event; all-day events are floating). `timezone` falls back to the host time zone for those, so `item_timezone` is what tells them apart from an event stored in the host zone. With `display_timezone`, the `*_local` strings are in that zone; neither field changes
- Available on `create_event`, `update_event`, and `create_events_batch`
- Undo/redo preserves per-event timezone

### Alarms (Read)

Event responses list the event's time-based alarms as `alarms` (#240), in the shape the reminder read tools use (#231), so a caller can check what `alarms_minutes_offsets` wrote and see absolute-date alarms. Available in `list_events`, `search_events` and `list_events_quick` (all three outside `detail_level: summary`; `fields: ["alarms"]` selects it), and in `check_conflicts`.

- `{"kind": "relative", "minutes_before": 15}`: measured from the start, positive = before, negative = after (the sense of `alarms_minutes_offsets`)
- `{"kind": "absolute", "absolute_date": "...Z", "absolute_date_local": "..."}`: `absolute_date_local` is in the zone of the other `*_local` strings (`display_timezone` when given)
- Absolute alarms come first by date, then relative alarms earliest first; `[]` when none. Location alarms are not listed. An occurrence reports the series' alarms unless it was edited on its own (then its own), as EventKit returns them

### Attendees & Organizer (Read-Only)

Event responses include participant information when available. These fields are **read-only** due to EventKit limitations — they cannot be set or modified through the MCP.

Available in: `list_events`, `search_events`, `list_events_quick`, `check_conflicts`

**`attendees`** (array, optional) — Present when the event has participants. Each attendee object contains:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string or null | Display name, null if not in Address Book |
| `email` | string | Email address extracted from participant URL |
| `role` | string | One of: `unknown`, `required`, `optional`, `chair`, `non_participant` |
| `status` | string | One of: `unknown`, `pending`, `accepted`, `declined`, `tentative`, `delegated`, `completed`, `in_process` |
| `type` | string | One of: `unknown`, `person`, `room`, `resource`, `group` |
| `is_current_user` | boolean | Whether this participant is the current user |

**`organizer`** (object, optional) — Present when the event has an organizer. Contains:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string or null | Display name |
| `email` | string | Email address |
| `is_current_user` | boolean | Whether the organizer is the current user |

> **Note:** Both fields are omitted when the event has no participants or organizer (e.g., local calendar events created without invitees).

### Fuzzy Calendar Matching

Calendar names are now matched **case-insensitively**. If not found, the error says `Calendar not found: <name>`, or `Calendar '<name>' not found in source '<source>'` with `calendar_source`; `list_calendars` shows the names.

### Enhanced list/delete Tools

- **`list_events`**: `filter` (all/past/future/all_day), `sort` (asc/desc), `limit`
- **`list_reminders`**: `filter` (all/incomplete/completed/overdue), `sort` (due_date/creation_date/priority/title), `limit`
- **`delete_events_batch`**: date range mode (`before_date`/`after_date`) + `dry_run` preview

**`find_duplicate_events` checks `calendar_names` (#437):** names are matched as the other tools match them: the exact title, or ignoring case when no title matches exactly. A name that matches no calendar, fewer than two calendars, or a value that is not an array of strings is refused and nothing is returned, because it only compares different calendars. With no names it compares every calendar, so a host with fewer than two is refused too. A name two accounts share reads both; this tool has no `calendar_source`, and `calendar_name`, `calendar_source` and `calendars` are refused rather than ignored. `calendars_checked` lists the calendars read, with the account where two share a title (`Work (iCloud)`, which is a label: pass titles from `list_calendars`); with no names that is every calendar, not `all calendars`. Each side of a pair gives `calendar` and `calendar_source`, which tells two accounts apart; two calendars of one title in one account read the same on both sides. Two accounts sharing a name have been tested in unit tests only, and the read with no names has not been run on a device.

**Reads over a wide range (#332):** a range of at most 1462 days is read in full, whatever it holds; four calendar years across a clock change are 1461 days and an hour, so they count as narrow. Over a longer range, `list_events`, `search_events`, `check_conflicts`, `find_duplicate_events` and `delete_events_batch` by date range stop with an error, returning nothing and deleting nothing, once the read has passed about 200,000 occurrences. All calendars read are counted together, and on `search_events` the count comes before keywords are matched. This is a safety valve, not an everyday limit: over 100 years it is about 2,000 occurrences a year (between five and six open-ended daily series, or about 40 weekly ones), and over the 400-year ceiling about 500 a year. The count is checked after each 1460-day part, which EventKit reads whole, so a read can pass it by that part's size. `limit` does not lift it. Narrow the range, or name one calendar; on `find_duplicate_events` naming fewer calendars also reads less, but keep at least two, because it only compares different calendars; on `check_conflicts` other calendars are then not checked; on `delete_events_batch` give both `after_date` and `before_date`, at most 1460 days apart.

Over a range longer than 1462 days, without `limit` at most 500 events are returned, with `default_limit` (`metadata.default_limit` on `list_events`). `search_events` with only `start_date` or only `end_date` keeps two years from today on the other side, so such a range is often this long. `limit` takes up to 10000; more rows than that need a narrower range. On any range, `event_count` is still the total and `truncated: true` appears when fewer events are returned than `event_count`, whether the default or your `limit` cut them. What a cut keeps differs by tool: `list_events` keeps the first in its `sort`; `search_events`, which has no sort, keeps the events closest to today, returns them sorted by start and says so in `truncation_note`. With nothing cut, `search_events` returns events in the order they were read, which is not date order.

> **Breaking Change**: `list_events` and `list_reminders` now return `{events/reminders: [...], metadata: {...}}` instead of a plain array.

---

## Usage Examples

### Calendar Management

```
"List all my calendars"
"What's on my schedule next week?"
"Create a meeting tomorrow at 2 PM titled 'Team Sync'"
"Add a dentist appointment on Friday at 10 AM with location '123 Main St'"
"Delete the meeting called 'Cancelled Meeting'"
```

### Reminder Management

```
"List my incomplete reminders"
"Show all reminders in my Shopping list"
"Add a reminder: Buy milk"
"Create a reminder to call mom tomorrow at 5 PM"
"Mark 'Buy milk' as completed"
"Delete the reminder about groceries"
```

### Reminder Management (v1.5.0)

```
"Remove the due date from 'Buy groceries'"
→ update_reminder(reminder_id: "...", clear_due_date: true)
```

### Advanced Features (v0.3.0+)

```
"Search for events containing 'meeting'"
"Search for events with both 'project' AND 'review'"
"What do I have today?"
"Show me this week's schedule"
"Are there any conflicts if I schedule a meeting from 2-3 PM?"
"Create 3 weekly team meetings for the next 3 weeks"
"Copy the dentist appointment to my Work calendar"
"Move all events from 'Old Calendar' to 'New Calendar'"
"Delete all the cancelled events"
"Find duplicate events between 'IDOL' and 'Idol' calendars"
```

### DX Improvements (v1.0.0)

```
"Show my next 5 upcoming events"
→ list_events(start_date: "2026-02-06", end_date: "2026-12-31", filter: "future", sort: "asc", limit: 5)

"Show my overdue reminders"
→ list_reminders(filter: "overdue")

"Preview which events would be deleted from 'Old Calendar' before 2025"
→ delete_events_batch(calendar_name: "Old Calendar", before_date: "2025-01-01", dry_run: true)

"Create an event at 2 PM" (no need for full ISO8601!)
→ create_event(start_time: "14:00", end_time: "15:00", ...)
```

---

## Supported Calendar Sources

Works with any calendar synced to macOS Calendar app:

- iCloud Calendar
- Google Calendar
- Microsoft Outlook/Exchange
- CalDAV calendars
- Local calendars

### Same-Name Calendar Disambiguation (v0.6.0+)

If you have calendars with the same name from different sources (e.g., "Work" in both iCloud and Google), use the `calendar_source` parameter:

```
"Create an event in my iCloud Work calendar"
→ create_event(calendar_name: "Work", calendar_source: "iCloud", ...)

"Show events from my Google Work calendar"
→ list_events(calendar_name: "Work", calendar_source: "Google", ...)
```

If ambiguity is detected, the error says several calendars have that name and asks for `calendar_source`; `list_calendars` shows the sources.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Server disconnected | Rebuild with `make release && make install` |
| Permission denied | Grant Calendar/Reminders access in System Settings > Privacy & Security |
| Permission dialog never appears | See [Grant Permissions](#grant-permissions) for macOS Sequoia workaround |
| **Permission denied over SSH** | See [SSH Access](#ssh-access) below |
| **Permission denied under launchd** | See [launchd / Automation](#launchd--automation) below |
| **One service denied while every diagnostic reports green** | See [Silent permanent denial after upgrade](#silent-permanent-denial-after-upgrade-154) below |
| **Calendar/Reminders break again after every Claude Code update** | See [Claude Code updates rotate the host-side grant](#claude-code-updates-rotate-the-host-side-grant-170) below |
| Calendar not found | Ensure the calendar is visible in macOS Calendar app |
| Reminders not syncing | Check iCloud sync in System Settings |

### Silent permanent denial after upgrade (#154)

If one service (typically Calendar) returns `access denied` while the other works, **and** `--print-tcc-path` and System Settings report the permission as granted, you are likely hitting the [#154](https://github.com/PsychQuant/che-ical-mcp/issues/154) signature: a TCC row created by a pre-v1.7.1 (ad-hoc-signed) build is pinned to that old build's code hashes. The upgraded Developer ID binary can never match it, and on macOS 26.5+ the OS only allows the healing re-prompt when the binary carries the matching `com.apple.security.personal-information.*` entitlement.

As of **v1.14.0+ the startup banner surfaces this directly** — a `[drift] TCC.db <service> entry pins a code requirement this binary no longer satisfies` line ([#155](https://github.com/PsychQuant/che-ical-mcp/issues/155)) — when the Security-framework check can confirm the csreq mismatch. Before that, *every* status-API diagnostic (including the banner) reported green, which is exactly what made this class silent. If you hit the denial through Claude Desktop's `.mcpb` install, the denial message itself now names the real blocker and the working paths instead of the dead-end `--setup` ([#158](https://github.com/PsychQuant/che-ical-mcp/issues/158)).

**Fix**: upgrade to **v1.11.0 or later** (the binary now ships both entitlements), restart the host app (full `Cmd+Q` for Claude Desktop), and approve the permission dialog that appears on the first Calendar/Reminders access. Approving rewrites the TCC row keyed to the Developer ID requirement, so it survives all future upgrades. If you accidentally **deny** the dialog, re-enable the corresponding toggle in System Settings → Privacy & Security → Calendars or Reminders.

> ⚠️ **Erratum for the #108-era workaround**: `tccutil reset Calendar com.checheng.CheICalMCP` (or `Reminders`) does **not** work for a bare (non-bundled) binary — it fails with `OSStatus error -10814` (`kLSApplicationNotFoundErr`) because the binary has no LaunchServices registration.
>
> That covers both shipped builds: the Developer-ID `~/bin/CheICalMCP` and the `.mcpb` `server/CheICalMCP` are bare executables with an embedded Info.plist. The -10814 was seen with the #154-era builds; on 2026-11-04 `lsregister -dump` had no record for `com.checheng.CheICalMCP` on a Mac with the Developer-ID `~/bin/CheICalMCP` installed (the command itself was not re-run there, because a lookup that unexpectedly succeeded would reset the real grant). Since #357 no message, banner line or `--print-tcc-path` section prints it.
>
> Instead: Switch CheICalMCP on, or off and on, in System Settings → Privacy & Security → Calendar / Reminders ([#382](https://github.com/PsychQuant/che-ical-mcp/issues/382)).
>
> **Last resort**, only on CheICalMCP v1.11.0 or later: `tccutil reset Calendar` (or `tccutil reset Reminders`) without a bundle id clears that permission for **every app** on the Mac, and command-line tools or hosts recorded by version number may not ask again. The user decides and runs it; an agent must not. On a pre-entitlements binary (before v1.11.0) it leaves CheICalMCP permanently unable to re-prompt.

### Claude Code updates rotate the host-side grant (#170)

> **Changed in v1.22.0, and again in v1.23.0 ([#343](https://github.com/PsychQuant/che-ical-mcp/issues/343))**: From v1.23.0 the rule depends on the grant macOS checks for this binary, that of its responsible process (which is not always the process that starts it), and it is the same for every host: before any dispatch the binary reads that context's authorization status. If it already has full access to both Calendar and Reminders (Terminal, VS Code, a Claude Code version-number entry, any host), that grant is kept and nothing is re-exec'd. A host that a policy (a configuration profile or Screen Time) restricts for either service keeps its attribution too, because CheICalMCP's own grant is not what that policy covers ([#367](https://github.com/PsychQuant/che-ical-mcp/issues/367)). Otherwise, including a host with only one of the two or one the user denied, the binary re-execs in place as its own responsible process (`posix_spawn` + `POSIX_SPAWN_SETEXEC` + disclaim, the call Claude Desktop's `disclaimer` makes; pid and stdio unchanged), so macOS checks the `CheICalMCP` grant, the one `--setup` creates. This covers the MCP server, `--cli`, `--print-tcc-path` and `--setup`; `--setup` re-execs under any host, because it is the action that creates CheICalMCP's own grant. (v1.22.0 re-exec'd by default only when Claude Code was the responsible process, and under any host when `CHE_ICAL_MCP_FORCE_DISCLAIM` was set.) A rotated Claude Code path has no grant, so after an update the binary re-execs and uses CheICalMCP's own grant instead of going stale.
>
> **Seeing a re-exec (#361)**: every re-exec writes one line to stderr first, with the host and, except for `--setup`, which reads no status, its Calendar and Reminders status. That line is a server's own record. `--print-tcc-path` reports only its own start, in the context it runs in: when it re-executed, it adds `CHE_ICAL_MCP_DISCLAIMED says this process re-executed at start (...)`, with the reason, the two statuses and the kind of host, also when the re-exec had no effect. A parent process could set that variable with no re-exec at all, so the line is marked as not verified: only values this binary can write are accepted, and anything else reads as not known.
>
> **Migration from v1.22.0**: under a host other than Claude Code, a context without full access used to keep its own (missing or partial) grant and now uses CheICalMCP's; if that is not granted yet, run `~/bin/CheICalMCP --setup` once in the foreground and restart the client. Under Claude Code, v1.22.0 re-exec'd whatever the status: a version-number entry with full access to both services is now kept, and one without still uses CheICalMCP's grant. A host other than Claude Code with full access is unaffected.
>
> **Trade-off**: once CheICalMCP's own grant is allowed, any process that runs this binary from a context without full access of its own (another app, a script, a launchd or cron job, a Claude Code session, `--cli` included, and a host the user denied Calendar or Reminders to; not a host a policy restricts, which keeps its attribution, [#367](https://github.com/PsychQuant/che-ical-mcp/issues/367)) reads Calendar and Reminders under that grant without a separate consent. v1.22.0 did this by default only under Claude Code, and for any caller that set `CHE_ICAL_MCP_FORCE_DISCLAIM`, without a notice. `CHE_ICAL_MCP_NO_DISCLAIM=1` keeps host attribution for the environment that sets it; it does not stop another process from running the binary without it. `CHE_ICAL_MCP_FORCE_DISCLAIM=1` re-execs even under a host with a grant of its own, but not under a host a policy restricts (the opt-out wins over it; a re-exec prints one stderr line (#361)).
>
> **Not verified**: CI does not cover reading the calendar through the re-exec. On 2026-10-28 v1.22.0 read the calendar through a forced re-exec with `--cli`; a re-exec that a Claude Code worker launched through `ClaudeCode.app` triggers by itself, and server mode after the re-exec, have not been observed yet.
>
> The wording of `--print-tcc-path`, the banner, the access-denied message and `--setup`'s WARNING line recognises Claude Code's native install and the build inside Claude Desktop, both under your home directory, with or without its symlinks resolved; another install (Homebrew, npm) is named by its app or executable, and the re-exec applies all the same (#356).
>
> The rest of this section applies to v1.21.0 and earlier, to a host that has full access of its own (its grant is kept), and with `CHE_ICAL_MCP_NO_DISCLAIM=1`.

Under a Claude Code **native install**, the real executable lives at a **versioned path** (`~/.local/share/claude/versions/<version>`; `~/.local/bin/claude` is just a symlink), and macOS TCC keys the host-side Calendar/Reminders grant to that path. **Every Claude Code auto-update rotates the path and silently invalidates the grant** — the classic symptom is "worked yesterday, broken right after an update", with System Settings accumulating stale bare-version-number entries (`2.1.202`, `2.1.203`, …).

**Fix**: trigger any calendar tool call from Claude Code so macOS re-prompts (or re-creates the entry), then toggle the **newest** version-number entry ON in System Settings → Privacy & Security → Calendars / Reminders. Full checklist: the `troubleshoot-tcc` skill (`/che-ical-mcp:check-tcc`). Root cause is upstream (tracked in [#170](https://github.com/PsychQuant/che-ical-mcp/issues/170) — Claude Code would need a stable TCC identity); this repo can only detect and document it.

### SSH Access

> **Since v1.23.0 ([#343](https://github.com/PsychQuant/che-ical-mcp/issues/343))**: an SSH session's context usually has no grant of its own, so by [the rule above](#claude-code-updates-rotate-the-host-side-grant-170) the binary re-execs onto CheICalMCP's own grant, as under any other host. Whether macOS honours that grant over SSH has not been measured ([#382](https://github.com/PsychQuant/che-ical-mcp/issues/382)), so the steps below and the SSH error messages have not been changed for it: they were written before the re-exec, Workaround A is the first thing to try, and Workaround B may not be needed, or may not help, after a re-exec.

macOS TCC (Transparency, Consent, and Control) grants privacy permissions **per-application**. SSH sessions run under `sshd`, which is a different security context — so permissions granted to Terminal or Claude Code locally do **not** carry over to SSH.

**Workaround A — Run locally first (recommended):**
1. Run `CheICalMCP` once on the target Mac **locally** (not over SSH)
2. Grant Calendar and Reminders access when the TCC dialog appears
3. SSH sessions should then inherit the grant for the `CheICalMCP` binary

**Workaround B — Grant Full Disk Access to sshd:**
1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**, press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>, type `/usr/sbin/sshd`, and add it
3. Restart the SSH session

> ⚠️ Workaround B grants `sshd` broad file access — only use this on machines you fully control.

### launchd / Automation

When running CheICalMCP from `launchd`, cron, or other non-interactive automation, macOS TCC cannot show permission dialogs. Use `--setup` to pre-grant permissions:

```bash
# Step 1: Run once from Terminal (triggers TCC permission dialog)
CheICalMCP --setup

# Step 2: Grant Calendar & Reminders access in the dialog that appears
# Step 3: The binary now has permission — launchd jobs can use it
```

> **Detection**: CheICalMCP treats a session as non-interactive, where a permission dialog cannot appear, when the process is a direct launchd child, when there is no window-server (GUI login) session, or, for the MCP server only, when the `CI` variable is set; it then gives targeted error messages with `--setup` instructions. `TERM` is not used (#165): a server that a GUI app such as Claude Desktop starts has no `TERM` but is in the GUI session, so it is interactive, and an SSH shell with `TERM` but no GUI session is not. For an indirect launch chain (launchd → Claude Code → CheICalMCP) the parent is not launchd, so the GUI session decides: under a LaunchDaemon, or with no GUI login, it is non-interactive; under a per-user LaunchAgent in the logged-in GUI session it counts as interactive and the access request is made. That reading follows from the rule; it has not been checked on a device.
>
> **`--setup` in non-interactive sessions** (#143): if you run `--setup` itself from a non-interactive session (a direct launchd child, or no GUI session; a `CI` variable does not count for `--setup`, #143) and permission is still undetermined, `--setup` now **skips the request and exits non-zero** instead of hanging — a TCC dialog can't appear there, so it prints manual-grant instructions rather than blocking. Run `--setup` from a real Terminal to trigger the dialog. (An already-granted binary still reports success even when re-run non-interactively.)
>
> **Note**: If `--setup` grants permission but the MCP still fails under launchd, TCC may have associated the permission with the parent process. In that case, switch CheICalMCP on in **System Settings → Privacy & Security → Calendar/Reminders**; if it is not listed, run `~/bin/CheICalMCP --setup` (or the `.mcpb` binary's path) from Terminal — the access request adds it.

---

## Technical Details

- **Current Version**: v1.23.0
- **Framework**: [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.12.0
- **Calendar API**: EventKit (native macOS framework)
- **Transport**: stdio
- **Platform**: macOS 14.0+ (Sonoma and later — bumped from 13.0 in the post-1.10 cluster per [#119](https://github.com/PsychQuant/che-ical-mcp/issues/119))
- **Tools**: 29 tools for calendars, events, reminders, tags, undo/redo, cleanup, and advanced operations

---

## Version History

| Version | Changes |
|---------|---------|
| v1.23.0 | **Self-disclaim follows the host's grant, one rule for every host** (#343, #367): a host with full Calendar and Reminders access keeps its grant, and so does a host a policy restricts; any other host, Claude Code included, re-execs onto CheICalMCP's own grant, which `--setup` creates. The banner, the access-denied message and `--print-tcc-path` give the same steps and say when a host's grant is kept on purpose; paste-ready commands are single-quoted. **Upgrade**: if CheICalMCP is not granted yet, run `~/bin/CheICalMCP --setup` once in the foreground, then restart the client. |
| v1.22.0 | **Under Claude Code, CheICalMCP is its own responsible process** (#343): when the responsible process macOS reports is Claude Code, the binary re-execs in place with the disclaim attribute so the `CheICalMCP` grant is the one checked (and Claude Code updates no longer invalidate it); `--setup` re-execs under any host; every other host keeps its own grant. `--print-tcc-path`, the start-up banner and the access-denied message name the process macOS checks. Not verified yet: reading the calendar through the re-exec under a Claude Code host. See the CHANGELOG for the migration step and the same-user trade-off. |
| v1.21.0 | **Complete long-range listings, series ids that explain themselves, conference module and per-folder routing** (#285/#310/#325/#326/#335/#337/#338): an event listing over more than four years is no longer cut at about 1461 days; a series whose first occurrence was deleted can be moved, copied and deleted again and its occurrences updated, and a bare series id that cannot be used says why (an earlier edited occurrence, or every remaining occurrence edited on its own); undo of a whole-series delete restores its exceptions inside the scan window; `make verify-release-ready` compares against the latest release tag. Plugin shell: a conference program becomes one all-day umbrella plus one timed event per item, and a folder's `calendar_routing` rules choose the calendar. |
| v1.20.0 | **Date-only reminders, undo that refuses to overwrite, start dates and alarms on reads** (#231/#235/#236/#243/#247/#262/#267/#297/#299/#301/#311): a bare `YYYY-MM-DD` `due_date` makes a date-only reminder and a date-only reminder is overdue only once its day has ended; `create_reminder` / `update_reminder` report `date_sync` (with `aligned`), `update_reminder` gains `realign_to_due`; `list_reminders` / `search_reminders` return `start` and `alarms`; reminder dates are read and written in the Gregorian calendar whatever the region setting; `undo` / `redo` refuse to overwrite a change made elsewhere after the operation, an `update_event` that touched a recurring event is never undone, and a created series whose occurrence was edited on its own (time included) is not deleted; undo keeps location / email / absolute alarms, recurrence, URL, availability and list; batch deletes record undo. **BREAKING (behavior)**: bare-date `due_date`, overdue rule, undo / redo refusals, `redo` of anything but a completion writes nothing. |
| v1.19.0 | **In-place event moves, reminder date sync, verified self-update** (#223/#225/#226/#227): `move_events_batch` reassigns the calendar instead of copy + delete, keeping recurrence, attendees and every field (identifier changes only across accounts; `span` / `occurrence_dates` for recurring events; per-event `method` / `id_changed` / `not_carried_over`; copy + delete only as a guarded fallback); `update_reminder` moves the start date and absolute-date alarms with the due date (Reminders.app shows the alarm's date) and reports `date_sync`, `clear_due_date` clears them, undo restores them; `--self-update` installs only a Developer ID signed + notarized binary, shared skeleton from `che-mcp-kit-swift` 0.2.x. **BREAKING (behavior)**: a recurring event without `occurrence_date` is refused; `copy_event` refuses to move a recurring event; a non-string `event_ids` entry is rejected. |
| v1.18.0 | **Undo/redo completeness for reminders, explicit `discard_id`, strict booleans everywhere** (#196/#197/#198/#199/#202/#203/#206/#207/#208/#209/#211/#212/#214/#215/#216): undo writes back the recorded `completion_date` and redo restores the saved instant instead of re-inferring state; repeated completion preserves the original instant; `undo(discard_id)` explicitly removes a blocked head record by its stable `undo_history` ID (not-found targets no longer jam the stack for deleted reminders or dead events); event moves record the source occurrence so undo restores into the original calendar; `event_recurrence_rules` / `reminder_recurrence_rules` distinguish the two formats (legacy aliases kept); every tool annotation has an explicit tested policy, with `complete_reminder`, update and optional-move tools now `destructiveHint: true`. **BREAKING**: every boolean tool argument is a strict JSON boolean (strings/numbers rejected with `<key> must be a boolean`). Internals: reminder list/search filter/sort/limit inside the actor pre-snapshot, `list_reminder_tags` on the snapshot seam, linear tag scan (no exponential backtracking), immutable Sendable reminder write results, completion/recurring-history methods in a dedicated actor extension. |
| v1.17.0 | **Reminder recurrence on read, explicit completion results, identity-guarded undo, strict boolean `completed`** (#194/#204/#205): `list_reminders` / `search_reminders` expose `has_recurrence`, full `recurrence_rules` (incl. `frequency_raw_value`) and a `due` object; `complete_reminder` separates the write outcome (`operation`) from the saved object (`observed`) and reports the successor as `next_occurrence` — observed once, synchronously, after save (on-device iCloud: the same ID advances in place, the finished occurrence is filed under a new ID), message in the reminder's own wall clock. Undo/redo of a recurring completion is identity-guarded: once the ID no longer resolves to the recorded occurrence it refuses explicitly and **discards** the entry so older operations stay undoable; not-found stays transient (#191). **BREAKING**: `completed` must be a JSON boolean on the three reminder tools (strings/numbers rejected before any read or write; omit/`null` keep their meaning; `--cli` JSON `null` → omitted). Three 6-AI verify rounds on PR #195 plus rounds on #200 / #201; two on-device stdio probes. 582 tests. |
| v1.16.1 | **Type-safety + on-device-verification fixes** (#184/#190/#191): non-object `recurrence` now rejected (was silently dropped); `all_day` + `timezone` pairing rejected (was silently stripping the all-day flag and defeating exclusions across the dateline); undo of a recurring-series deletion rebuilds rules from value snapshots (fixes EKCADErrorDomain 1010) and a failed undo/redo no longer consumes the entry. 529 tests. |
| v1.16.0 | **Recurrence exclusions + undo completeness + archive-event skill** (#182/#185/#180): `excluded_occurrence_dates` on create_event/batch (two-pass create-then-remove, compensating delete, first occurrence not excludable); batch/series deletions now record undo entries (one `.batch` unit); undo of a recurring create now removes the whole series; new `archive-event` skill — source-to-event archiving with correction tracking and `.claude/.ical/` project config. 514 tests. |
| v1.15.0 | **`--print-tcc-path` execution context + versioned-host banner signal.** The TCC diagnostic now prints its parent process chain (self → … → launchd) with a context-dependence warning — the authorization status follows the responsible-process context (#168), so knowing *which* host the query ran under is load-bearing (#169). Parent-chain diagnostics polish: visible truncation/cycle markers, empty-`comm` linkage, `ps -ww`, decode/exit failure reporting, NOTE precision (#173). New drift-detector signal: "versioned Claude Code host + ungranted EventKit" — explains the #170 update-rotation breakage proactively at startup, suppressing the contradictory `--setup` hint in that scenario (#175). All three verified by 6-AI cross-model ensembles; a CWE-150 terminal-escape gap found by verify was fixed pre-merge. Version drift from the v1.14.2 plugin release aligned across all five version sites (#172). 490 tests. |
| v1.14.2 | **Docs/skill-layer release — two-layer TCC authorization model** (#168): `troubleshoot-tcc` skill, `/check-tcc`, `mcpb/README.md`, and `plugin/CLAUDE.md` now document the host-app (responsible-process) TCC layer, the bare version-number System Settings entries (`2.1.202` = Claude Code's versioned binary), and the toggle-and-observe verification procedure. Binary byte-identical to v1.14.1 at release time (plugin-shell only; source version sites aligned later in #172). |
| v1.14.1 | **Metadata correction — tool-count consistency.** `server.json` `description` said "24 tools" and `PROMOTION.md` said "20 tools"; the server actually exposes **29 tools** (matching `mcpb/manifest.json` `long_description` and the `ManifestParityTests` tool-parity guard). Corrected the registry-facing `server.json`, `docs/COMPETITIVE_ANALYSIS.md`, and `PROMOTION.md` to 29. No code or tool-surface changes — functionally identical to v1.14.0; this release exists solely to publish corrected registry metadata (registry versions are immutable). |
| v1.14.0 | **Claude Desktop tool-injection drop fixed** (#166): a literal `&` in `mcpb/manifest.json` `display_name` made Desktop 1.18286.0 silently drop the whole 29-tool server from every conversation (Claude Code unaffected); changed `&` → `and`, confirmed by single-variable intervention on the failing install + a `ManifestParityTests` regression guard. Also aligned `serverInfo.name` to the kebab manifest id (hygiene; empirically refuted as the cause). **#154 sister batch**: csreq-mismatch TCC drift signal (#155, `SecCodeCheckValidity` self-check for the silent-denial class), `.mcpb` denial message no longer dead-ends on `--setup` for the already-`.denied` signature (#158), macOS badge 13.0 → 14.0 (#157), swift-nio 2.96 → 2.101 (#159). 454 tests. |
| v1.13.0 | **SwiftUI SetupWindow** (#164): interactive `--setup` presents a live-status window (per-entity Grant buttons + resolved binary path) inside the #163 foreground `NSApplication`. **Desktop Calendar-denied fix** (#165): `isNonInteractive` misfired on `TERM == nil` for GUI-app-spawned servers → fast-failed before `requestFullAccess`, so the first-grant dialog never appeared through Claude Desktop; now uses a `CGSession` GUI-session signal. 429 tests. |
| v1.12.0 | **Foreground `--setup`** (#163): interactive `--setup` now runs inside a foreground `NSApplication` so EventKit's Calendar TCC modal actually presents (previously silently denied from a bare CLI async context). Denial messages + startup banner surface the resolved binary path + a copy-pasteable `"<path>" --setup` command for the buried `.mcpb` binary. |
| v1.11.1 | **`create_event` time-range validation** (#160): symmetric with `update_event` — rejects inverted / zero-duration timed events via a shared `validateTimeRange` guard. 405 tests. |
| v1.11.0 | **TCC healing re-prompt unblocked** (#154): `Entitlements.plist` ships `personal-information.calendars` + `.reminders` — long-lived pre-v1.7.1 installs could hit silent permanent Calendar denial on macOS 26.5 (TCC row pinned to old cdhashes, healing re-prompt policy-blocked because the binary shipped no entitlements, every diagnostic reporting green); signed-binary release gate verifies both keys. **Non-interactive EventKit hardening** (#131 / #143 / #144 + #146–#150). **BREAKING**: deploy floor raised to macOS 14.0 (#119). 401 tests. |
| v1.10.0 | **TCC drift detector + startup banner** (#122): single-shot stderr banner at MCP-server startup with version/path/PID + drift signals (TCC.db path mismatch per-service, stale processes); opt-out via `CHE_ICAL_MCP_NO_BANNER=1`. Pipe-deadlock fix in subprocess helpers; CWE-117 stderr-injection defense on all interpolated banner values. |
| v1.9.0 | **TCC access gate refactor** (#108 Phase 2, closes #109): removed the process-lifetime `has*Access` cache anti-pattern; per-call `EKEventStore.authorizationStatus(for:)` via new `AuthorizationGate` + `AuthorizationStatusSource` seam (Apple TN3153 pattern) — state changes surface immediately instead of silent stale-grant fail. Adds `--print-tcc-path` diagnostic flag. |
| v1.8.1 | **Docs**: `mcpb/README.md` post-install / upgrade TCC permission setup guide (#108 Phase 1). |
| v1.8.0 | **Wire-format consistency wave + response-shape parameters** (#101 cluster — 5 issues closed in 3 days, all `Refs #N` IDD + 6-AI ensemble verify). **Event listing response-shape params** (#47 / #101): `detail_level` (`summary`/`standard`), `fields` allow-list, `display_timezone` (strict IANA), `limit` (cap 10000) — LLM verbosity tuning. **Envelope unification** (#102 / #107, **breaking wire-format**): `list_events.metadata.returned` + `list_reminders.metadata.returned` removed; all 5 list/search envelopes use top-level `<entity>_count` with pre-limit semantic; `search_reminders.result_count` → `reminder_count`; `search_reminders` gains `limit` parameter (mirror `search_events`). MCP clients reading `metadata.returned` or `result_count` must update. **Validator hardening** (#101 F1–F3): `requireOptionalInt` uses `Int(exactly:)` closing the `Int.max` DoS trap; `detail_level` / `display_timezone` validators distinguish absent vs. non-string (no silent coerce). **Runtime-anchored drift detection** (#103, strengthening #101 M3): `formatEventDict` ↔ `validEventFields` divergence test now via `EventFormattingSource` seam + `FakeFormattableEvent`. **CHANGELOG reclass** (#106): wire-format renames moved from `Fixed` to `Changed` (Keep a Changelog 1.1.0). **Release pipeline fix**: pre-pack defense check now derives Team ID from `DEVELOPER_ID` cert (was comparing SHA hash against human-readable `Authority=` string). |
| v1.7.2 | **Hardening + features wave** (30+ commits over v1.7.1, all `Refs #N` IDD with 6-AI verify). **`--self-update`** (#49) + **SHA-256 binary verify** (#98): existing-install upgrade path with cryptographic guarantee against corrupted releases. **`make install-signed`** (#50): maintainer dev TCC flow on macOS 26 — fail-fast on missing Developer ID + force codesign verification. **CI test workflow** (#51): PR-time `swift build` + `swift test` on macos-latest. **Sanitizer hardening cluster**: `escapeForStderr` full C0+DEL coverage (#73), `sanitizeForInterpolation` for executeUndo/executeRedo title interpolation (#74), CLIRunner stderr delegated to `writeFailureLog` for trusted-branch carve-out (#80), `writeFailureLog` 1024-char DoS cap (#86), `CLIError.invalidJSON` author-controlled-only contract doc (#85), `FileHandle.standardError.write` thread-safety + macOS PIPE_BUF=512 documented (#70 / #94). **Distribution polish**: stale-codesign-cache install snippets get `rm -f` preamble (#90 zh-TW parity for #62). **Post-v1.7.1 polish** (#46 #57 #58 #60): redo error interpolation parity, `build-mcpb.sh` step renumbering, `Entitlements.plist` documentation, `Makefile release-signed:` cwd note. **`cleanup_completed_reminders` tool** (#21): single-call cleanup of all completed reminders, `dry_run=true` default. |
| v1.7.1 | **Security hardening** (#20 #26): input validation (length limits + URL scheme allowlist) at all event/reminder entry points, prompt-injection wrapper on MCP read responses, parse-boundary validation for `days_of_week` / `days_of_month` / `alarms_minutes_offsets` (throws instead of silent-dropping invalid values), `Info.plist` catch-up, 42 new regression tests. |
| v1.7.0 | **Attendee & organizer info** (#17): read-only `attendees` array and `organizer` object in event responses. Refactored shared `formatEventDict` method. |
| v1.6.0 | **`--setup` flag** (#13): pre-authorize TCC permissions for launchd/automation. Non-interactive session detection (TERM + ppid). Combined SSH+launchd error messages. **`--cli` mode** (#14): invoke all 28 tools directly from command line without MCP server. Flag-based (`--key value`) and JSON stdin modes. Smart type inference for bool/int/double/array params. MCP Swift SDK 0.12.0 (Swift 6.3 compat). |
| v1.5.0 | **Per-event timezone** (#12): `timezone` parameter on `create_event`/`update_event`/`create_events_batch`, event output uses event's own timezone, naive datetimes parsed in event timezone. **Clear due date** (#9): `clear_due_date` on `update_reminder`. **Weekday validation** (#5): `create_event`/`update_event` validate `start_time` weekday against `days_of_week`. **Undo/redo** (#8): 3 new tools (`undo`, `redo`, `undo_history`). **Recurring event fixes** (#7): occurrence-level delete/update with `occurrence_date`. **Swift 6 build** (#11): README updated for `make release` workflow |
| v1.4.0 | **LLM reliability**: Fix default search range (±2yr instead of distantPast/Future), `searched_range` metadata in `search_events` response, `similar_events` hints in `create_events_batch`, LLM tips in tool descriptions |
| v1.3.1 | **Docs fix**: Clarified that tags are MCP-level (not native Reminders.app tags); Apple provides no public API for native tags |
| v1.3.0 | **Reminder tags** (MCP-level): `#hashtag` text stored in notes for `create_reminder`/`update_reminder`/`create_reminders_batch`, tag-based filtering in `search_reminders`, new `list_reminder_tags` tool; MCP SDK 0.11.0. Note: tags are searchable via MCP but do not appear as native Reminders.app tags (Apple provides no public API for this) |
| v1.2.0 | **Idempotent writes**: `create_event`, `create_events_batch`, `create_reminder`, `create_reminders_batch`, `create_calendar` now check-before-write to prevent duplicates on retry; responses include `skipped` count |
| v1.1.0 | **Recurrence + Location**: recurring events/reminders (daily/weekly/monthly/yearly), structured locations with coordinates, location-based reminder triggers (geofence enter/leave), rich recurrence output |
| v1.0.0 | **DX improvements**: flexible date parsing (4 formats), fuzzy calendar matching, `list_events`/`list_reminders` filter/sort/limit, `delete_events_batch` dry-run + date range mode |
| v0.9.0 | **4 new tools** (20→24): `update_calendar`, `search_reminders`, `create_reminders_batch`, `delete_reminders_batch` |
| v0.8.2 | **i18n week support**: `week_starts_on` parameter for `list_events_quick` (monday/sunday/saturday/system) |
| v0.8.1 | **Fix**: `update_event` time validation bug, duration preservation when moving events |
| v0.8.0 | **BREAKING**: `calendar_name` now required for create operations (no more implicit defaults) |
| v0.7.0 | **Tool annotations** for Anthropic Connectors Directory, auto-refresh mechanism, improved batch tool descriptions |
| v0.6.0 | **Source disambiguation**: `calendar_source` parameter for same-name calendars |
| v0.5.0 | Batch delete, duplicate detection, multi-keyword search, improved permission errors, PRIVACY.md |
| v0.4.0 | Copy/move events: `copy_event`, `move_events_batch` |
| v0.3.0 | Advanced features: search, quick range, batch create, conflict check, timezone display |
| v0.2.0 | Swift rewrite with full Reminders support |
| v0.1.x | Python version (deprecated) |

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Release Process (for maintainers)

Version numbers live in three places with different semantics:

| File | Role | When to bump |
|------|------|--------------|
| `Sources/CheICalMCP/Version.swift` — `AppVersion.current` | Source of truth; appears in `--version`, `help`, and MCP `serverInfo.version` | Every release |
| `Sources/CheICalMCP/Info.plist` — `CFBundleVersion` | macOS bundle version | Every release; must match `AppVersion.current` |
| `mcpb/manifest.json` — `version` | Claude Desktop bundle manifest shipped inside `.mcpb` | Every release; must match `AppVersion.current` |
| `server.json` — `version` + `packages[].identifier` + `fileSha256` | **MCP Registry submission snapshot** | Only when re-submitting a new `.mcpb` to the MCP Registry (independent cadence) |

`scripts/build-mcpb.sh` enforces the first three match; it will fail the build if any drifts. `server.json` is intentionally decoupled because bumping it requires a rebuilt `.mcpb`, a fresh SHA256, and a re-submission — steps that don't happen every source release.

#### Signing & Notarization (required for macOS 26+)

Starting v1.7.1, release binaries are signed with a Developer ID Application certificate and notarized via Apple's `notarytool`. This is **required** on macOS 26 — ad-hoc signed binaries cannot trigger Calendar / Reminders TCC permission dialogs there.

**Prerequisites** (one-time setup):

1. Apple Developer Program enrollment.
2. Developer ID Application certificate installed in login keychain.
   - Verify with: `security find-identity -p codesigning -v` (must show `Developer ID Application: <Your Name> (<TeamID>)`).
   - Your Team ID is your own — find it at <https://developer.apple.com/account> → Membership Details. (The maintainer's `6W377FS7BS` shown anywhere in this repo is for reference only.)
3. `notarytool` keychain profile (any name; `che-ical-mcp` is the default the build script looks for).
   - Create interactively (recommended — keeps password out of shell history):
     ```bash
     xcrun notarytool store-credentials che-ical-mcp --apple-id <your-apple-id> --team-id <your-team-id>
     # notarytool will prompt for the app-specific password
     ```
   - App-specific password: generate at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords. Use a single-purpose password (e.g. named `che-ical-mcp`); revoke + regenerate if leaked. **Never** pass it via `--password` on the command line — it lands in `~/.zsh_history`.
4. Export your identity for the build script:
   ```bash
   export DEVELOPER_ID='Developer ID Application: <Your Name> (<TeamID>)'
   export NOTARY_PROFILE='che-ical-mcp'   # match what you set up in step 3
   ```
   Persist these in `~/.zshrc` or a project-local `.envrc` (gitignored). The script intentionally has **no defaults** for these, so a fresh fork doesn't fail with errors referring to the maintainer's identity.

**Per-release flow**:

```bash
make release-signed     # builds universal binary → signs + notarizes → packages .mcpb
gh release create vX.Y.Z mcpb/server/CheICalMCP mcpb/server/CheICalMCP.sha256 mcpb/che-ical-mcp-X.Y.Z.mcpb mcpb/che-ical-mcp-X.Y.Z.mcpb.sha256 --notes "..."
```

`make release-signed` runs `scripts/build-mcpb.sh`, which after creating the universal binary calls `scripts/sign-and-notarize.sh`. The signing script does pre-flight checks (cert + notarytool profile) and fails fast with friendly messages if anything's missing. Notarization typically takes 1–15 minutes (`notarytool submit --wait` blocks until Apple finishes).

**Verification** after build (run all three to confirm end-to-end):

```bash
# 1. Signature properties (cert + hardened runtime + team ID)
codesign -dv --verbose=2 mcpb/server/CheICalMCP
# Expected:
#   Authority=Developer ID Application: <Your Name> (<TeamID>)
#   TeamIdentifier=<TeamID>
#   flags=0x10000(runtime)
#   Signature size in the few thousand bytes range (varies by cert chain)

# 2. Signature integrity
codesign --verify --deep --strict --verbose=2 mcpb/server/CheICalMCP
# Expected: exit 0, no warnings

# 3. Notarization end-to-end (this is the real "Gatekeeper would accept" gate)
spctl -a -vvv -t install mcpb/server/CheICalMCP
# Expected: <binary>: accepted; source=Notarized Developer ID
#
# Note on flag choice (verified empirically on macOS 26.4.1, 2026-05-04):
#   -t execute → rejected "code is valid but does not seem to be an app"
#                (Apple's "execute" type expects a .app bundle structure,
#                 not raw Mach-O CLI binaries)
#   -t install → accepted; source=Notarized Developer ID  ← use this
#   -t open    → rejected "Insufficient Context"
#
# Apple's Code Signing Guide describes -t execute as the assessment type for
# "applications and tools", but on macOS 26 raw Mach-O binaries fall through
# the .app bundle check. -t install is the documented assessment type for
# software being installed (which describes how a CLI binary lands in ~/bin),
# and is the type that returns the actual notarization verdict in practice.
# Re-test if Apple changes this behavior in a future macOS update.
```

**Local dev iteration** without signing latency:

```bash
SKIP_CODESIGN=1 ./scripts/build-mcpb.sh   # ad-hoc signed; do NOT ship the result
make install                              # installs ad-hoc to ~/bin (dev only)
```

The `build-mcpb.sh` script also **auto-skips signing** when `DEVELOPER_ID` is unset OR the cert isn't in your keychain — so contributors / CI / forks can build a working unsigned `.mcpb` for testing without manually setting `SKIP_CODESIGN`. (You'll see a clear "Skipping codesign" warning when this happens.)

**Signing identity environment**:

| Env var | Default | Required for |
|---------|---------|--------------|
| `DEVELOPER_ID` | _(unset — auto-skip signing)_ | Signed release |
| `NOTARY_PROFILE` | _(unset — fail-fast in `sign-and-notarize.sh`)_ | Signed release |
| `ENTITLEMENTS` | `Sources/CheICalMCP/Entitlements.plist` | Custom entitlements file |
| `SKIP_CODESIGN` | _(unset)_ | Force-skip signing even with cert present (set to `1` or `true`) |
| `REQUIRE_CODESIGN` | _(unset)_ | Fail-fast if signing prerequisites missing (set to `1` by `make release-signed` — canonical release path must not silently produce unsigned artifacts; do not set when running `./scripts/build-mcpb.sh` directly for fork-friendly dev builds) |

**Known limitation — no stapling**: `stapler staple` does not support raw Mach-O binaries (only `.app` / `.pkg` / `.dmg` bundles). After notarization, Gatekeeper will online-check the binary on first launch instead of reading a stapled ticket. End users behind air-gapped networks may see "cannot verify developer" warnings; one launch with network resolves it (Apple caches the verdict). Mitigation: `xcrun stapler staple` on a future `.pkg` wrapper if needed.

**Troubleshooting**:

- Notarization rejected? `xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE` shows Apple's reason. The signing script prints the submission ID on every run.
- `codesign` complains about missing identity? `security find-identity -p codesigning -v` to confirm cert is present + valid; `xcrun notarytool history --keychain-profile $NOTARY_PROFILE` to confirm the profile works.
- Cert expired? Re-issue at <https://developer.apple.com/account/resources/certificates>, install, re-export `DEVELOPER_ID`.
- Security warning: don't unlock signing keychain on shared / untrusted machines. The cert + private key signing artifact is supply-chain critical.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))

If you find this useful, please consider giving it a star!

**Recurrence read names (#198, unreleased):** use `event_recurrence_rules` for events and `reminder_recurrence_rules` for reminders. Both are rule arrays, but missing selectors and end-date rendering differ. The legacy `recurrence_rules` alias is retained. Clients rejecting unknown fields need decoder updates. See [the format comparison](docs/REMINDER_RECURRENCE.md#recurrence-read-formats-198).
