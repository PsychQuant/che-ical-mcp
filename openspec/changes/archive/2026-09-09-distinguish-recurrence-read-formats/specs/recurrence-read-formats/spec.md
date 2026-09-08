## ADDED Requirements

### Requirement: Entity-specific recurrence read names

Event standard responses SHALL expose event_recurrence_rules whenever recurrence_rules exists, with the same JSON value. Reminder list/search responses SHALL expose reminder_recurrence_rules with the same JSON value as recurrence_rules. Legacy recurrence_rules SHALL retain its existing per-entity shape and semantics.

#### Scenario: Event recurrence and field selection
- **WHEN** a recurring event is formatted in standard detail
- **THEN** both event_recurrence_rules and recurrence_rules contain the existing array of rule objects
- **AND** selecting only event_recurrence_rules through fields includes that field and excludes the unselected legacy field

#### Scenario: Event summary and non-recurring event
- **WHEN** an event is formatted in summary detail without explicit fields, or has no recurrence fragment
- **THEN** event_recurrence_rules is absent

#### Scenario: Reminder recurrence states
- **WHEN** a reminder is serialized
- **THEN** both recurrence fields are [] for a non-recurring reminder, null for a recurring reminder without available rules, or the same complete ordered array for available rules

### Requirement: Published format distinction

Documentation SHALL distinguish the event rule array from the reminder rule array, event omitted selectors from reminder null selectors, existing event end_date rendering from reminder UTC rendering, and the reminder-specific selector keys. It SHALL explain the legacy aliases and that clients rejecting unknown fields require decoder updates.

#### Scenario: Client chooses a decoder
- **WHEN** a client author reads the recurrence documentation
- **THEN** the documentation identifies event_recurrence_rules as an array of event rule objects and reminder_recurrence_rules as an array or null, with their respective missing-value rules

### Requirement: Unknown event frequency

Event recurrence serialization SHALL avoid indexing outside a fixed frequency table. An unsupported raw frequency SHALL produce frequency unknown plus frequency_raw_value equal to the original integer. Supported frequencies SHALL keep their existing names and fields.

#### Scenario: Unsupported frequency value
- **WHEN** frequency raw value is 999
- **THEN** frequency name resolution yields unknown without trapping
