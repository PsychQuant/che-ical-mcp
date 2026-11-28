## MODIFIED Requirements

### Requirement: A name and source that match more than one calendar are refused

Only the calendars of the kind a tool works on (event calendars or reminder lists) SHALL be candidates. When more than one candidate matches `calendar_name`, and either `calendar_source` was given or every match has the same source title, the server SHALL refuse the call on every lookup, read or write, and SHALL NOT choose one of them or read them together. The refusal SHALL change nothing in the store. It SHALL give the count of matching calendars. It SHALL list each candidate's `id` when every candidate `id` consists only of ASCII letters, digits and hyphens and is 1 to 64 characters long, and otherwise SHALL list none. It SHALL NOT contain any calendar title or source title. It SHALL tell the caller to pass `calendar_id` when the lookup serves a tool that takes one, and otherwise to rename one of the calendars in the Calendar or Reminders app. `delete_events_batch`, the reminder tools, and the target calendar of `copy_event` and `move_events_batch` take no `calendar_id`.

The one exception: when no `calendar_source` was given and the matches have more than one distinct source title, as written, the server SHALL refuse as it did before #604, with a text that repeats the caller's `calendar_name` and asks for `calendar_source`, and that holds no source title and no `id`. One matching calendar SHALL be used as before.

#### Scenario: Two event calendars share a title and an account

- **WHEN** a lookup is made with a `calendar_name` and `calendar_source` that two calendars of the requested kind match
- **THEN** it is refused with the count and the two `id`s, and no calendar is returned

##### Example: two calendars in one account are refused

| Kind looked up | calendar_name | calendar_source | Event calendars | Reminder lists | Result |
|---|---|---|---|---|---|
| event | Calendar A | iCloud | two titled Calendar A in iCloud | (none) | refused, count 2, both ids listed |
| event | Calendar A | iCloud | one titled Calendar A in iCloud | (none) | that calendar |
| event | Calendar A | (none) | one titled Calendar A in iCloud | one titled Calendar A in iCloud | the event calendar |

##### Example: a refusal names ids and no titles

| Candidate ids | The refusal lists ids | The refusal contains a title or source title |
|---|---|---|
| A1B2-C3, D4E5-F6 | yes | no |
| A1B2-C3, has space | no | no |
| A1B2-C3, an id with the Kelvin sign U+212A | no | no |

#### Scenario: A name two accounts share, with no source

- **WHEN** a lookup has no `calendar_source` and calendars of two different source titles match `calendar_name`
- **THEN** it is refused with the earlier text that asks for `calendar_source`

##### Example: two accounts without a source keep the earlier refusal

| calendar_name | Matches | The refusal asks for | The refusal contains |
|---|---|---|---|
| Calendar A | one in iCloud, one in Google | calendar_source | the caller's calendar_name, no source title, no id |

#### Scenario: A tool that takes no calendar id refuses with another remedy

- **WHEN** a lookup for a tool without a `calendar_id` argument finds two calendars of one account that match
- **THEN** it is refused and the text tells the caller to rename one of the calendars, not to pass `calendar_id`

##### Example: the remedy follows the tool

| Lookup | The refusal tells the caller to |
|---|---|
| the range reads of list_events, list_events_quick, search_events and check_conflicts | pass calendar_id |
| create_event and update_event | pass calendar_id |
| the listing delete_events_batch deletes from | rename one of the calendars |
| the target of copy_event and move_events_batch | rename one of the calendars |
| the reminder tools | rename one of the calendars |

### Requirement: calendar_id selects one calendar

The tools `list_events`, `list_events_quick`, `search_events`, `check_conflicts`, `create_event`, `create_events_batch` (in each row) and `update_event` SHALL accept `calendar_id`, the `id` that `list_calendars` returns. A `calendar_id` SHALL select the one calendar with that `id` among the calendars of the kind the tool works on; an `id` of a calendar of the other kind, and an empty `calendar_id`, SHALL be refused as not found. When `calendar_name` or `calendar_source` is given with `calendar_id`, the selected calendar alone SHALL be compared with them, by the title and source match (exact, then ignoring case); when it does not match, the call SHALL be refused and SHALL change nothing. Neither argument is ignored.

#### Scenario: calendar_id picks one of two same-title calendars

- **WHEN** a lookup carries the `calendar_id` of one of two event calendars that share a title and an account
- **THEN** that calendar is returned

##### Example: calendar_id against name and source

| calendar_id | calendar_name | calendar_source | Result |
|---|---|---|---|
| pair member 1 | (none) | (none) | pair member 1 |
| pair member 1 | Calendar A | iCloud | pair member 1 |
| pair member 1 | Work | (none) | refused, the name does not match |
| pair member 1 | Calendar A | Google | refused, the source does not match |
| a reminder list | (none) | (none) | refused as not found |
| an id no calendar has | (none) | (none) | refused as not found |
| (empty) | Calendar A | (none) | refused as not found |

### Requirement: list_calendars says which kind each row is

Each row of `list_calendars` SHALL carry `entity_types`, a list holding one name: the list the row was read from, `event` for the event calendars and `reminder` for the reminder lists. A calendar that both lists return SHALL appear as one row per list. Without `type`, the event calendars SHALL come first. The other fields of the row SHALL be unchanged.

#### Scenario: An event calendar and a reminder list share a title

- **WHEN** `list_calendars` is called without `type` and an event calendar and a reminder list share a title in one account
- **THEN** the row from the event list carries `entity_types` of `["event"]` and the row from the reminder list `["reminder"]`

##### Example: entity types of a row

| type argument | Lists read, in order | entity_types of their rows |
|---|---|---|
| event | event calendars | ["event"] |
| reminder | reminder lists | ["reminder"] |
| (none) | event calendars, then reminder lists | ["event"], then ["reminder"] |
