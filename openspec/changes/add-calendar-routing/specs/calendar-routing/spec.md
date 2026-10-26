## Purpose

Defines how the che-ical-mcp plugin decides which calendar an event is created in, using a per-folder `calendar_routing` rule set found by walking up from the working directory. It gives every event-creating entry point one resolution path and one traceable report.

## ADDED Requirements

### Requirement: Config lookup walks up and the closest file wins

The plugin SHALL look for `.claude/.ical/config.yaml` starting in the current working directory and moving to each parent directory in turn, and SHALL use the first file found. It SHALL NOT merge the contents of more than one config file. The walk SHALL stop at the user's home directory, at the filesystem root, or at a git repository boundary, whichever comes first, where a directory holding a `.git` entry is the last directory searched. A config file SHALL be ignored with a warning, and the walk SHALL continue, when the file, its `.ical` directory or its `.claude` directory (each judged at its physical path) is not owned by the current user or is writable by group or others, so that a file planted in or swapped within a shared directory cannot redirect events. If no file is found, the plugin SHALL look for `~/.claude/.ical/config.yaml`. If that is also absent, the plugin SHALL keep today's behavior, in which the caller names the calendar.

#### Scenario: A parent folder's config covers a subfolder

- **GIVEN** `~/Conf/.claude/.ical/config.yaml` exists, `~/Conf/2026-jscs/` has no `.claude/.ical/` directory, and the working directory is `~/Conf/2026-jscs/`
- **WHEN** an event is created
- **THEN** the config at `~/Conf/.claude/.ical/config.yaml` is used

#### Scenario: The closest config replaces the parent's without merging

- **GIVEN** `~/Conf/.claude/.ical/config.yaml` defines kinds `conference_schedule` and `travel`, and `~/Conf/2026-jscs/.claude/.ical/config.yaml` defines only kind `talk`
- **WHEN** an event is created with the working directory `~/Conf/2026-jscs/`
- **THEN** only kind `talk` is used, and the parent's kinds are not

#### Scenario: The walk stops at a repository boundary

- **GIVEN** the working directory is inside a git repository whose root has no `.claude/.ical/config.yaml`, and a parent of that repository has one
- **WHEN** an event is created
- **THEN** the parent's config is not used, and the lookup continues with `~/.claude/.ical/config.yaml`

#### Scenario: A config owned by another user is ignored

- **GIVEN** the nearest `.claude/.ical/config.yaml` is owned by a different user, and a parent directory has one owned by the current user
- **WHEN** an event is created
- **THEN** the foreign file is ignored with a warning naming it, and the parent's file is used

#### Scenario: A config in a directory others can write to is ignored

- **GIVEN** the nearest `.claude/.ical/config.yaml` is owned by the current user but its `.ical` directory is writable by group or others, and the user-level config exists
- **WHEN** an event is created
- **THEN** the file is ignored with a warning naming it, and the lookup continues

#### Scenario: The user-level config is the fallback

- **GIVEN** no `.claude/.ical/config.yaml` exists from the working directory up to its boundary, and `~/.claude/.ical/config.yaml` exists
- **WHEN** an event is created
- **THEN** the user-level config is used

#### Scenario: No config anywhere

- **GIVEN** neither a project config nor `~/.claude/.ical/config.yaml` exists
- **WHEN** an event is created
- **THEN** the caller names the calendar as it does today, and no error is raised

### Requirement: Routing rules are user-defined kinds with a required calendar and includes

A `calendar_routing` block SHALL be a list of rules. Each rule SHALL have a `kind` name chosen by the user, a `calendar` naming the destination calendar, and an `includes` value that is a non-empty description of the events the kind covers. A rule SHALL accept an optional `source` naming the account that holds the calendar, for the case where the same calendar name exists in more than one account. The plugin SHALL NOT define a fixed set of kind names. An unknown key SHALL be reported and ignored.

#### Scenario: A valid rule set is read

- **GIVEN** a config with rules `conference_schedule` (calendar `Conference`) and `travel` (calendar `旅遊`), each with a non-empty `includes`
- **WHEN** an event is created
- **THEN** both rules are available for classification

#### Scenario: A rule without includes is invalid

- **GIVEN** a `calendar_routing` entry has a `calendar` but an empty or missing `includes`
- **WHEN** an event is created
- **THEN** the run's report names the invalid entry, the whole `calendar_routing` block is ignored, and the other fields of the file still apply

#### Scenario: A rule without calendar is invalid

- **GIVEN** a `calendar_routing` entry has an `includes` but no `calendar`
- **WHEN** an event is created
- **THEN** the same reporting and ignoring applies as for a missing `includes`

#### Scenario: An unknown key is reported and ignored

- **GIVEN** a rule carries a key the plugin does not define, such as `when`
- **WHEN** an event is created
- **THEN** the report names the key, the key has no effect, and the rule is otherwise used

### Requirement: Events are classified against includes, with no match and multiple matches handled explicitly

The model SHALL classify an event by comparing it with each rule's `includes` text. If exactly one rule matches, the event SHALL be created in that rule's calendar. If no rule matches, the plugin SHALL NOT use `default_calendar` as a fallback, and SHALL behave as the entry point does without routing: the caller names the calendar. If two or more rules match, the plugin SHALL ask the user which rule applies, and SHALL NOT pick the first rule listed.

#### Scenario: One rule matches

- **GIVEN** rules `conference_schedule` (includes program sessions, the user's own talk, a reception) and `travel` (includes flights, lodging, transfers)
- **WHEN** an event for a program session is created
- **THEN** it is created in the `conference_schedule` calendar without a calendar question

#### Scenario: No rule matches

- **GIVEN** the same rules and an event that fits neither, such as a dentist appointment
- **WHEN** the event is created
- **THEN** the calendar is chosen the way the entry point chooses without routing, and `default_calendar` is not applied by routing

#### Scenario: Two rules match

- **GIVEN** the same rules and an excursion organized by the conference that is also private sightseeing
- **WHEN** the event is created
- **THEN** the user is asked which rule applies, and nothing is created until they answer

### Requirement: A routed creation reports the rule and the config file

When an event is created through routing, the report SHALL contain the line `Routed to <calendar> by rule '<kind>' from <config path>`. When an event is created without routing, the report SHALL state why: no config file, no rule matched, or the user was asked. A config that cannot be parsed SHALL be reported and treated as absent; it SHALL NOT change behavior silently.

#### Scenario: The routed line is present

- **GIVEN** an event matches rule `travel` in `/Users/x/Conf/.claude/.ical/config.yaml`
- **WHEN** the event is created
- **THEN** the report contains `Routed to 旅遊 by rule 'travel' from /Users/x/Conf/.claude/.ical/config.yaml`

#### Scenario: An unrouted creation says why

- **GIVEN** no config file exists
- **WHEN** an event is created
- **THEN** the report states that no config file was found

#### Scenario: A config that fails to parse is reported

- **GIVEN** the nearest config file is not valid YAML
- **WHEN** an event is created
- **THEN** the report carries an explicit warning naming the file, and behavior proceeds as if no config file existed

### Requirement: A named calendar that does not exist is reported, never created

When the calendar named by the matched rule does not exist, the plugin SHALL report this and ask the user how to proceed. It SHALL NOT create the calendar. When the rule carries a `source`, the plugin SHALL look for the calendar in that account only.

#### Scenario: The calendar is missing

- **GIVEN** rule `travel` names calendar `旅遊` and no calendar by that name exists
- **WHEN** an event matches `travel`
- **THEN** the plugin reports the missing calendar and asks, and no calendar is created

#### Scenario: The same name exists in two accounts

- **GIVEN** rule `conference_schedule` names calendar `Conference` with `source: iCloud`, and a calendar named `Conference` also exists in another account
- **WHEN** an event matches `conference_schedule`
- **THEN** the event is created in the iCloud calendar

### Requirement: All event-creating entry points share one resolution path

The `archive-event` skill, the `quick-event` command, and the create workflow of the `calendar-management` skill SHALL resolve the destination calendar through the same documented rule and the same lookup helper. No entry point SHALL restate the lookup order, the rule structure, or the report format in its own text; each SHALL refer to the shared rule.

#### Scenario: Two entry points give the same answer

- **GIVEN** a config whose rule `conference_schedule` matches a given event
- **WHEN** the event is created once through `archive-event` and once through `quick-event` from the same working directory
- **THEN** both choose the same calendar and both reports contain the routed line

#### Scenario: The helper finds the nearest config

- **GIVEN** a test directory tree with configs at several levels, a repository boundary, and a user-level config
- **WHEN** the lookup helper runs from each directory in the tree
- **THEN** it prints the path the lookup requirement above selects, or prints nothing when none applies

### Requirement: Existing default_calendar configs behave as before

`default_calendar` SHALL keep its current meaning: it is read by the `archive-event` skill as the first tier of calendar choice, and by no other entry point. Routing SHALL NOT use it as a catch-all. A config with only `default_calendar` SHALL behave exactly as it does without this capability.

#### Scenario: A config with only default_calendar

- **GIVEN** `.claude/.ical/config.yaml` contains `default_calendar: "行政"` and no `calendar_routing`
- **WHEN** a source is archived
- **THEN** the event is created in 行政 without a calendar question, as before

#### Scenario: quick-event ignores default_calendar

- **GIVEN** the same config
- **WHEN** an event is created through `quick-event` with no calendar named
- **THEN** the user is asked for the calendar, as before
