## ADDED Requirements

### Requirement: A conference program is archived through the conference module

When the source is a conference program and the `conference-module` capability is enabled and triggered, the skill SHALL build the events through that module instead of creating or updating one event, and this requirement SHALL take precedence over the single-event rules of this capability for that source only. The skill SHALL still choose the authoritative message by sender identity and parsable time, SHALL still write the source line (with the source identifier) and estimate lines into each event's notes above the module's marker lines, and SHALL still surface same-day deadlines, leaving out the program's own events. Correction tracking for the program SHALL be the module's dedup by marker lines rather than the search by source identifier, and the report SHALL say so. The skill SHALL record in `state/archives.json` the source identifier mapped to the umbrella event. When `state/archives.json` maps the source to an event, the skill SHALL read that event's notes: when they carry the module's umbrella marker, that marker SHALL be used to find the set without a question; otherwise the event was archived before the module, and the skill SHALL tell the user and ask before building the program. When a session's end time is not stated, the skill SHALL use the module's estimate (the next item's start, or start plus one hour) with an estimate line instead of asking the operator. The skill SHALL judge the module's trigger on the program the thread holds, not on the newest message alone. When the authoritative message is a partial correction that names only some items, the skill SHALL apply it to the existing set, found through the umbrella the source maps to, as a correction of those items, and SHALL NOT list the items it does not name as outdated or update the umbrella with an item's values. The skill reads `conference_module` from the same config as its other fields.

#### Scenario: A corrected program in the same thread

- **GIVEN** a program was archived from a thread and the organizer later sends the full program with one session moved
- **WHEN** the thread is archived again
- **THEN** the index maps the thread to the umbrella, whose marker finds the set without an extra question; the module shows the moved session in its mapping table, and no second set is created

#### Scenario: A partial correction

- **GIVEN** a program was archived and the organizer's newest message only says that one session moves to 14:00
- **WHEN** the thread is archived again
- **THEN** the set is found through the umbrella the thread maps to, only that session is shown for correction, the umbrella is not changed, and the other sessions are not listed as outdated

#### Scenario: The state index maps the source to a single event

- **GIVEN** `state/archives.json` maps the thread's Message-ID to one event archived before the module existed, whose notes carry no module marker
- **WHEN** the thread is archived again and turns out to be a program
- **THEN** the skill tells the user and asks before building the program

#### Scenario: The report on correction tracking

- **GIVEN** a program was archived through the module
- **WHEN** the skill reports
- **THEN** the report says corrections are tracked by the module's marker lines, and `state/archives.json` maps the source to the umbrella event
