# calendar-resolution Specification

## Purpose

How a tool call finds the one calendar it acts on, from a title, a source and a calendar `id`, and what it does when the call matches none, several, or contradicts itself (#604).

## Requirements

### Requirement: A name and source that match more than one calendar are refused

When `calendar_name`, with or without `calendar_source`, matches more than one calendar of the requested kind (event calendar or reminder list), the server SHALL refuse the call on every lookup, read or write, and SHALL NOT choose one of them or read them together. The refusal SHALL change nothing in the store. It SHALL give the count of matching calendars. It SHALL list each candidate's `id` when every candidate `id` consists only of letters, digits and hyphens and is at most 64 characters, and otherwise SHALL list none. It SHALL NOT contain any calendar title or source title. It SHALL tell the caller to pass `calendar_id` when the tool takes one, and otherwise to rename one of the calendars in the Calendar or Reminders app. One matching calendar SHALL be used as before.

#### Scenario: Two event calendars share a title and an account

- **WHEN** `list_events` is called with `calendar_name` and `calendar_source` that two event calendars match
- **THEN** the call is refused with the count and the two `id`s, and no events are returned

##### Example: two calendars in one account are refused

| Tool | calendar_name | calendar_source | Calendars that match | Result |
|---|---|---|---|---|
| list_events | Calendar A | iCloud | 2 event calendars | refused, count 2, both ids listed |
| create_event | Calendar A | iCloud | 2 event calendars | refused, nothing written |
| list_events | Calendar A | iCloud | 1 event calendar | events of that calendar |
| list_events | Calendar A | (none) | 1 event calendar, 1 reminder list | events of the event calendar |

##### Example: a refusal names ids and no titles

| Candidate ids | Titles of the candidates | The refusal lists ids | The refusal contains a title |
|---|---|---|---|
| A1B2-C3, D4E5-F6 | Calendar A, Calendar A | yes | no |
| A1B2-C3, has space | Calendar A, Calendar A | no | no |

#### Scenario: A tool that takes no calendar id refuses with another remedy

- **WHEN** a tool without a `calendar_id` argument is called with a name and source that two calendars match
- **THEN** the call is refused and the text tells the caller to rename one of the calendars, not to pass `calendar_id`

##### Example: the remedy follows the tool

| Tool takes calendar_id | The refusal tells the caller to |
|---|---|
| yes | pass calendar_id |
| no | rename one of the calendars |

---
### Requirement: calendar_id selects one calendar

The tools `list_events`, `list_events_quick`, `search_events`, `check_conflicts`, `create_event`, `create_events_batch` (in each row) and `update_event` SHALL accept `calendar_id`, the `id` that `list_calendars` returns. A `calendar_id` SHALL select the one calendar with that `id`. The calendar SHALL be of the kind the tool works on; an `id` of a calendar of the other kind SHALL be refused as not found. When `calendar_name` or `calendar_source` is given with `calendar_id` and the selected calendar does not match them by the rule of the title and source match, the call SHALL be refused and SHALL change nothing; neither argument is ignored.

#### Scenario: calendar_id picks one of two same-title calendars

- **WHEN** `create_event` is called with the `calendar_id` of one of two event calendars that share a title and an account
- **THEN** the event is created in that calendar

##### Example: calendar_id against name and source

| calendar_id | calendar_name | calendar_source | Selected calendar | Result |
|---|---|---|---|---|
| id of pair member 1 | (none) | (none) | pair member 1 | used |
| id of pair member 1 | Calendar A | iCloud | pair member 1 (title and source match) | used |
| id of pair member 1 | Work | (none) | pair member 1 | refused, the name does not match |
| id of pair member 1 | Calendar A | Google | pair member 1 in iCloud | refused, the source does not match |
| id of a reminder list | (none) | (none) | none of the event calendars | refused as not found |
| an id no calendar has | (none) | (none) | none | refused as not found |

---
### Requirement: list_calendars says which kind each row is

Each row of `list_calendars` SHALL carry `entity_types`, a list that holds `event` when the calendar holds events and `reminder` when it holds reminders. A list of event calendars and reminder lists in one answer SHALL therefore tell the two kinds apart. The other fields of the row SHALL be unchanged.

#### Scenario: An event calendar and a reminder list share a title

- **WHEN** `list_calendars` is called without `type` and an event calendar and a reminder list share a title in one account
- **THEN** the two rows have different `id`s and the first carries `entity_types` of `["event"]` and the second `["reminder"]`

##### Example: entity types of a row

| Calendar allows | entity_types |
|---|---|
| events only | ["event"] |
| reminders only | ["reminder"] |
| both | ["event", "reminder"] |
