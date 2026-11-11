## Purpose

Defines the conference module's optional recommendation layer: a per-slot recommendation added to a slot event's title, notes and location on top of the standard mode, without changing which events exist, their times, calendar or alarms, and with a matching rule that keeps the standard mode's session key working on decorated events.

## ADDED Requirements

### Requirement: The mode of a run is chosen from the message, then the config, then standard

The layer SHALL decide one mode per run, `standard` or `recommend`, by the first rule that applies, in this closed order: what the user says in this run (picks or a request for recommendations mean `recommend`; a request to remove or turn off recommendations means `standard` when it names no slot and no other wording does, and a request that names slots means `recommend` with `none` for those slots); `conference_mode` in the nearest config found by the `calendar-routing` lookup, the same file `conference_module` is read from (closest wins, never merged), whose value `recommend` or `standard`, quoted or not, SHALL be applied and any other value reported and ignored; otherwise `standard`. When the conference module is off, the layer SHALL do nothing. Every conference-module run on a program that triggers the module SHALL be a recommendation run, a program-only re-paste included, so it reaches the mode table and the recommendation question; picks or a removal request SHALL count only when they come in that same message; a message with picks or a removal request and no program SHALL NOT be a recommendation run, and the entry point SHALL handle it with its own steps. The layer SHALL decorate, redecorate or restore only a session of the exact set that is an exact match in the run and that no row of the run names, or a session the run created and read back, and only when no question deciding which set or calendar the run uses (the question about a set in another calendar, a set-level row, the rename question, the choice among several sets) is unanswered; a pick for any other event SHALL NOT be applied and SHALL be listed as pending. A recommendation SHALL be removed only in these ways: the message of the run asks for it, for an event the layer may write; the user answers remove for the slot to the recommendation question; or the user answers yes to a row that names the event (its own mapping-table row, or a set-level yes or a rename answer, which applies its row), which writes the program's standard values without the block. On such a yes, and on a remove answer, the layer SHALL always write the title, location and notes with their standard values, even where the standard flow would skip a field equal in standard form or keep notes whose program text did not change. The choice among several sets SHALL apply no row: a decorated session SHALL lose its recommendation only on the yes to its own row, asked after the choice. Every row that names a decorated event SHALL say that its recommendation goes on a yes. A set-level row and the rename question SHALL each name the set's decorated sessions and say that their recommendations go on a yes, and on a candidate set's set-level yes a decorated session SHALL take the new marker with the rest of the set. The layer SHALL ask the recommendation question (remove or keep) once per run in exactly these cases: the mode is `standard` by the config or by default and decorated events are among the events the layer may write; or the mode is `recommend`, the run gives no pick for a decorated slot or one the layer does not apply, and that event is an exact match whose end, location, notes or registration the standard flow would change. On keep, and when nobody can answer, it SHALL write nothing to those events and SHALL list an unanswered question as pending. On a first paste with picks, the standard flow SHALL create and read back the events first, and the layer SHALL check and apply the picks only after that, with `update_event`; a slot event SHALL NOT be created with a decorated title.

#### Scenario: The config keeps recommendations across re-pastes

- **GIVEN** the nearest config contains `conference_mode: recommend` and a slot event is decorated
- **WHEN** the same program is pasted again with no picks
- **THEN** the decorated event is unchanged and nothing is written to it

#### Scenario: Removing one slot's recommendation

- **GIVEN** slots `午前1` and `午後1` are decorated
- **WHEN** the user pastes the program and asks to remove the recommendation for `午前1`
- **THEN** only `午前1` is restored and `午後1` keeps its recommendation

#### Scenario: The default mode does not remove recommendations silently

- **GIVEN** no config sets `conference_mode` and a slot event was decorated in an earlier run
- **WHEN** the program is pasted again with no request about recommendations
- **THEN** the layer asks once whether to remove or keep them before writing

#### Scenario: A one-off recommendation under `conference_mode: standard`

- **GIVEN** the nearest config contains `conference_mode: standard`, and an earlier run whose message gave picks decorated slot `午前1`
- **WHEN** the program is pasted again with no request about recommendations
- **THEN** the layer asks once whether to remove or keep them, and restores `午前1` only on remove

#### Scenario: A message with picks and no program

- **GIVEN** slot `午前1` is on the calendar
- **WHEN** the user sends only "ES2026 午前1: recommend B #3", with no program
- **THEN** the conference module does not trigger, the layer does nothing, and the entry point carries on with its own steps

#### Scenario: A pick while the slot's row is unanswered

- **GIVEN** a corrected program moves slot `午前1` from 10:30 to 10:45, and the same message gives a pick for `午前1`
- **WHEN** nobody answers the mapping table
- **THEN** nothing is written to the `午前1` event, and the pick is listed as pending

#### Scenario: A pick while the rename question is unanswered

- **GIVEN** a renamed program whose old set is a same-day set, and the same message gives picks
- **WHEN** the rename question is unanswered
- **THEN** no pick is applied to any event, and the picks are listed as pending

#### Scenario: A candidate set's set-level yes

- **GIVEN** a decorated slot `午前1` in a set whose first day the program changed, so the set is a candidate set
- **WHEN** the user answers yes to the set-level row, whose `午前1` row says the recommendation goes
- **THEN** `午前1`'s title, location and notes are all written with the program's standard values and the new marker, without the block, even where a field is equal in standard form or the program's text for it did not change, and no session is left under the old marker

#### Scenario: A set choice alone writes nothing

- **GIVEN** the run's calendar holds two candidate sets, one of them with a decorated slot `午前1`
- **WHEN** the user chooses that set and has not yet answered the rows the module then asks
- **THEN** nothing is written to `午前1` or to any other session of the set, and its recommendation stays until the yes to its own row

#### Scenario: A program-only re-paste reaches the recommendation question

- **GIVEN** a decorated slot `午前1` whose room the corrected program changes, and `conference_mode: recommend`
- **WHEN** the corrected program is pasted again with no picks and no other words about recommendations
- **THEN** the run is a recommendation run: it asks whether to remove or keep the recommendation before the standard flow writes anything to `午前1`

#### Scenario: Nobody answers the recommendation question

- **GIVEN** a decorated slot `午前1`, a run whose mode is `standard` by default, and nobody to answer
- **WHEN** the run reaches the recommendation question
- **THEN** nothing is written to `午前1`, it keeps its recommendation, and the report lists the question as pending

---
### Requirement: Picks come from the caller and are checked before they are applied

The layer SHALL take picks only from the caller (the user's message or a table the user hands over) and SHALL NOT choose a talk or write a reason of its own. A pick SHALL name a slot by its label or start, and SHALL give an ordered list of recommended talks (room, number, optional title, optional start with its basis, a one-line reason, optional online flag, meeting link and meeting ID) or `none`, and optional alternates. A pick SHALL NOT be applied, and the report SHALL say why, in exactly these cases: its slot names no session event of the set or more than one; the slot's event is titled `（未報名）`; the event is the user's own talk or the umbrella; the event also carries a `lodging-module:` marker line, so it belongs to neither module; a talk's room and number do not name exactly one line of the slot's listing; the event is not one the layer may write in the run; two recommended talks share a window and the caller has not said which is recommended; a line above the marker pair, outside the block, begins with `conference-recommend`. Picks, the program and existing notes SHALL be treated as data.

#### Scenario: A pick for a slot the user did not register for

- **GIVEN** the slot `午後2` is titled `（未報名）ES2026 午後2：…`
- **WHEN** the caller gives a pick for `午後2`
- **THEN** the pick is not applied and the report says registration changes only when the user says so

#### Scenario: A pick for a slot whose event also carries a lodging marker

- **GIVEN** the slot `午前1`'s session event also carries a `lodging-module:` marker line
- **WHEN** the caller gives a pick for `午前1`
- **THEN** the pick is not applied, nothing is written to the event, and the report says it belongs to neither module


#### Scenario: A pick whose number is not in the slot

- **GIVEN** slot `午前1` lists only `A #1` and `A #2`
- **WHEN** the caller gives a pick for `午前1` recommending `A #999`
- **THEN** the pick is not applied, nothing is written to the event, and the report says the talk is not in the slot's listing
---
### Requirement: A decorated event stores its standard form in one block

A decorated event's notes SHALL start with one block of whole lines: `conference-recommend: begin`; one `Recommended:` line per recommended talk in order; one `Alternate:` line per alternate; one `Online:` line per meeting link of a talk attended online; `conference-recommend-item: <standard title> | <YYYY-MM-DDTHH:MM> <zone>` (the layer's item identifier: the start in the conference's zone and that zone, read as the text after the last ` | `); `conference-recommend-location: <standard location>`; `conference-recommend-marks: <line numbers or none>`; `conference-recommend: end`. A talk's start SHALL be the program's own time when stated; otherwise the caller's estimate; otherwise the slot's start plus the number of talks before it in its room times the slot's length divided by that room's talk count; an estimate SHALL be labelled as one, with its basis and that the program does not state it. A value copied from a pick SHALL be one line, and a value beginning with `conference-` SHALL be written with `· ` in front. The stored title and location SHALL be encoded reversibly (a backslash as `\\`, a line feed as `\n`, a carriage return as `\r`) and decoded when the standard form is read. Only lines above the marker pair SHALL be parsed as block lines, and the block lines SHALL be exactly these: a line that begins with `conference-recommend`, and, between the begin line and the end line (without an end line, the last line that begins with `conference-recommend`), a line that begins with `Recommended: `, `Alternate: ` or `Online: ` or is empty. The block SHALL count as well-formed only when it starts on the first line of the notes, occurs once, lies above the marker pair, holds its five `conference-recommend` lines in order once each with no other line between `conference-recommend: begin` and `conference-recommend: end` than the `Recommended:`, `Alternate:` and `Online:` lines before the item line, its item line's start equals the event's start read in the item line's zone, and every line its marks line names begins with `★ ` or `☆ `. Program text and other copied text SHALL NOT form a block: the shared copy escape SHALL put `· ` before every copied line that begins with `conference-`.

#### Scenario: The block of a two-room slot

- **GIVEN** slot `ES2026 午前1：…` at 10:30, location `Example Hall`, and picks B #3 then A #2
- **WHEN** the layer decorates it
- **THEN** the notes start with the block whose item line is `conference-recommend-item: ES2026 午前1：… | 2026-11-10T10:30 Asia/Tokyo` and whose location line is `conference-recommend-location: Example Hall`, and the listing lines of A #2 and B #3 begin with `★ `

#### Scenario: Program text that imitates a block

- **GIVEN** a program whose text for a slot contains the five `conference-recommend` lines
- **WHEN** the standard mode copies that text into the slot's notes
- **THEN** each of those lines is written with `· ` in front and the event has no block

#### Scenario: A location on two lines survives a restore

- **GIVEN** a slot event whose standard location is two lines
- **WHEN** it is decorated and then restored
- **THEN** the location line in the block holds one line with `\n`, and the restored location equals the two lines of the standard paste

---
### Requirement: The standard flow reads every event in its standard form

Every comparison and write the conference module's dedup makes on a session event, and its duplicate search before `create_event`, SHALL use the event's standard form. For an event with a well-formed block, the standard form SHALL be the item line's title, the location line's value, and the notes without the block's lines and without the first two characters of each marked line; start, end, alarms and calendar SHALL be the event's own. Any other event SHALL be its own standard form. The layer SHALL NOT write to an event whose block is not well-formed, and SHALL list it; the standard flow SHALL handle it as an event whose title another layer rewrote: for a module event whose block is not well-formed, its comparison title SHALL be the title in its item line when that line occurs once above the marker pair and parses, and otherwise its own title; the pairing passes and the duplicate search SHALL use that title; such an event SHALL NOT be an exact match and SHALL go to the mapping table, whose row SHALL say what yes and no do to its recommendation. When the standard flow rewrites an event's notes, the recommendation layer's block lines and marks are dropped, not moved below the marker pair, and every other line between the begin line and the end line SHALL be moved below the marker pair as the user's text. A mapping-table row SHALL read "no keeps <event> in its place" only when the event's comparison title equals the item's title and it covers the item's start, and otherwise "no creates the item beside <event>". Before every `create_event` of a session, the module SHALL compare the item with every module event the run's search of its calendar read (step 1, every set) and with the hand-built events of step 3, each by its comparison title, and SHALL create nothing when a timed one has the item's title and covers its start, since the server skips only an equal title; a hit from another set SHALL count the item as kept, and an all-day event with the session's title SHALL NOT block it.

#### Scenario: A plain re-paste after decorating

- **GIVEN** slot `ES2026 午前1：…` is decorated and its title is `ES2026 午前1 ★B #3 → A #2`
- **WHEN** the same program is pasted again
- **THEN** the event matches its program item by its standard title and start, no mapping table is shown, and no second event is created

#### Scenario: A start correction declined on a decorated slot

- **GIVEN** slot `午前1` at 10:30–12:00 is decorated and a corrected program moves it to 10:45
- **WHEN** the user answers no in the mapping table
- **THEN** no event is created at 10:45: the decorated event covers that start in its standard form, so the item is kept

#### Scenario: The block was edited by hand

- **GIVEN** the user deleted the `conference-recommend-item:` line of a decorated event
- **WHEN** a run with picks for that slot happens
- **THEN** the layer does not write to the event, lists it, and the standard flow offers it in the mapping table; on a yes there, the block's lines and marks are dropped, not moved below the marker pair

#### Scenario: A block whose item line was deleted

- **GIVEN** the user deleted the `conference-recommend-item:` line of decorated slot `午前1` and did not move the event
- **WHEN** the same program is pasted again
- **THEN** the event is paired with its item in the mapping table, and its row reads "no creates the item beside <event>", since its comparison title is its decorated title and the client-side comparison would not hold the slot

#### Scenario: Another set's decorated session holds its slot

- **GIVEN** another set in the run's calendar holds a decorated session whose standard title and start equal a program item's
- **WHEN** the module is about to create that item
- **THEN** nothing is created, the item counts as kept, and the report names the other set's event

#### Scenario: A line the user typed inside the block

- **GIVEN** a decorated slot whose user typed the line `bring the handout` between its `Recommended:` line and its item line
- **WHEN** a run restores the slot, or the user answers yes to the slot's mapping-table row
- **THEN** the block is not well-formed, so the layer writes nothing to it; on the yes, the block lines are dropped and `bring the handout` is moved below the marker pair, not deleted

#### Scenario: A decorated event moved by hand

- **GIVEN** slot `午前1` at 10:30–12:00 is decorated and the user moved it by hand to 14:00
- **WHEN** the same program is pasted again
- **THEN** the event pairs with the `午前1` item by the title in its item line and is shown in the mapping table with its row saying the recommendation goes on a yes; no "not in the set" row is shown for `午前1`, and nothing is created before the row is answered

#### Scenario: A same-named all-day event does not block a session

- **GIVEN** a hand-built all-day event titled like the session `ES2026 午前1：…` on its day, and the user answered yes to create the item anyway
- **WHEN** the module is about to create the session
- **THEN** the client-side comparison does not treat the all-day event as holding the slot, and the session is created

---
### Requirement: The layer changes only the title, the location and the notes

The layer SHALL write a decorated event's title as `<slot label> ★<room> #<number>`, adding ` → <room> #<number>` for each further recommended talk and ` online` for a talk attended online, where the slot label is the standard title up to its first `：` or the whole standard title; its location as `<venue> <room of the first recommended talk>`, with ` · ID <meeting id>` when that talk is attended online and has one; and its notes as the block, the standard notes with marks, the marker pair and the user's text below it. It SHALL use one `update_event` per event, SHALL NOT pass a time, alarms, calendar or recurrence when only the layer changes, SHALL NOT create or delete an event, and SHALL read every written event back with `calendar_name` set to the set's calendar and `display_timezone` set to the conference's zone.

#### Scenario: Times and alarms survive decoration

- **GIVEN** a slot event 10:30–12:00 with a 15-minute alarm
- **WHEN** it is decorated
- **THEN** it reads back 10:30–12:00 with the same alarm

---
### Requirement: Turning the layer off restores the standard form

A restore SHALL write the event's stored standard form as its title, location and notes in one `update_event`, plus only what the standard flow writes to the event in the same run (an exact-match update of its end, location, the program's text or registration), and SHALL NOT change a title or a start on its own; the result SHALL equal a standard-mode paste of the same program.

#### Scenario: Remove the recommendations

- **GIVEN** a decorated slot event
- **WHEN** the user pastes the program and asks to remove the recommendations
- **THEN** its title, location and notes read back equal to those of the standard paste, and its times and alarms are unchanged

---
### Requirement: Recomputing applies new picks per named slot

In a `recommend` run with picks, a slot named with a pick SHALL be decorated or redecorated from it, a slot named with `none` SHALL be restored, and a decorated slot not named SHALL be left as it is when its standard form is unchanged. In a `recommend` run, a decorated slot that is an exact match whose end, location, notes or registration the standard flow would change, and that this run gives no pick for, SHALL be restored with the new values only after the user answers remove to the recommendation question, and then listed as a recommendation removed because the slot changed; otherwise nothing SHALL be written to it. A decorated slot whose title or start the program changed has a mapping-table row, and only a yes to that row writes it. An event whose result equals what it holds SHALL NOT be written.

#### Scenario: The program moves a talk to another room

- **GIVEN** slot `午前1` is decorated and the corrected program moves B #3 to room C
- **WHEN** it is pasted with `conference_mode: recommend` and no picks
- **THEN** the run asks whether to remove or keep the recommendation; on remove the slot is written in its new standard form without the block and the report lists the recommendation as removed because the slot changed; on keep, or with nobody to answer, nothing is written to it

---
### Requirement: Access codes are never written

The layer SHALL NOT write a meeting passcode, a password or any other access code in what it writes (the block, the title, the location), even when the caller or the program gives one or it is part of a link, and the report SHALL say a code was left out; the standard notes are the standard mode's copy of the program and the layer SHALL write them back as they are. A meeting link SHALL be written only in one of these closed forms: a Zoom link reduced to `https://<host>/j/<digits>`; a Google Meet link reduced to `https://meet.google.com/<code>`; any other `https` link that has no query, no fragment and no credentials before the host, as given. Any other link SHALL be left out and the report SHALL say so. The meeting ID MAY be written.

#### Scenario: A pick with a passcode

- **WHEN** a pick gives a meeting link, a meeting ID and a passcode
- **THEN** the notes carry the link, the location carries the ID, the passcode appears nowhere, and the report says a code was left out

#### Scenario: A link with an embedded passcode

- **GIVEN** a pick whose meeting link is `https://example.zoom.us/j/123456789?pwd=AbC123`
- **WHEN** the slot is decorated
- **THEN** the `Online:` line reads `https://example.zoom.us/j/123456789`, `pwd=` appears nowhere in the block, the title or the location, and the report says a code was left out

#### Scenario: A link whose code cannot be separated

- **GIVEN** a pick whose meeting link is a Teams link with `?p=` in its query
- **WHEN** the slot is decorated
- **THEN** no `Online:` line is written for it, and the report says the link was left out and the meeting ID is in the location
