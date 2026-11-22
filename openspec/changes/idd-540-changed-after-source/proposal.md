## Problem

When an undo is refused because the item no longer holds the state the recorded operation left, the text (`UndoTargetChangedError`, revertable case) says the item "was changed after this operation, in another app or by the calendar server". The change can also be this server's own: a later operation whose entry was given up with `discard_id`, or that an undo refused and discarded, leaves its write in place, and the next undo compares an older record against it (#540; measured on #484 run G on a Google account: `create_event`, `move_events_batch`, `discard_id` of the move, `undo` named `calendar` and blamed another app or the calendar server). The text then goes on with "Whoever made the change should decide", which points away from the session's own history. The redo text has the same fixed source.

## Root Cause

The source is a fixed string (`changedBy` in `UndoTargetChangedError.init`), not something the guard knows: `UndoTargetCheck.check` and `postStateRefusal` compare the item with the recorded state and have no information about who changed it.

## Proposed Solution

- The undo text names this server's own later operations as a possible source next to another app and the calendar server: "or by a later operation of this server that has no entry in the undo history now (for example one whose entry was given up with discard_id)". Reminders keep the failed-write source of #274.
- The redo text names "a later operation or undo of this server that has no entry in the redo history now" the same way (every recorded write clears the redo history, so only an unrecorded write or an undo whose redo entry is gone can be the server's own source there).
- "Whoever made the change should decide:" is dropped; the sentence goes on with "ask the user whether to change it back".

## Non-Goals

- Telling the sources apart: the guard cannot, and no record is added for it.
- Any change to what an undo or redo writes, keeps or discards.
- The other refusal texts (edited occurrences, unchecked occurrences, shortened rule, unconfirmed occurrence, the missing-item texts, `MoveByCopyUndo`, `SeriesUpdateUndo`): they name no source.

## Success Criteria

- The event and reminder undo texts and the redo texts name another app, the calendar server and this server's own later operations without an entry; reminders still name the failed write; events do not.
- No text says "Whoever made the change".
- The fixed prefixes "was changed after this operation" and "was changed after the undo" and the #265 note stay.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `undo-history-discard`: the changed-after refusal names the possible sources it cannot tell apart, this server's own later operations among them.

## Impact

- `Sources/CheICalMCP/EventKit/UndoGuardErrors.swift`: the two revertable texts.
- Tests: a new pure test file of the texts.
- `CHANGELOG.md` `[Unreleased]`.
