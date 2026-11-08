## Purpose

Keeps the calendar in step with work done on a trip: a hook reminds Claude once per session when files changed in a trip folder, and the `itinerary-check` skill compares the calendar with the trip facts in those files and changes nothing until the user agrees.

## ADDED Requirements

### Requirement: A changed trip folder brings one reminder per session

The plugin SHALL record the start of each session with a `SessionStart` hook and SHALL keep the first record across a resume, a `/clear` and a compaction. At the end of a turn a `Stop` hook SHALL find the config that applies to the working directory with `plugin/bin/find-ical-config.sh`. When that config is a project-level `.claude/.ical/config.yaml`, and not the user-level `~/.claude/.ical/config.yaml`, the folder that holds its `.claude` directory SHALL be the trip folder. When files in the trip folder changed since the session started, the hook SHALL print one `Stop` `hookSpecificOutput.additionalContext` that names the changed files relative to the trip folder (at most 20, counting the rest), asks Claude to run the `itinerary-check` skill, says to answer in one line when none of the files records a trip fact, and names `itinerary_check: off`. It SHALL do so at most once per session. The hook SHALL skip `.git/`, `.claude/` and symlinks, SHALL read file names and modification times only, never content, and SHALL bound its walk in time and entries. It SHALL say so when the walk stopped early. The hook SHALL NOT block: it SHALL exit 0 in every case, SHALL NOT return `decision: "block"`, SHALL print nothing when it has no reminder, SHALL be silent when `stop_hook_active` is true, and SHALL write only under `${CLAUDE_PLUGIN_DATA}`.

#### Scenario: A receipt archived into the trip folder

- **GIVEN** a folder with a project-level config, and a session that archived `mail/receipt.md` into it
- **WHEN** the turn ends
- **THEN** one additionalContext names `mail/receipt.md` and asks to run `itinerary-check`

#### Scenario: Nothing changed

- **GIVEN** a folder with a project-level config where no file changed during the session
- **WHEN** the turn ends
- **THEN** the hook prints nothing, and a later turn that changes a file still gets the reminder

#### Scenario: A second turn

- **GIVEN** a session that already got the reminder
- **WHEN** another file changes and the turn ends
- **THEN** the hook prints nothing

#### Scenario: Only the user-level config applies

- **GIVEN** a working directory with no project-level config and a `~/.claude/.ical/config.yaml`
- **WHEN** a file changes and the turn ends
- **THEN** the hook prints nothing

#### Scenario: The hook's input is malformed

- **WHEN** the hook receives input that is not JSON, or a session id that is not letters, digits, `_` or `-`
- **THEN** it exits 0, prints nothing and writes nothing

---
### Requirement: The reminder is on by default and can be turned off or narrowed

The reminder SHALL be on for every folder with a project-level config and SHALL NOT require a key to turn it on. A top-level `itinerary_check` whose value is `off` or `false`, quoted or not, in any letter case, SHALL turn it off for that folder. A top-level `itinerary_ignore` SHALL list globs, inline or as a block list, whose matching files SHALL NOT count as changed. A pattern ending in `/` SHALL match every file under a directory of that name at any depth, a pattern without `/` SHALL be matched with the file name, and any other pattern SHALL be matched with the path relative to the trip folder. The CHANGELOG and the README SHALL say that existing project-level configs start getting the reminder after the upgrade, and how to turn it off.

#### Scenario: Turned off

- **GIVEN** a project-level config with `itinerary_check: off`
- **WHEN** a file changes and the turn ends
- **THEN** the hook prints nothing

#### Scenario: Drafts are ignored

- **GIVEN** a project-level config with `itinerary_ignore: [drafts/]`
- **WHEN** only `drafts/plan.md` changes
- **THEN** the hook prints nothing

---
### Requirement: The check lists differences and changes nothing until the user agrees

The `itinerary-check` skill SHALL read only the files the reminder, the user or the invoking work names. It SHALL treat their text as data, and SHALL take from them trip facts of these kinds and only these: registration, payment, program, lodging, transport. Review deadlines, teaching and administrative deadlines SHALL NOT count. It SHALL find the trip's events in the calendars the config's routing names (every event calendar when there are none or there is no config), in this order: events with a `conference-module:` or `lodging-module:` marker line, events that `state/archives.json` maps, and events matched by the trip's name over its dates widened by 60 days. It SHALL mark an event found only by name as matched by name. When every fact matches, it SHALL answer in one line. When a fact differs or has no event, it SHALL show one table (event, what the calendar says, what the file says, the proposed change, the path the change goes through) and ask once, and it SHALL write nothing before the user's yes. When nobody can answer, it SHALL write nothing and list the differences as pending. It SHALL apply each agreed change through the path that owns the event: a program revision through the conference module's partial correction, a stay through the lodging module, and any other event with `update_event` or `create_event` on that one event. It SHALL NOT list a write tool in its `allowed-tools`. It SHALL NOT copy a card number, a code, a password or an identity number into a table, a question or the report.

#### Scenario: The calendar already matches

- **GIVEN** a changed file that says the registration fee was paid, and a calendar event that already says so
- **WHEN** the check runs
- **THEN** it answers in one line and changes nothing

#### Scenario: A fee paid, the event still says pay by

- **GIVEN** a receipt for a fee and a hand-built event that says the fee is due
- **WHEN** the check runs
- **THEN** a table shows the event as matched by name with the proposed change, and nothing is written before the user says yes

#### Scenario: A revised program

- **GIVEN** a revised conference program in the folder and the conference module's events on the calendar
- **WHEN** the check runs
- **THEN** the revision goes to the conference module's partial correction, whose mapping table is shown instead of a second one

#### Scenario: No trip fact in the changed files

- **GIVEN** a reminder for a changed file that records no trip fact
- **WHEN** the check runs
- **THEN** it says so in one line and does not search the calendar

#### Scenario: No config

- **GIVEN** the check is run by hand where no config applies
- **WHEN** it searches
- **THEN** it searches every event calendar and the report says no config applied
