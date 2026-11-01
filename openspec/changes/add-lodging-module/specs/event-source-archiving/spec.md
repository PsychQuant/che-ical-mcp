## ADDED Requirements

### Requirement: A booking confirmation is archived through the lodging module

When the source is a booking confirmation, change notice or cancellation notice for a stay and the `lodging-module` capability is enabled and triggered, the skill SHALL build the event through that module instead of creating or updating one event, and this requirement SHALL take precedence over the single-event rules of this capability for that source only. The skill SHALL still write the source line (sender, date and time, subject, Message-ID) into the event's notes above the module's marker line, and SHALL still surface same-day deadlines. The key of the event SHALL be the reservation number carried in the module's marker line and not the Message-ID of the original notice, because a change or cancellation notice is a different message. The skill's rule for choosing the authoritative message by sender and parsable time SHALL NOT apply to a stay: the authoritative message SHALL be the latest booking-party message (confirmation, change or cancellation) carrying the reservation number, ordered by each message's own date and time (the original's for a forwarded message), and the skill SHALL ask when the order is unclear. The thread-root rules of the skill (resolving a thread to its first message, and storing the original notice's Message-ID) SHALL NOT apply to a stay: the source line, the state keys and the cancellation record SHALL use the Message-ID of the message actually reflected, and the protection of a stay from the single-event path is a separate requirement below. The skill SHALL still apply its calendar fallback and its same-day deadline check. The skill SHALL NOT write an estimate line for a stay: when the check-out date is missing, the skill SHALL ask. The skill SHALL record in `state/archives.json` the source identifier with the suffix `#lodging:<reservation>` mapped to the stay event together with its reservation number (one entry per reservation, because one message can confirm several), so that a source which also built a conference keeps its own entry, SHALL treat a mapping only as a hint, SHALL read the entry under the bare source identifier, and under the bare identifier of the thread's first message, the same way for a booking archived before the module existed (an event it maps to that holds no module marker is adopted only after a mapping table and the user's yes), SHALL, after the module deletes an event, remove every mapping that names it and write an entry keyed by the cancelling message with `reservation` and `cancelled_at`, the date and time of the cancelling message, as the module's cancellation record, and SHALL write nothing for a cancellation left pending. The skill SHALL NOT apply the conference module's umbrella lookup or its marker lines to a stay: when `state/archives.json` maps the source to an event, the skill SHALL read that event's notes and treat it as a module event only if they hold the `lodging-module:` marker line, and otherwise as a hand-built event that is adopted only after a mapping table and the user's yes. A cancellation notice SHALL follow the module's confirmation rule, and the skill SHALL NOT list `delete_event` in its `allowed-tools`. The skill reads `lodging_module` from the same config as its other fields.

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
- **THEN** `state/archives.json` holds the umbrella under the message identifier and the stay under the identifier with the suffix `#lodging:` and the reservation number

#### Scenario: A booking archived before the module gets a change notice

- **GIVEN** `state/archives.json` maps a source's bare identifier to a single hand-built event with no marker, and a later change notice for the same booking arrives
- **WHEN** the skill archives the notice
- **THEN** the skill shows a mapping table of that event and the booking and asks once before touching it

#### Scenario: A cancelled stay's confirmation is archived again

- **GIVEN** a stay was cancelled and deleted, and `state/archives.json` holds a cancellation record with `cancelled_at` for its reservation number
- **WHEN** the original confirmation, dated before the cancellation, is archived again
- **THEN** no event is created and the report says the confirmation is superseded

#### Scenario: A later notice in the same thread

- **GIVEN** a stay archived from a confirmation, and a change notice in the same thread with another Message-ID
- **WHEN** the skill archives the change notice
- **THEN** the stay is updated rather than reported as unchanged, and its source line now holds the change notice's own Message-ID (it held the confirmation's, not the thread's first message, before)

#### Scenario: A hotel message with no reservation number

- **GIVEN** a stay archived through the module, and `lodging_module: off` or a later hotel message with no reservation number
- **WHEN** the message is archived
- **THEN** the single-event steps do not update the stay and the report names it as left as it is (or the module decides it changes nothing)

#### Scenario: A traveler's reply in the same thread

- **GIVEN** a stay archived through the module
- **WHEN** the traveler's own reply quoting the reservation number is archived
- **THEN** the single-event steps do not update the stay and the report lists the message as not a notice from the booking party

#### Scenario: A cancellation has no time

- **GIVEN** an event for reservation 123456 and a cancellation notice that states no date-time
- **WHEN** the skill chooses the authoritative message
- **THEN** it chooses the latest message carrying 123456, not the older confirmation

#### Scenario: The report on correction tracking

- **GIVEN** a stay was archived through the module
- **WHEN** the skill reports
- **THEN** the report says corrections are tracked by the module's marker line, and `state/archives.json` maps the source to the stay event

### Requirement: A stay is never updated as a single event, whatever the lodging switch says

This requirement does not depend on the lodging module being enabled or triggered. A hit of the skill's single-event path, from the state mapping or from a notes search, on an event that holds a `lodging-module:` marker line SHALL NOT be updated as a single event: the skill SHALL read the mapped event's notes before updating it, SHALL hand the message to the lodging module when that module is on and triggered, and otherwise SHALL name the event in the report and leave it as it is. The trigger SHALL be judged on the whole thread: any message in a thread that already produced a stay, a traveler's reply included, goes to the module even when it carries no reservation number. A thread has produced a stay when `state/archives.json` holds an entry whose key starts with the Message-ID of any message of the thread followed by `#lodging:`, or when a notes search for those Message-IDs hits an event with a lodging marker; with the module off, that check SHALL also block `create_event` for the thread. A `conference-module` marker SHALL NOT be covered by this requirement: the conference module keeps its own rule that, when it is off, the skill's steps run unchanged. For the lookup of a booking archived before the module existed, the thread-root rule of the skill SHALL still apply to that one lookup.

#### Scenario: A hotel message with no reservation number and the module off

- **GIVEN** a stay archived through the module, `lodging_module: off`, and a later hotel message in the same thread with another Message-ID
- **WHEN** the message is archived
- **THEN** the skill finds the thread's stay through the state entry or the marker, creates nothing, updates nothing, and the report names the stay as left as it is

#### Scenario: The mapped event is read before it is updated

- **GIVEN** the state maps a source to an event that holds a `lodging-module:` marker line
- **WHEN** the single-event path would update it
- **THEN** the skill reads its notes first, sees the marker, and does not update it as a single event
