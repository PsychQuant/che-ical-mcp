## ADDED Requirements

### Requirement: Occurrence lookups read the series' calendar

The lookup of an occurrence of a recurring event by date, and the reading of the requested day's events after it missed (#532) or for an exclusion retry (#534), SHALL query only the calendar of the series object the call read: for `update_event`, `delete_event`, `delete_events_batch` and `move_events_batch`, the resolved series object's calendar, never a move's target; for the exclusions of a series just created, that series' calendar; for an exclusion retry, the calendar the duplicate lookup searched. Every event calendar SHALL be queried only when that object has no calendar. Which occurrence is taken SHALL NOT change: the same identifier, slot and start-day checks apply. A lookup that misses in the series' calendar SHALL NOT be retried in other calendars (#573).

#### Scenario: Two calendars hold events on the requested day

- **GIVEN** a series in calendar Work and another series in calendar Other, both with an occurrence on the requested day
- **WHEN** an occurrence of the Work series is looked up on that day
- **THEN** the query names only Work, and the Work occurrence is returned

#### Scenario: The calendar is unknown

- **GIVEN** a series object with no calendar
- **WHEN** an occurrence is looked up
- **THEN** every event calendar is queried, as before

#### Scenario: An occurrence reported in another calendar

- **GIVEN** an occurrence of the series that the store reports in a calendar other than the series'
- **WHEN** it is looked up
- **THEN** it is not found, the call answers as for a missing occurrence, and nothing is written
