## Problem

PR #583 verify round 1 (#540) found that the changed-after refusal named this server as a possible source but still told the caller to "change it back and run undo again". A change made back through this server is recorded as an entry of its own above the refused one, so the next undo takes that entry first, and the undo after it is refused again (E1, E3). Both shapes measured for #540 loop this way. The redo text offered a change-back that cannot work through this server, since any recorded change clears the redo history (E9). The `undo` tool description and its manifest summary give the same instruction. README.md, README_zh-TW.md and docs/UNDO_HISTORY.md still say that a person made the change and that whoever made it decides (E2). The #538 paragraph of both READMEs, the #538 and #484 entries of CHANGELOG `[Unreleased]`, and the #538 requirement of `undo-history-discard` still describe the old text as current (E4, E5).

## Root Cause

The texts of the first change named the sources but kept the change-back instruction written for a change made elsewhere. The other surfaces that state the source or the instruction were not swept.

## Proposed Solution

- The undo text says that a change made back through this server is recorded above the refused entry, that the next undo takes that entry first, and that it has to be given up with `discard_id` before undo runs again. A change made back in another app records nothing here.
- The redo text asks for the change-back in another app, and names `complete_reminder` for setting the completion through this server.
- The `undo` tool description and its manifest summary say the same. Both READMEs and docs/UNDO_HISTORY.md drop "a person" and "whoever made the change". The #538 paragraph, the CHANGELOG entries and the #538 requirement say that since #540 the text names this server's later operations among the possible sources.

## Corrections to the archived change `idd-540-changed-after-source`

These corrections are recorded here. The archived files are kept as they were, except for the e-mail address removed from its `.openspec.yaml` (E8):

- Task 1.1 says the redo texts name another app, the calendar server and this server's later operations. The redo text names no source (commit d8b3ed87); the plan changed in review.
- Task 2.2 says README, tool descriptions and manifest needed no change. That was wrong. README.md and README_zh-TW.md (the #236 and #538 paragraphs) and docs/UNDO_HISTORY.md stated the source or the "whoever" instruction, and the `undo` description and manifest summary gave the change-back instruction. This change updates them.

## Non-Goals

- Any change to what an undo or a redo writes, keeps or discards.
- Historical CHANGELOG lines of released versions, and the plugin's CHANGELOG and README, which describe released texts.

## Success Criteria

- The whole undo and redo texts match their pinned strings.
- Each new phrase appears once in its document, and the old phrases appear nowhere in the current docs.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `undo-history-discard`: the #538 requirement names the text as changed by #540, and the #540 requirement says what a change-back through this server needs.

## Impact

- `Sources/CheICalMCP/EventKit/UndoGuardErrors.swift`, `Sources/CheICalMCP/Server.swift` (`undo` description), `mcpb/manifest.json` (`undo` summary).
- `README.md`, `README_zh-TW.md`, `docs/UNDO_HISTORY.md`, `CHANGELOG.md`.
- Tests: `UndoChangedSourceTests` (whole texts), new `UndoChangedSourceDocsTests`.
