---
name: archive-event
description: Archive a meeting or event into Calendar from a narrative source — a meeting notice, an announcement, a message thread — deriving the time from the thread's authoritative correction, recording the source in the event notes, and labelling any value the source did not state. Use when the user hands over a notice, forwards a thread, or asks to "put this meeting in the calendar" from something they read. The boundary with quick-event is the SOURCE, not completeness: a fully specified notice still belongs here whenever the basis should be recorded; quick-event is for times the user states directly with nothing to cite.
allowed-tools:
  - mcp__che-ical-mcp__list_calendars
  - mcp__che-ical-mcp__list_events
  - mcp__che-ical-mcp__search_events
  - mcp__che-ical-mcp__create_event
  - mcp__che-ical-mcp__update_event
  - mcp__che-ical-mcp__check_conflicts
  - mcp__che-ical-mcp__list_reminders
  - Read
  - Write
  - Edit
  - Bash
---

# Archive an event from a source

Turning "here is the notice" into a calendar entry requires judgements the 29 EventKit tools will never prompt for. Two of those judgements fail **silently** — the event is created, the calendar looks normal, and the content is wrong:

- **The time was superseded.** A notice goes out, then the organizer corrects it. Reading only the first message puts the wrong day in the calendar.
- **An estimated value reads as a stated fact.** Notices often omit the end time. An estimate that is not labelled is indistinguishable, later, from something the source actually said.

Failures that raise an error can live in a README — the reader will look it up. Silent failures cannot, because nobody knows to look. That is what this skill is for.

## What already exists — do not rebuild it

| Mechanism | Covers | Does not cover |
|---|---|---|
| `quick-event` command | parse → list calendars → **conflict check** → create | source derivation, correction tracking, evidence |
| `create_event` built-in idempotency | same-calendar repeat of (title, start ±30s) | the same activity after its start time changed |
| `find_duplicate_events` tool | duplicates **across** calendars | within one calendar (it skips same-calendar pairs by design) |
| `calendar-management` skill | tool catalogue and common workflows | the judgements below |

Conflict checking exists as a tool — this skill still invokes `check_conflicts` itself before any create (it does not go through quick-event, so it inherits nothing). What it adds are the five judgements that no existing mechanism covers.

## Procedure

```
source ──▶ 1. authoritative time ──▶ 4. which calendar ──▶ 3. compose notes
                                                               │
                              2. update or create  ◀───────────┘
                              （check_conflicts before create）
                                            │
                                            └──▶ 5. same-day deadlines
```

Numbers refer to the sections below (ordered by topic, not execution): calendar choice and the notes body must be resolved BEFORE the create/update call that consumes them, and a `check_conflicts` on the resolved time precedes any `create_event`.

---

## Configuration and state

Two optional files under `.claude/.ical/` steer this skill. Both may be absent — absence is never an error.

**`config.yaml`** — human-authored; comments record the reasoning behind each setting. Found by the lookup in [`rules/calendar-routing.md`](../../rules/calendar-routing.md) (nearest one walking up from the working directory, then `~/.claude/.ical/`), which also defines its `calendar_routing` block. Besides that block and the module switches of [`rules/event-modules.md`](../../rules/event-modules.md) (`conference_module`), this skill reads one field:

```yaml
# Which calendar archived events land in when no routing rule matched.
# Reason recorded here, e.g.: 系上行政活動一律進「行政」，家庭行程勿混入.
default_calendar: "行政"
```

**`state/archives.json`** — always in the working directory's own project (`.claude/.ical/state/`), even when `config.yaml` came from a parent directory. Machine-queried map from source identifier to the archived event. Written by this skill after every successful archive; never hand-edited:

```json
{
  "<message-id>": {
    "event_id": "…",
    "calendar": "行政",
    "archived_at": "2026-08-31T14:00:00+08:00"
  }
}
```

If either file fails to parse, say so explicitly in the report and proceed as if it were absent — a malformed config must never silently change behavior.

---

> **An input that matches a module's trigger** in [`rules/event-modules.md`](../../rules/event-modules.md) (today: a conference program), when that module is on, is built as the module says; otherwise carry on below. For such a source the module replaces §2's create/update of one event and its search by source identifier; §4 stays as the module's calendar fallback. Judge the trigger on the program the thread holds, not on the newest message alone. Still apply: §1 (the authoritative message; a newest message that corrects only some items is a partial correction, applied to the existing set as the module's section 6 says); §2's `state/archives.json` lookup and its write-back, which maps the source identifier to the umbrella event. When the lookup maps the source to an event, read that event's notes: if they carry the module's `conference-module-item: umbrella` marker, that marker finds the set; if not, it is a single event archived before the module, so tell the user and ask before building the program. §3 (the source line and any estimate line, placed in each event's notes above the module's marker lines; a session without an end time uses the module's estimate instead of asking); and §5 over the program's days, leaving out the program's own events. The report says corrections are tracked by the module's marker lines. Normative: the `event-source-archiving` requirement "A conference program is archived through the conference module".

## 1. Authoritative time: sender identity + parsable time

Walk the thread **from the newest message backwards**. Select the first message that satisfies **both**:

- **(a)** its sender matches the sender of the original notice
- **(b)** its body contains a parsable date-time

Stop at the first match. Do not keep walking.

**Do not select by recency.** The last message in a thread is very often an attendee's acknowledgement, not the organizer's correction. Taking it silently yields the wrong time.

**Do not use a keyword list.** Organizers do not reliably write "correction" or "rescheduled" — real notices say "更正資訊如下", "因故調整", "新的時間是", and endlessly more. Every phrasing missing from the list is another silent failure.

Condition (b) is what makes this work: a message with no time cannot, by definition, be a reschedule. It excludes exactly the "shall we push it later?" proposals that a recency rule would wrongly take.

### Reading the two conditions precisely

| Term | Means | Not |
|---|---|---|
| sender matches | the **email address** is identical | the display name — those vary between clients and mail systems |
| parsable date-time | a date **and** a time-of-day (`Aug 13 15:30`, `8/13 下午 3:30`) | a bare date, a weekday alone, or a month reference |

A message that gives only a date is not a reschedule notice; it is a mention. Treat it as failing (b).

### Worked example

A four-message thread, in chronological order:

| # | Sender | Content |
|---|---|---|
| 1 | organizer | notice for Aug 12 14:00 |
| 2 | someone else | "shall we push it later?" — no specific time |
| 3 | organizer | new time: Aug 13 15:30 |
| 4 | attendee | "noted, thank you" |

The backward walk:

| Step | Message examined | (a) sender matches? | (b) parsable time? | Result |
|---|---|---|---|---|
| 1 | (4) attendee reply | no | no | continue |
| 2 | (3) organizer new time | yes | yes | **select — stop** |

The event starts **Aug 13 15:30**. Messages (1) and (2) are never examined.

Why not message (4)? It is the newest, and a recency rule would take it — but it carries no time, so the skill would then have to fall back to some earlier message anyway, and any rule for choosing *which* earlier message is the rule above. Condition (b) rejects (4) outright.

### When neither condition can be satisfied

**Do not infer a time.** List the candidate messages with their senders and times, and ask the operator which is authoritative.

The common trigger is one person writing from two addresses — the institutional account for the original notice, a personal account for the correction. Condition (a) misses it. Handing the choice back is correct here: an operator glancing at two candidates resolves it in seconds, and the alternative is a wrong time nobody notices.

---

## 2. Update or create, keyed on the source

Record a **source identifier** whenever the source provides one, in two places: the `state/archives.json` index (primary) and the event notes' source line (fallback + human-readable evidence; notes may be hand-edited later, the state file is written only by this skill).

**The stable key is the ORIGINAL notice's `Message-ID`** — the first message of the thread, not the correction being archived. A correction arrives in a different mail with its own Message-ID; keying on it would orphan the event archived from the original. When archiving any message of a thread, resolve the thread's first message and use ITS Message-ID for both lookup and write-back.

Before creating anything, resolve the identifier:

1. **`state/archives.json` maps it** → `update_event` on the mapped event directly, no search needed.
2. **Index miss** (state absent, or entry missing) → search existing events for the identifier in their notes: **found** → `update_event`; **not found** → `create_event`.

After every successful archive, write the mapping back to `state/archives.json` (creating the file on first use).

### Why the built-in idempotency is not enough

`create_event` already refuses same-calendar duplicates, keyed on **(title, start time ±30s, calendar)**. After a reschedule from Aug 12 14:00 to Aug 13 15:30 the start time no longer matches, so that key sees a *new* event — it creates the second one and leaves the superseded event in place.

The source identifier does not move when the time does. That is the whole reason to key on it.

### When the source has no stable identifier

A verbal account, a screenshot, a forwarded excerpt with headers stripped — none carry an identifier.

Fall back to the existing create-time behavior, and **state in the report** that later corrections to this source cannot be detected. Do not silently accept the degraded guarantee: the operator needs to know that re-archiving will not clean up after itself.

---

## 3. Event notes: source citation and estimate labelling

Notes carry two lines. The source line is always present. The estimate line appears **only** when a value was estimated.

```
來源：<sender> <date>「<subject>」
推估：結束時間 17:30（沿用同行事曆前次同類活動時長；通知未載明）
```

### The source line

Names the sender, the date, the subject or title of the source, and the source identifier (`Message-ID` of the thread's original notice) — the same key the state index uses, so the notes-search fallback in §2 has a concrete string to find.

Its purpose is recovery: months later someone opens the event in Calendar with none of the conversation in which it was archived. The notes have to answer "where did this come from" on their own.

### The estimate line — mandatory, not configurable

Whenever the skill supplies a value the source did not state, the line states three things:

1. the estimated value
2. the basis for the estimate
3. that the source did not state it

**This is not optional and there is no setting to turn it off.** The moment it is most likely to be skipped — a busy archive, an "obviously fine" estimate — is exactly the moment it matters. An unlabelled estimate is a guess wearing the costume of a fact.

**When nothing was estimated, omit the line entirely.** Do not emit an empty line or a placeholder such as `推估：（無）`. Noise trains readers to skip the field, which defeats it.

### Worked example

A notice states: a meeting on **Aug 13 at 15:30**, room 2008. No end time. The two most recent events of the same kind on the target calendar each ran two hours.

Result:

- Event: **15:30 – 17:30**
- Notes:

```
來源：<sender> <date>「<subject>」
推估：結束時間 17:30（沿用同行事曆前次同類活動時長；通知未載明）
```

"Same kind" means events matching this one's title pattern on the same calendar — a recurring lab meeting, a recurring coordination meeting. If no prior comparable event exists, do not invent a duration: ask the operator.

Had the notice stated both start and end times, the notes would carry the source line and **no** estimate line.

---

## 4. Which calendar

Four tiers, first hit wins:

1. **Routing** — a `calendar_routing` rule that matches the event, resolved as [`rules/calendar-routing.md`](../../rules/calendar-routing.md) says (including asking when two rules match, and the `Routed to …` report line).
2. **`config.yaml` → `default_calendar`** — if the config sets one, use it without asking. Only this skill reads it.
3. **Derivation** — look up where activities of this kind were filed previously, and follow that.
4. **Ask** — nothing comparable found: ask the operator.

Derivation matches its accuracy from the second occurrence onward; the config tiers remove even the first-occurrence question for projects that declared their intent.

---

## 5. Same-day deadlines

After creating or updating the event, check for other deadlines on the same day and list any found in the report:

- calendar events on that date
- reminders due on that date

**Scope this claim honestly.** The check covers calendar events and reminders. Deadlines living in mail, issue trackers, or anywhere else are not visible here — do not report "no other deadlines" as though the sweep were exhaustive.

---

## Report

After archiving, report:

- the event created or updated, with its final time and calendar
- how the calendar was decided: the `Routed to …` or `Not routed: …` line from [`rules/calendar-routing.md`](../../rules/calendar-routing.md)
- which message the time came from, when the source was a thread
- any estimated field and its basis
- whether correction tracking is available for this source
- same-day deadlines found, scoped as above

## Related

- **`quick-event`** — the time and place are already known and stated; just create it.
- **`calendar-management`** — which tool does what, and common workflows.
- **`troubleshoot-tcc`** — calendar tools failing or silently doing nothing.
