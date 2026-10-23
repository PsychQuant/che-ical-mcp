## MODIFIED Requirements

### Requirement: Project-level configuration and archive state

The skill SHALL honor an optional `.claude/.ical/config.yaml` (human-authored YAML; fields: `default_calendar` and the `calendar_routing` block defined by the `calendar-routing` capability), found by the lookup order defined there, and SHALL maintain `.claude/.ical/state/archives.json` in the working directory's own project, even when the config was found in a parent directory. The archive state file is a machine-queried map from source identifier to the archived event (`event_id`, `calendar`, `archived_at`). Calendar choice SHALL try, in order: a matching `calendar_routing` rule; then `default_calendar`; then derivation from prior filings of the same kind; then asking. `default_calendar` is read by this skill only; routing SHALL NOT treat it as a catch-all. Missing files are not errors: an absent config falls back to derivation-then-ask for calendar choice; an absent state file makes the index lookup a miss, falling back to the notes search, and is created on the next successful archive. A malformed file SHALL be reported in the run's output and treated as absent — never silently swallowed.

#### Scenario: The config names a default calendar

- **GIVEN** `.claude/.ical/config.yaml` contains `default_calendar: "行政"` and no `calendar_routing`
- **WHEN** a source is archived
- **THEN** the event is created in 行政 without a calendar question

#### Scenario: A routing rule outranks default_calendar

- **GIVEN** the config contains `default_calendar: "行政"` and a rule `conference_schedule` with calendar `Conference` that matches the source
- **WHEN** the source is archived
- **THEN** the event is created in Conference, and the report carries the routed line

#### Scenario: No rule matches and default_calendar is set

- **GIVEN** the config contains `default_calendar: "行政"` and rules that match nothing about the source
- **WHEN** the source is archived
- **THEN** the event is created in 行政, as the second tier of calendar choice

#### Scenario: The config comes from a parent directory

- **GIVEN** the working directory has no `.claude/.ical/config.yaml` and its parent has one
- **WHEN** a source is archived
- **THEN** the parent's config is used for calendar choice, and `state/archives.json` is read and written under the working directory's `.claude/.ical/state/`

#### Scenario: No config file exists

- **GIVEN** no config file is found by the lookup order
- **WHEN** a source is archived
- **THEN** calendar choice falls back to derivation (prior filings of the same kind), then to asking — and no error is raised

#### Scenario: The state index already maps this source

- **GIVEN** `state/archives.json` maps the mail's Message-ID to an event
- **WHEN** the corrected source is re-archived
- **THEN** the mapped event is updated directly, without searching event notes

#### Scenario: A malformed config is reported, not swallowed

- **GIVEN** `config.yaml` fails to parse
- **WHEN** a source is archived
- **THEN** the report carries an explicit warning and behavior proceeds as if the file were absent
