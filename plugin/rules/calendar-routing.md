# Calendar Routing — which calendar an event goes into

Every event-creating entry point (`archive-event`, `/quick-event`, the create workflow of `calendar-management`) resolves the destination calendar through this one rule. Entry points point here; they do not restate it. Normative source: `openspec/specs/calendar-routing/spec.md`.

## 1. Find the config

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/find-ical-config.sh"        # starts from the current directory
```

It prints the path of the config that applies and exits 0, or prints nothing and exits 1. Order: the nearest `.claude/.ical/config.yaml` walking up from the working directory (closest wins; files are **never merged**; the walk ends at a git repository boundary, at `$HOME`, or at the filesystem root), then `~/.claude/.ical/config.yaml`. A config file is skipped with a warning on stderr when the file, its `.ical` directory or its `.claude` directory (judged at the physical path) is not owned by the current user or is writable by group or others (a file planted in or swapped within a shared directory such as `/tmp` must not redirect events); say so in the report. Exit 1 means no config: the entry point behaves as it did before routing (the caller names the calendar).

Read the file with `Read`. A file that does not parse as YAML is reported (name the file) and treated as absent.

## 2. The `calendar_routing` block

```yaml
calendar_routing:
  - kind: conference_schedule        # your own name for the kind
    calendar: Conference             # required: the destination calendar
    includes: items the organizer scheduled with a time — program sessions, own talk, tutorial/workshop, reception   # required, non-empty
  - kind: travel
    calendar: 旅遊
    source: iCloud                   # optional: the account, when the same calendar name exists in more than one
    includes: flights, lodging, transfers (train/bus), sightseeing and private plans around the trip

default_calendar: "行政"             # unchanged: archive-event's first tier only; routing never falls back to it
```

- Kind names are yours. The plugin defines none.
- `includes` is the closed list of what the kind covers. Match the event against it; do not match by similarity to the kind's name.
- An entry without `calendar`, or with an empty or missing `includes`, is invalid: report the entry, **ignore the whole `calendar_routing` block**, and keep using the other fields of the file (`default_calendar` still works).
- An unknown key (for example `when`) is reported and ignored; the rest of the rule still applies.

## 3. Classify

Compare the event with each rule's `includes`.

| Matches | Do |
|---|---|
| exactly one rule | create the event in that rule's calendar, no calendar question |
| no rule | do what the entry point does without routing (the caller names the calendar; `archive-event` continues with `default_calendar`, then derivation, then asking). Routing itself never applies `default_calendar` |
| two or more rules | **ask the user** which rule applies; create nothing until they answer. Never take the first rule listed |

Worked examples for a conference folder with the rules above:

- A program session (09:30–10:20, Hall A) → `conference_schedule`.
- A flight to the venue city, the hotel stay, the shinkansen leg → `travel`.
- An excursion the organizer runs on the free afternoon → fits both (organizer-scheduled, and sightseeing) → ask.
- A dentist appointment → fits neither → no rule matched.

The match is a judgment, so state it: the report names the rule (section 5), and the user can correct it.

## 4. The calendar must exist

Look the calendar up by name with `list_calendars` (with `source`, in that account only). If it does not exist, say so and ask how to proceed. **Never create a calendar for routing**: routing selects among existing calendars, it does not provision them.

## 5. Report

Every creation says how the calendar was decided:

- Routed: `Routed to <calendar> by rule '<kind>' from <config path>`. When two rules matched and the user picked one, add the fact: `Routed to <calendar> by rule '<kind>' from <config path> (user chose between '<kind>' and '<kind>')`.
- Not routed, one of:
  - `Not routed: no config file found`
  - `Not routed: no rule matched` (when the file has no `calendar_routing` block at all, say so: `Not routed: no rule matched (no calendar_routing in <file>)`)
  - `Not routed: asked the user (two rules matched)` (only when the user then named a calendar that is none of the matching rules')
  - `Not routed: <file> could not be parsed, treated as absent`
  - `Not routed: invalid calendar_routing in <file>, block ignored (<which entry, what is missing>)`
  - `Not routed: calendar '<name>' of rule '<kind>' does not exist, asked the user` (after the user chose another calendar)

A config problem is always said out loud; it never changes behavior silently. When nothing is created yet (waiting for the user's answer), say what you are waiting for; the report line comes with the creation.

## 6. `default_calendar` and archive state

`default_calendar` keeps its meaning: `archive-event` reads it as the first tier of calendar choice, after routing. `/quick-event` and `calendar-management` do not read it. A config with only `default_calendar` behaves exactly as before routing existed. `archive-event`'s `state/archives.json` stays in the working directory's own `.claude/.ical/state/`, even when the config came from a parent directory.

## 7. Inputs that become several events

When an [event module](event-modules.md) turns one input into several events (for example a conference program), resolve the calendar **once for the whole input** and use it for every event the module creates. Do not classify the events one by one: a rule's `includes` text is written for the events it names, and a module's umbrella (an all-day event) may not fit it. A rule's kind may be a lodging one (`includes: "hotel stay"`): the lodging module classifies its one event against the rules once. When one input also matches another module, each module resolves its own calendar separately; a rule that applies to one does not change the other's.
