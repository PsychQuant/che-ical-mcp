## ADDED Requirements

### Requirement: A booking confirmation is archived through the lodging module

When the source is a booking confirmation, change notice or cancellation notice for a stay and the `lodging-module` capability is enabled and triggered, the skill SHALL build the event through that module instead of creating or updating one event, and this requirement SHALL take precedence over the single-event rules of this capability for that source only. The skill SHALL still write the source line (sender, date, subject, Message-ID) into the event's notes above the module's marker line, and SHALL still surface same-day deadlines. The key of the event SHALL be the reservation number carried in the module's marker line and not the Message-ID of the original notice, because a change or cancellation notice is a different message. The skill's rule for choosing the authoritative message by sender and parsable time SHALL NOT apply to a stay: the authoritative message SHALL be the latest message carrying the reservation number, ordered by each message's own date (the original's date for a forwarded message), and the skill SHALL ask when the order is unclear. The skill SHALL still apply its calendar fallback and its same-day deadline check. The skill SHALL NOT write an estimate line for a stay: when the check-out date is missing, the skill SHALL ask. The skill SHALL record in `state/archives.json` the source identifier with the suffix `#lodging` mapped to the stay event, so that a source which also built a conference keeps its own entry, SHALL treat a mapping only as a hint, SHALL remove the mappings that name an event the module deleted, and SHALL write nothing for a cancellation left pending. The skill SHALL NOT apply the conference module's umbrella lookup or its marker lines to a stay: when `state/archives.json` maps the source to an event, the skill SHALL read that event's notes and treat it as a module event only if they hold the `lodging-module:` marker line, and otherwise as a hand-built event that is adopted only after a mapping table and the user's yes. A cancellation notice SHALL follow the module's confirmation rule, and the skill SHALL NOT list `delete_event` in its `allowed-tools`. The skill reads `lodging_module` from the same config as its other fields.

#### Scenario: A change notice in a different message

- **GIVEN** a stay was archived from a confirmation and a later message with another Message-ID changes its dates
- **WHEN** the later message is archived
- **THEN** the event is found through the reservation number in its marker line, updated in place, and no second event is created

#### Scenario: The check-out date is missing

- **GIVEN** a confirmation that states the check-in date but not the check-out date
- **WHEN** the skill archives it
- **THEN** the skill asks for the check-out date and writes no estimate line

#### Scenario: The state maps the source to a hand-built event

- **GIVEN** `state/archives.json` maps a source to an event whose notes hold no `lodging-module:` marker line
- **WHEN** a booking confirmation for that stay is archived
- **THEN** the skill shows a mapping table of the event and the booking and asks once, and writes nothing to the event before the user says yes

#### Scenario: A source builds a conference and a stay

- **GIVEN** one message registers for a conference and confirms a room
- **WHEN** the skill archives it
- **THEN** `state/archives.json` holds the umbrella under the message identifier and the stay under the identifier with the suffix `#lodging`

#### Scenario: A cancellation has no time

- **GIVEN** an event for reservation 123456 and a cancellation notice that states no date-time
- **WHEN** the skill chooses the authoritative message
- **THEN** it chooses the latest message carrying 123456, not the older confirmation

#### Scenario: The report on correction tracking

- **GIVEN** a stay was archived through the module
- **WHEN** the skill reports
- **THEN** the report says corrections are tracked by the module's marker line, and `state/archives.json` maps the source to the stay event
