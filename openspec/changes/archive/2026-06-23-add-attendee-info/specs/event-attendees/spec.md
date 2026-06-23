## ADDED Requirements

### Requirement: Event responses include attendees array

All event-returning tool responses SHALL include an `attendees` array when the event has participants. Each attendee object SHALL contain `name` (string or null), `email` (string), `role` (string), `status` (string), `type` (string), and `is_current_user` (boolean). The `attendees` field SHALL be omitted when the event has no participants.

#### Scenario: Event with multiple attendees

- **WHEN** a user calls `list_events` and an event has 3 attendees
- **THEN** the event JSON SHALL include an `attendees` array with 3 objects, each containing `name`, `email`, `role`, `status`, `type`, and `is_current_user` fields

#### Scenario: Event with no attendees

- **WHEN** a user calls `list_events` and an event has no participants (e.g., local calendar event)
- **THEN** the event JSON SHALL NOT include the `attendees` field

#### Scenario: Attendee with nil name

- **WHEN** an `EKParticipant` has `name == nil` (contact not in Address Book)
- **THEN** the attendee object SHALL set `name` to `null` and `email` SHALL still be populated from the participant URL

### Requirement: Event responses include organizer object

All event-returning tool responses SHALL include an `organizer` object when the event has an organizer. The organizer object SHALL contain `name` (string or null), `email` (string), and `is_current_user` (boolean). The `organizer` field SHALL be omitted when the event has no organizer.

#### Scenario: Event with organizer

- **WHEN** a user calls `search_events` and an event has an organizer
- **THEN** the event JSON SHALL include an `organizer` object with `name`, `email`, and `is_current_user` fields

#### Scenario: Event without organizer

- **WHEN** a user calls `list_events` and an event has no organizer (e.g., locally created event)
- **THEN** the event JSON SHALL NOT include the `organizer` field

### Requirement: Email extraction from EKParticipant URL

The system SHALL extract the email address from `EKParticipant.url` by stripping the `mailto:` prefix. If the URL does not use the `mailto:` scheme, the system SHALL use the full URL string as the email value.

#### Scenario: Standard mailto URL

- **WHEN** an `EKParticipant.url` is `mailto:user@example.com`
- **THEN** the extracted email SHALL be `user@example.com`

#### Scenario: Non-mailto URL

- **WHEN** an `EKParticipant.url` is `https://example.com/user`
- **THEN** the email field SHALL contain the full URL string `https://example.com/user`

### Requirement: Enum values mapped to human-readable strings

The system SHALL map `EKParticipantRole`, `EKParticipantStatus`, and `EKParticipantType` enum values to lowercase human-readable strings.

Role mapping: `unknown`, `required`, `optional`, `chair`, `non_participant`.
Status mapping: `unknown`, `pending`, `accepted`, `declined`, `tentative`, `delegated`, `completed`, `in_process`.
Type mapping: `unknown`, `person`, `room`, `resource`, `group`.

#### Scenario: Accepted required person attendee

- **WHEN** an `EKParticipant` has role `.required`, status `.accepted`, type `.person`
- **THEN** the attendee object SHALL have `role: "required"`, `status: "accepted"`, `type: "person"`

#### Scenario: Unknown enum value

- **WHEN** an `EKParticipant` has a role/status/type value not in the known mapping
- **THEN** the system SHALL use `"unknown"` as the string value

### Requirement: Attendee info in all event-returning handlers

The following tools SHALL include attendee and organizer information in their event output: `list_events`, `search_events`, `list_events_quick`, `check_conflicts`, `create_event` (response), `update_event` (response), `copy_event` (response), `find_duplicate_events`.

#### Scenario: Consistency across handlers

- **WHEN** the same event is returned by `list_events` and `search_events`
- **THEN** both responses SHALL contain identical `attendees` and `organizer` fields for that event
