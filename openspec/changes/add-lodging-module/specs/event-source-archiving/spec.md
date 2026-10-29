## ADDED Requirements

### Requirement: A booking confirmation is archived through the lodging module

When the source is a booking confirmation, change notice or cancellation notice for a stay and the `lodging-module` capability is enabled and triggered, the skill SHALL build the event through that module instead of creating or updating one event, and this requirement SHALL take precedence over the single-event rules of this capability for that source only. The skill SHALL still write the source line (sender, date, subject, Message-ID) into the event's notes above the module's marker line, and SHALL still surface same-day deadlines. The key of the event SHALL be the reservation number carried in the module's marker line and not the Message-ID of the original notice, because a change or cancellation notice is a different message; the authoritative message SHALL be the latest message carrying the reservation number, and the skill SHALL ask when the order of messages is unclear. The skill SHALL NOT write an estimate line for a stay: when the check-out date is missing, the skill SHALL ask. The skill SHALL record in `state/archives.json` the source identifier mapped to the stay event. The skill reads `lodging_module` from the same config as its other fields.

#### Scenario: A change notice in a different message

- **GIVEN** a stay was archived from a confirmation and a later message with another Message-ID changes its dates
- **WHEN** the later message is archived
- **THEN** the event is found through the reservation number in its marker line, updated in place, and no second event is created

#### Scenario: The check-out date is missing

- **GIVEN** a confirmation that states the check-in date but not the check-out date
- **WHEN** the skill archives it
- **THEN** the skill asks for the check-out date and writes no estimate line

#### Scenario: The report on correction tracking

- **GIVEN** a stay was archived through the module
- **WHEN** the skill reports
- **THEN** the report says corrections are tracked by the module's marker line, and `state/archives.json` maps the source to the stay event
